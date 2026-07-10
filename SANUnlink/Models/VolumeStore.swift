import Foundation
import Combine

/// An in-flight mount / unmount operation on a specific volume, used to drive the
/// status UI.
struct VolumeOperation: Equatable {
    enum Kind { case mounting, unmounting }
    let kind: Kind
    let volumeName: String
    let started: Date

    var verb: String { kind == .mounting ? "Mounting" : "Unmounting" }
}

/// Observable source of truth for the menu bar UI. Owns the current set of Fibre
/// Channel / Xsan volumes, keeps them fresh via Disk Arbitration plus a backup
/// timer, and exposes mount / unmount / eject actions that run off the main thread.
///
/// Xsan mounts can take up to a minute and `diskutil` enumeration flickers while a
/// volume transitions, so refreshes are made resilient: a transient empty result
/// never blanks the list, and volumes with an operation in flight are always kept
/// visible with their status.
@MainActor
final class VolumeStore: ObservableObject {

    @Published private(set) var disks: [FCDisk] = []
    @Published private(set) var operations: [String: VolumeOperation] = [:]  // key: volume id
    @Published var lastError: String?
    @Published var launchAtLogin: Bool

    private let watcher = DiskArbitrationWatcher()
    private var backupTimer: Timer?
    private let workQueue = DispatchQueue(label: "com.sanunlink.disk-work", qos: .userInitiated)
    private var emptyVerifyToken = 0
    private var isRefreshing = false
    private var refreshQueued = false

    var isBusy: Bool { !operations.isEmpty }

    var volumes: [FCVolume] { disks.flatMap(\.volumes) }

    var hasMountedVolumes: Bool { disks.contains(where: \.hasMountedVolume) }

    func operation(for volumeID: String) -> VolumeOperation? { operations[volumeID] }

    init() {
        launchAtLogin = LoginItem.isEnabled
        watcher.onChange = { [weak self] in self?.refresh() }
        watcher.start()
        refresh()

        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        backupTimer = timer
    }

    deinit {
        backupTimer?.invalidate()
        watcher.stop()
    }

    // MARK: - Refresh

    /// Coalesces refreshes: at most one enumeration runs at a time, and a burst of
    /// Disk Arbitration events collapses into a single follow-up scan instead of
    /// piling dozens of expensive scans onto the work queue.
    func refresh() {
        guard !isRefreshing else { refreshQueued = true; return }
        isRefreshing = true
        workQueue.async {
            let fresh = DiskService.enumerateFCDisks()
            Task { @MainActor in
                self.applyRefresh(fresh)
                self.isRefreshing = false
                if self.refreshQueued {
                    self.refreshQueued = false
                    self.refresh()
                }
            }
        }
    }

    /// Commits an enumeration result to `disks`, guarding against the transient
    /// empties and dropouts that occur while Xsan volumes mount/unmount.
    private func applyRefresh(_ fresh: [FCDisk]) {
        if fresh.isEmpty {
            // Don't blank an existing list on a momentary empty — confirm first.
            guard disks.isEmpty else { return verifyEmptyLater() }
            return
        }
        disks = merge(fresh: fresh, keepingActiveVolumesFrom: disks)
    }

    /// Re-checks after a short delay before accepting that all volumes are gone, so a
    /// real disconnect still clears the list but a transition blip does not.
    private func verifyEmptyLater() {
        emptyVerifyToken += 1
        let token = emptyVerifyToken
        workQueue.asyncAfter(deadline: .now() + 3) {
            let recheck = DiskService.enumerateFCDisks()
            Task { @MainActor in
                guard token == self.emptyVerifyToken else { return }
                if recheck.isEmpty {
                    if self.operations.isEmpty { self.disks = [] }
                } else {
                    self.disks = self.merge(fresh: recheck, keepingActiveVolumesFrom: self.disks)
                }
            }
        }
    }

    /// Keeps any volume that has an operation in flight visible even if `diskutil`
    /// momentarily stops reporting it mid-transition.
    private func merge(fresh: [FCDisk], keepingActiveVolumesFrom old: [FCDisk]) -> [FCDisk] {
        guard !operations.isEmpty else { return fresh }
        var result = fresh
        let present = Set(fresh.flatMap { $0.volumes.map(\.id) })

        for oldDisk in old {
            for vol in oldDisk.volumes where operations[vol.id] != nil && !present.contains(vol.id) {
                if let idx = result.firstIndex(where: { $0.id == oldDisk.id }) {
                    result[idx].volumes.append(vol)
                } else {
                    result.append(FCDisk(id: oldDisk.id,
                                         mediaName: oldDisk.mediaName,
                                         sizeBytes: oldDisk.sizeBytes,
                                         isEjectable: oldDisk.isEjectable,
                                         volumes: [vol]))
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    // MARK: - Actions

    func toggle(_ volume: FCVolume) {
        let kind: VolumeOperation.Kind = volume.isMounted ? .unmounting : .mounting
        operations[volume.id] = VolumeOperation(kind: kind, volumeName: volume.name, started: Date())
        lastError = nil

        workQueue.async {
            var failure: String?
            do {
                if volume.isMounted { try DiskService.unmount(volume) }
                else { try DiskService.mount(volume) }
            } catch { failure = error.localizedDescription }
            let fresh = DiskService.enumerateFCDisks()
            Task { @MainActor in
                self.operations[volume.id] = nil
                self.applyRefresh(fresh)
                if let failure { self.lastError = failure }
            }
        }
    }

    func mountAll() {
        let unmounted = volumes.filter { !$0.isMounted }
        guard !unmounted.isEmpty else { return }
        for v in unmounted {
            operations[v.id] = VolumeOperation(kind: .mounting, volumeName: v.name, started: Date())
        }
        lastError = nil

        workQueue.async {
            var failures: [String] = []
            for v in unmounted {
                do { try DiskService.mount(v) } catch { failures.append(v.name) }
            }
            let fresh = DiskService.enumerateFCDisks()
            Task { @MainActor in
                for v in unmounted { self.operations[v.id] = nil }
                self.applyRefresh(fresh)
                if !failures.isEmpty {
                    self.lastError = "Could not mount: \(failures.joined(separator: ", "))"
                }
            }
        }
    }

    func ejectAll() {
        let mounted = volumes.filter(\.isMounted)
        guard !mounted.isEmpty else { return }
        for v in mounted {
            operations[v.id] = VolumeOperation(kind: .unmounting, volumeName: v.name, started: Date())
        }
        lastError = nil

        workQueue.async {
            let failures = DiskService.ejectAllFCDisks()
            let fresh = DiskService.enumerateFCDisks()
            Task { @MainActor in
                for v in mounted { self.operations[v.id] = nil }
                self.applyRefresh(fresh)
                if !failures.isEmpty {
                    self.lastError = "Could not unmount: \(failures.joined(separator: ", "))"
                }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let success = LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
        if !success { lastError = "Could not update the Launch at login setting." }
    }

    func clearError() { lastError = nil }
}
