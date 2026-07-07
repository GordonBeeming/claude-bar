import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp`. Registering only succeeds from inside a
/// real `.app` bundle — under a bare `swift run` binary it throws — so callers must
/// check `UsageViewModel.launchAtLoginAvailable` before touching this.
@MainActor
struct LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
