import Foundation
import OSLog
import ServiceManagement

/// "Launch at login", kept pointing at whichever copy of the app is running.
///
/// The user's choice is persisted in UserDefaults and reconciled with the
/// `SMAppService.mainApp` registration at every launch. Background Task Management
/// keys the login item by bundle ID, not path: `status` reports `.enabled` from any
/// copy with our bundle ID even when the registered URL points at another (possibly
/// deleted) copy, and macOS can silently re-point it at any copy it finds. Calling
/// `register()` from the running copy re-points it here, so we do that every launch,
/// unless the user has switched the item off in System Settings › Login Items.
@MainActor
enum LaunchAtLogin {
    private static let intentKey = "launchAtLogin"
    private static let log = Logger(subsystem: "com.thegoldenmule.ClaudeTray", category: "LaunchAtLogin")

    /// Last registration failure, for the panel to show. Cleared on success.
    private(set) static var lastError: String?

    /// SMAppService.mainApp needs an app bundle; `swift run` launches a bare executable.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// What the user asked for (independent of whether the system honored it).
    static var isWanted: Bool { UserDefaults.standard.bool(forKey: intentKey) }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    private static var bundlePath: String { Bundle.main.bundleURL.path }

    /// Call once at launch. Never opens System Settings; approval prompts are left to the toggle.
    static func reconcile() {
        guard isAvailable else { return }
        let defaults = UserDefaults.standard
        // No longer used: registration is unconditional now.
        defaults.removeObject(forKey: "launchAtLoginBundlePath")
        // Registered before the choice was persisted: adopt the system's state.
        if defaults.object(forKey: intentKey) == nil {
            guard status == .enabled else { return }
            defaults.set(true, forKey: intentKey)
        }
        guard isWanted else { return }
        // Switched off in System Settings › Login Items: respect that rather than
        // re-registering over it every launch. The panel offers a link to re-allow it.
        if status == .requiresApproval {
            log.notice("Login item needs approval in System Settings; not re-registering")
            return
        }
        // Otherwise unconditional: status and any remembered path can't tell us where the
        // registered URL points, and register() is a cheap no-op-or-fix when enabled.
        register()
    }

    /// Persists the user's choice and applies it.
    static func setWanted(_ wanted: Bool) {
        guard isAvailable else { return }
        UserDefaults.standard.set(wanted, forKey: intentKey)
        if wanted {
            register()
            if status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            lastError = nil
            // Throws if nothing is registered; either way the result is "off".
            try? SMAppService.mainApp.unregister()
        }
    }

    private static func register() {
        do {
            // Also re-points an existing registration at this bundle.
            try SMAppService.mainApp.register()
            lastError = nil
            log.notice("Registered login item for \(bundlePath, privacy: .public); status \(status.rawValue)")
        } catch {
            lastError = error.localizedDescription
            log.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
