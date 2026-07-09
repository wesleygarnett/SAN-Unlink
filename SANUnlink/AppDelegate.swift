import AppKit
import Carbon.HIToolbox

/// Handles the logout / shutdown guard: before the Mac powers off we unmount every
/// Fibre Channel volume so macOS does not hang on a still-connected SANlink / Xsan
/// device.
///
/// Critically, this only runs for a genuine system logout / restart / shutdown — a
/// manual "Quit" of the app must never unmount the user's (often production) volumes.
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
        // Only guard against real logout/shutdown; a user-initiated Quit must leave
        // the mounted volumes untouched.
        guard isSystemLogoutOrShutdown() else { return .terminateNow }

        // Nothing to do if no FC volumes are attached — terminate immediately.
        guard !DiskService.enumerateFCDisks().isEmpty else { return .terminateNow }

        let deadline = DispatchTime.now() + ejectTimeout
        DispatchQueue.global(qos: .userInitiated).async {
            DiskService.ejectAllFCDisks()
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }

        // Safety net: reply anyway if unmounting stalls past the timeout.
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    @objc private func willPowerOff(_ notification: Notification) {
        DiskService.ejectAllFCDisks()
    }

    /// Inspects the Apple Event that triggered termination. macOS sends a `quit`
    /// event carrying a `kAEQuitReason` when the user logs out / restarts / shuts
    /// down; an ordinary Quit carries no such reason.
    private func isSystemLogoutOrShutdown() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }

        let systemReasons: Set<OSType> = [
            OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
            OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown),
        ]
        return systemReasons.contains(reason.enumCodeValue)
    }
}
