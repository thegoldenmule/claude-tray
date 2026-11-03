import AppKit
import SwiftUI

@main
struct ClaudeTrayApp: App {
    @State private var model: UsageModel
    @State private var clock = MinuteClock()
    @AppStorage(SettingsKey.countWeekends) private var countWeekends = false
    @AppStorage(SettingsKey.tolerance) private var tolerance = PaceSettings().tolerance
    @AppStorage(SettingsKey.menuBarMode) private var menuBarMode = MenuBarMode.auto

    init() {
        // Start polling at launch, not on first click: the panel's onAppear only
        // fires when the user opens it, and modifiers like .task on a MenuBarExtra
        // label aren't reliably run (the label is flattened into the status item).
        // App.init runs once on the main actor, so create the model here, hand it
        // to @State, and start it directly. start() is idempotent.
        let model = UsageModel()
        _model = State(initialValue: model)
        model.start()
        // Re-register the login item from this copy if the user wants it.
        LaunchAtLogin.reconcile()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(model: model)
        } label: {
            // Only Image/Text survive in a MenuBarExtra label, so the bar is
            // pre-rendered into an NSImage.
            Image(nsImage: StatusBarRenderer.image(content: statusBarContent, stale: isStale))
        }
        .menuBarExtraStyle(.window)
    }

    private var statusBarContent: StatusBarContent {
        let now = clock.now
        let snapshot = model.snapshot
        let session = snapshot?.session?.displayPercent(at: now)
        let pace = model.weeklyPace(at: now, settings: PaceSettings(countWeekends: countWeekends, tolerance: tolerance))
        let showWeekly: Bool
        switch menuBarMode {
        case .session: showWeekly = false
        case .weekly: showWeekly = true
        case .auto:
            // Weekly when there's no session limit, or when the weekly limit is the urgent one.
            let weeklyIsUrgent = pace?.severity == .critical && UsageLevel(percent: session ?? 0) != .critical
            showWeekly = snapshot != nil && (snapshot?.session == nil || weeklyIsUrgent)
        }
        return showWeekly
            ? .weekly(snapshot?.weekly?.displayPercent(at: now), pace: pace)
            : .session(session)
    }

    private var isStale: Bool {
        switch model.status {
        case .stale, .error: true
        case .idle, .loading, .ok: false
        }
    }
}

/// Ticks once a minute so the label re-renders when a window's reset time passes,
/// which changes nothing in the model. (A TimelineView in a MenuBarExtra label is
/// only evaluated once.)
@MainActor @Observable
private final class MinuteClock {
    private(set) var now = Date()

    init() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }
}
