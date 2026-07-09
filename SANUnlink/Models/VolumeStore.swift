import Foundation
import Combine

/// Observable source of truth for the menu bar UI. Owns the current set of Fibre
/// Channel disks, keeps them fresh via Disk Arbitration plus a backup timer, and
/// exposes mount / unmount / eject actions that run off the main thread.
@MainActor
final class VolumeStore: ObservableObject {

    @Published private(set) var disks: [FCDisk] = []
    @Published private(set) var isBusy = false
    @Published var lastError: String?
    @Published var launchAtLogin: Bool

    private let watcher = DiskArbitrationWatcher()
    private var backupTimer: Timer?
    private let workQueue = DispatchQueue(label: "com.sanunlink.disk-work", qos: .userInitiated)

    /// Flattened list of volumes across all FC disks.
    var volumes: [FCVolume] { disks.flatMap(\.volumes) }

    /// True when any FC volume is currently mounted (drives Menu bar icon state).
    var hasMountedVolumes: Bool { disks.contains(where: \.hasMountedVolume) }

    init() {
        launchAtLogin = LoginItem.isEnabled
        watcher.onChange = { [weak self] in
            self?.refresh()
        }
        watcher.start()
        refresh()

        // Backup poll in case a Disk Arbitration event is missed.
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

    func refresh() {
        workQueue.async {
            let fresh = DiskService.enumerateFCDisks()
            Task { @MainActor in self.disks = fresh }
        }
    }

    // MARK: - Actions

    func toggle(_ volume: FCVolume) {
        perform {
            if volume.isMounted {
                try DiskService.unmount(volume)
            } else {
                try DiskService.mount(volume)
            }
        }
    }

    func eject(_ disk: FCDisk) {
        perform { try DiskService.eject(disk) }
    }

    func ejectAll() {
        perform {
            let failures = DiskService.ejectAllFCDisks()
            if !failures.isEmpty {
                throw DiskError(message: "Could not eject: \(failures.joined(separator: ", "))")
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let success = LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
        if !success {
            lastError = "Could not update the Launch at login setting."
        }
    }

    func clearError() { lastError = nil }

    /// Runs a throwing disk operation off the main thread, then refreshes and
    /// surfaces any error to the UI.
    private func perform(_ work: @escaping () throws -> Void) {
        isBusy = true
        lastError = nil
        workQueue.async {
            var failure: String?
            do { try work() } catch { failure = error.localizedDescription }
            let fresh = DiskService.enumerateFCDisks()
            Task { @MainActor in
                self.disks = fresh
                self.isBusy = false
                if let failure { self.lastError = failure }
            }
        }
    }
}
