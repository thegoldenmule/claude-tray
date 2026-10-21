import Foundation
import OSLog
import ServiceManagement

/// "Launch at login", kept pointing at whichever copy of the app is running.
///
/// The user's choice is persisted in UserDefaults and reconciled with the
/// `SMAppService.mainApp` registration at every launch. Background Task Management
/// keys the login item by bundle ID, not path: `status` reports `.enabled` from any
/// copy with our bundle ID even when the registered URL points at another (possibly
/// deleted) copy. Calling `register()` again from the running copy re-points it, so
/// we do that whenever this bundle isn't the one we last registered.
@MainActor
enum LaunchAtLogin {
    private static let intentKey = "launchAtLogin"
    private static let registeredPathKey = "launchAtLoginBundlePath"
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
        // Registered before the choice was persisted: adopt the system's state.
        if defaults.object(forKey: intentKey) == nil {
            guard status == .enabled else { return }
            defaults.set(true, forKey: intentKey)
        }
        guard isWanted else { return }
        if status == .enabled, defaults.string(forKey: registeredPathKey) == bundlePath {
            log.info("Login item already registered for \(bundlePath, privacy: .public)")
            return
        }
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
            UserDefaults.standard.removeObject(forKey: registeredPathKey)
            // Throws if nothing is registered; either way the result is "off".
            try? SMAppService.mainApp.unregister()
        }
    }

    private static func register() {
        do {
            // Also re-points an existing registration at this bundle.
            try SMAppService.mainApp.register()
            lastError = nil
            UserDefaults.standard.set(bundlePath, forKey: registeredPathKey)
            log.notice("Registered login item for \(bundlePath, privacy: .public); status \(status.rawValue)")
        } catch {
            lastError = error.localizedDescription
            log.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
