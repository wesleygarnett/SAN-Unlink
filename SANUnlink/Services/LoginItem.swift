import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` for the "Launch at login" toggle. Keeping the
/// app running at login is what allows the shutdown/logout guard to fire.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Returns `true` on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
            return false
        }
    }
}
