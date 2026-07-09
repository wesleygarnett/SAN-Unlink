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

    /// The `BusProtocol` value that identifies a Fibre Channel attachment.
    static let fibreChannelProtocol = "Fibre Channel"

    // MARK: - Command execution

    @discardableResult
    static func runDiskutil(_ args: [String]) -> CommandResult {
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

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

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

    /// Returns every Fibre Channel disk currently attached, with its mountable volumes.
    static func enumerateFCDisks() -> [FCDisk] {
        let listResult = runDiskutil(["list", "-plist"])
        guard listResult.succeeded,
              let root = parsePlist(listResult.stdout),
              let entries = root["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var disks: [FCDisk] = []

        for entry in entries {
            guard let wholeID = entry["DeviceIdentifier"] as? String else { continue }
            guard isFibreChannel(entry: entry, wholeID: wholeID) else { continue }

            let volumeIDs = volumeIdentifiers(in: entry)
            let volumes = volumeIDs.compactMap { makeVolume(id: $0, wholeDiskID: wholeID) }

            // Only surface disks that actually expose mountable volumes.
            guard !volumes.isEmpty else { continue }

            let info = infoPlist(for: wholeID)
            let mediaName = (info?["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)
            let size = (info?["TotalSize"] as? NSNumber)?.int64Value ?? 0

            disks.append(FCDisk(id: wholeID,
                                mediaName: (mediaName?.isEmpty == false ? mediaName! : wholeID),
                                sizeBytes: size,
                                volumes: volumes))
        }

        return disks.sorted { $0.id < $1.id }
    }

    /// Convenience: all FC volumes flattened across disks.
    static func enumerateFCVolumes() -> [FCVolume] {
        enumerateFCDisks().flatMap(\.volumes)
    }

    /// Determines whether a `diskutil list` entry is backed by a Fibre Channel device.
    /// Handles APFS containers by resolving their physical store's protocol.
    private static func isFibreChannel(entry: [String: Any], wholeID: String) -> Bool {
        if busProtocol(of: wholeID) == fibreChannelProtocol { return true }

        // APFS synthesized containers report their own (virtual) protocol, so follow
        // the physical store down to the backing hardware.
        if let stores = entry["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let storeID = store["DeviceIdentifier"] as? String {
                    let storeWhole = wholeDisk(of: storeID)
                    if busProtocol(of: storeWhole) == fibreChannelProtocol { return true }
                }
            }
        }
        return false
    }

    private static func busProtocol(of device: String) -> String? {
        infoPlist(for: device)?["BusProtocol"] as? String
    }

    /// Collects the mountable volume identifiers within a `diskutil list` entry,
    /// covering both classic partitions and APFS volumes.
    private static func volumeIdentifiers(in entry: [String: Any]) -> [String] {
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
        return ids
    }

    private static func makeVolume(id: String, wholeDiskID: String) -> FCVolume? {
        guard let info = infoPlist(for: id) else { return nil }
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
    private static func wholeDisk(of device: String) -> String {
        if let info = infoPlist(for: device),
           let parent = info["ParentWholeDisk"] as? String, !parent.isEmpty {
            return parent
        }
        // Fallback: strip the partition suffix.
        if let range = device.range(of: #"s\d+$"#, options: .regularExpression) {
            return String(device[..<range.lowerBound])
        }
        return device
    }

    // MARK: - Operations

    static func mount(_ volume: FCVolume) throws {
        let result = runDiskutil(["mount", volume.id])
        try check(result, action: "mount \(volume.name)")
    }

    /// Unmounts a single volume, retrying with `force` when the volume is busy.
    static func unmount(_ volume: FCVolume) throws {
        var result = runDiskutil(["unmount", volume.id])
        if !result.succeeded {
            result = runDiskutil(["unmount", "force", volume.id])
        }
        try check(result, action: "unmount \(volume.name)")
    }

    /// Ejects a whole disk after unmounting all of its volumes — this is what makes
    /// the device safe to physically disconnect. Retries with `force`.
    static func eject(_ disk: FCDisk) throws {
        var result = runDiskutil(["unmountDisk", disk.id])
        if !result.succeeded {
            result = runDiskutil(["unmountDisk", "force", disk.id])
        }
        try check(result, action: "unmount \(disk.mediaName)")

        let ejectResult = runDiskutil(["eject", disk.id])
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
