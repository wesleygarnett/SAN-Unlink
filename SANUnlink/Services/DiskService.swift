import Foundation

/// Result of running a `diskutil` invocation.
struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: String

    var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
    var succeeded: Bool { status == 0 }
}

/// Errors surfaced to the UI when a disk operation fails.
struct DiskError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Enumerates Fibre Channel (SANlink) disks and performs mount / unmount / eject
/// operations by shelling out to `diskutil`. All methods are synchronous and are
/// expected to be called off the main thread (see `VolumeStore`).
enum DiskService {

    static let diskutilPath = "/usr/sbin/diskutil"

    /// `diskutil` reports Fibre Channel as either "Fibre Channel" or
    /// "Fibre Channel Interface" (e.g. Xsan / SANlink), so we match by prefix.
    static func isFibreChannelProtocol(_ value: String?) -> Bool {
        value?.hasPrefix("Fibre Channel") ?? false
    }

    // MARK: - Command execution

    /// Default timeout for quick `diskutil` calls (`list`, `info`). Mount/unmount pass
    /// larger values since Xsan mounts legitimately take ~60s.
    static let defaultTimeout: TimeInterval = 60

    /// Runs `diskutil` with a hard timeout. If the process outlives `timeout` it is
    /// SIGTERM'd (then SIGKILL'd shortly after), so a wedged `diskutil` can never
    /// block the serial work queue — or the shutdown guard — indefinitely.
    @discardableResult
    static func runDiskutil(_ args: [String], timeout: TimeInterval = defaultTimeout) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: diskutilPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: Data(),
                                 stderr: "Failed to launch diskutil: \(error.localizedDescription)")
        }

        // Escalating kill timers; both are cancelled if the process exits on its own.
        let terminateItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let killItem = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let timerQueue = DispatchQueue.global(qos: .utility)
        timerQueue.asyncAfter(deadline: .now() + timeout, execute: terminateItem)
        timerQueue.asyncAfter(deadline: .now() + timeout + 5, execute: killItem)

        // Drain stdout as it streams (avoids a full-pipe deadlock), then stderr.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        terminateItem.cancel()
        killItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            return CommandResult(status: process.terminationStatus, stdout: outData,
                                 stderr: "diskutil \(args.first ?? "") timed out after \(Int(timeout))s")
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: outData,
                             stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    private static func infoPlist(for device: String) -> [String: Any]? {
        let result = runDiskutil(["info", "-plist", device])
        guard result.succeeded else { return nil }
        return parsePlist(result.stdout)
    }

    private static func parsePlist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }

    // MARK: - Enumeration

    /// Content types that are not user-facing volumes and must never be surfaced
    /// or unmounted individually: the raw Fibre Channel LUNs that back an Xsan volume.
    private static let excludedWholeDiskContent: Set<String> = ["Apple_Xsan_Component"]

    /// Whole-disk `Content` of an assembled Xsan volume (not a raw component LUN).
    /// Always treated as a mountable volume, even when unmounted reports blank
    /// filesystem / mount-point / volume-name fields.
    private static let xsanVolumeContent = "Apple_Xsan"

    /// Returns every Fibre Channel disk currently attached, with its mountable volumes.
    ///
    /// Performance matters here: a SAN can expose dozens of FC LUNs, and this runs on
    /// every Disk Arbitration event. Each disk's `diskutil info` is fetched at most once
    /// (memoised in `infoCache`), non-volume Xsan component LUNs are skipped before any
    /// per-volume work, and whole-disk volumes reuse the info already fetched.
    static func enumerateFCDisks() -> [FCDisk] {
        let listResult = runDiskutil(["list", "-plist"])
        guard listResult.succeeded,
              let root = parsePlist(listResult.stdout),
              let entries = root["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var infoCache: [String: [String: Any]] = [:]
        func info(_ id: String) -> [String: Any]? {
            if let cached = infoCache[id] { return cached }
            guard let fetched = infoPlist(for: id) else { return nil }
            infoCache[id] = fetched
            return fetched
        }

        // Liveness: `diskutil` keeps listing Xsan *volume* nodes (with full name / size /
        // acfs filesystem) even after the SAN is physically disconnected — there is no
        // per-volume "offline" field. The reliable signal is the backing component LUNs:
        // when the FC cable is pulled they vanish. So if no `Apple_Xsan_Component` LUN is
        // attached, the Xsan volumes that remain are stale and must not be surfaced.
        let xsanComponentsPresent = entries.contains { entry in
            guard let id = entry["DeviceIdentifier"] as? String, let i = info(id) else { return false }
            return isFibreChannelProtocol(i["BusProtocol"] as? String)
                && (i["Content"] as? String) == "Apple_Xsan_Component"
        }

        var disks: [FCDisk] = []

        for entry in entries {
            guard let wholeID = entry["DeviceIdentifier"] as? String,
                  let wholeInfo = info(wholeID) else { continue }

            guard isFibreChannel(entry: entry, wholeInfo: wholeInfo, info: info) else { continue }

            // Skip raw Xsan component LUNs early — before any per-volume work.
            let content = wholeInfo["Content"] as? String ?? ""
            if excludedWholeDiskContent.contains(content) { continue }

            // Hide stale Xsan volume nodes left behind after a physical disconnect.
            if content == xsanVolumeContent && !xsanComponentsPresent { continue }

            let volumeIDs = volumeIdentifiers(entry: entry, wholeID: wholeID, wholeInfo: wholeInfo)
            let volumes = volumeIDs.compactMap { id -> FCVolume? in
                makeVolume(id: id, wholeDiskID: wholeID, info: info(id))
            }
            guard !volumes.isEmpty else { continue }

            let mediaName = (wholeInfo["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)
            let size = (wholeInfo["TotalSize"] as? NSNumber)?.int64Value ?? 0
            let ejectable = (wholeInfo["Ejectable"] as? NSNumber)?.boolValue ?? true

            disks.append(FCDisk(id: wholeID,
                                mediaName: (mediaName?.isEmpty == false ? mediaName! : wholeID),
                                sizeBytes: size,
                                isEjectable: ejectable,
                                volumes: volumes))
        }

        return disks.sorted { $0.id < $1.id }
    }

    /// Determines whether a `diskutil list` entry is backed by a Fibre Channel device.
    /// Handles APFS containers by resolving their physical store's protocol.
    private static func isFibreChannel(entry: [String: Any],
                                       wholeInfo: [String: Any],
                                       info: (String) -> [String: Any]?) -> Bool {
        if isFibreChannelProtocol(wholeInfo["BusProtocol"] as? String) { return true }

        // APFS synthesized containers report their own (virtual) protocol, so follow
        // the physical store down to the backing hardware.
        if let stores = entry["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let storeID = store["DeviceIdentifier"] as? String,
                   let storeInfo = info(wholeDisk(of: storeID, info: info)),
                   isFibreChannelProtocol(storeInfo["BusProtocol"] as? String) {
                    return true
                }
            }
        }
        return false
    }

    /// Collects the mountable volume identifiers within a `diskutil list` entry,
    /// covering classic partitions, APFS volumes, and whole-disk filesystems
    /// (e.g. an Xsan volume, which is itself the whole disk with no partition map).
    private static func volumeIdentifiers(entry: [String: Any],
                                          wholeID: String,
                                          wholeInfo: [String: Any]) -> [String] {
        var ids: [String] = []
        if let partitions = entry["Partitions"] as? [[String: Any]] {
            for part in partitions {
                if let id = part["DeviceIdentifier"] as? String,
                   part["MountPoint"] != nil || (part["VolumeName"] as? String) != nil || part["Content"] != nil {
                    // Skip container partitions that only hold an APFS scheme.
                    if (part["Content"] as? String) == "Apple_APFS" { continue }
                    ids.append(id)
                }
            }
        }
        if let apfs = entry["APFSVolumes"] as? [[String: Any]] {
            for vol in apfs {
                if let id = vol["DeviceIdentifier"] as? String { ids.append(id) }
            }
        }

        // Whole-disk volume fallback: no partitions/APFS volumes, but the disk itself
        // carries a filesystem (Xsan, or an FC drive formatted without a partition map).
        // Reuses the already-fetched whole-disk info — no extra diskutil call.
        if ids.isEmpty {
            let content = wholeInfo["Content"] as? String ?? ""
            let isXsanVolume = content == xsanVolumeContent
            let hasFilesystem = (wholeInfo["FilesystemType"] as? String)?.isEmpty == false
            let hasMountPoint = (wholeInfo["MountPoint"] as? String)?.isEmpty == false
            let hasVolumeName = (wholeInfo["VolumeName"] as? String)?.isEmpty == false
            if isXsanVolume || hasFilesystem || hasMountPoint || hasVolumeName {
                ids.append(wholeID)
            }
        }
        return ids
    }

    private static func makeVolume(id: String, wholeDiskID: String, info: [String: Any]?) -> FCVolume? {
        guard let info else { return nil }
        let mountPoint = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let volumeName = (info["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let size = (info["TotalSize"] as? NSNumber)?.int64Value ?? 0
        return FCVolume(id: id,
                        wholeDiskID: wholeDiskID,
                        name: volumeName ?? id,
                        mountPoint: mountPoint,
                        sizeBytes: size)
    }

    /// Resolves a partition/volume identifier to its whole-disk identifier
    /// (e.g. "disk4s2" -> "disk4").
    private static func wholeDisk(of device: String, info: (String) -> [String: Any]?) -> String {
        if let parent = info(device)?["ParentWholeDisk"] as? String, !parent.isEmpty {
            return parent
        }
        // Fallback: strip the partition suffix.
        if let range = device.range(of: #"s\d+$"#, options: .regularExpression) {
            return String(device[..<range.lowerBound])
        }
        return device
    }

    // MARK: - Operations

    /// Xsan mounts can legitimately take ~60s, so mount/unmount get a generous cap.
    private static let mountTimeout: TimeInterval = 180

    static func mount(_ volume: FCVolume) throws {
        let result = runDiskutil(["mount", volume.id], timeout: mountTimeout)
        try check(result, action: "mount \(volume.name)")
    }

    /// Unmounts a single volume, retrying with `force` when the volume is busy.
    static func unmount(_ volume: FCVolume) throws {
        var result = runDiskutil(["unmount", volume.id], timeout: mountTimeout)
        if !result.succeeded {
            result = runDiskutil(["unmount", "force", volume.id], timeout: mountTimeout)
        }
        try check(result, action: "unmount \(volume.name)")
    }

    /// Makes a disk safe to disconnect: unmounts all of its volumes, then physically
    /// ejects it when the hardware supports ejection. Xsan volumes are not ejectable,
    /// so for them unmounting is the complete and correct safe-disconnect action.
    static func eject(_ disk: FCDisk) throws {
        var result = runDiskutil(["unmountDisk", disk.id], timeout: mountTimeout)
        if !result.succeeded {
            result = runDiskutil(["unmountDisk", "force", disk.id], timeout: mountTimeout)
        }
        try check(result, action: "unmount \(disk.mediaName)")

        guard disk.isEjectable else { return }

        let ejectResult = runDiskutil(["eject", disk.id], timeout: mountTimeout)
        try check(ejectResult, action: "eject \(disk.mediaName)")
    }

    /// Unmounts and ejects every attached FC disk. Returns the disks it failed on.
    /// Used by the shutdown/logout guard where we prioritise finishing over strictness.
    @discardableResult
    static func ejectAllFCDisks() -> [String] {
        var failures: [String] = []
        for disk in enumerateFCDisks() {
            do { try eject(disk) }
            catch { failures.append(disk.mediaName) }
        }
        return failures
    }

    private static func check(_ result: CommandResult, action: String) throws {
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty
                ? "Failed to \(action) (exit \(result.status))."
                : "Failed to \(action): \(detail)"
            throw DiskError(message: message)
        }
    }
}
