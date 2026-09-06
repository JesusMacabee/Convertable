import Foundation
import ServiceManagement

/// SMAppService needs a bundled, signed app; from a bare binary it is simply unavailable.
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        guard isAvailable else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
