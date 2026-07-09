import AppKit

/// Handles the logout / shutdown guard: before the app is allowed to terminate we
/// unmount and eject every Fibre Channel disk so macOS does not hang on a still-
/// connected SANlink device.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Upper bound on how long we delay termination, so we never hang the very
    /// shutdown we are trying to protect.
    private let ejectTimeout: TimeInterval = 12.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(willPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing to do if no FC disks are attached — terminate immediately.
        guard !DiskService.enumerateFCDisks().isEmpty else { return .terminateNow }

        let deadline = DispatchTime.now() + ejectTimeout
        DispatchQueue.global(qos: .userInitiated).async {
            DiskService.ejectAllFCDisks()
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }

        // Safety net: reply anyway if ejection stalls past the timeout.
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    @objc private func willPowerOff(_ notification: Notification) {
        DiskService.ejectAllFCDisks()
    }
}
