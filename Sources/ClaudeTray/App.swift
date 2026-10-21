import AppKit
import SwiftUI

@main
struct ClaudeTrayApp: App {
    @State private var model: UsageModel
    @State private var clock = MinuteClock()

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
            Image(nsImage: StatusBarRenderer.image(percent: model.snapshot?.session?.displayPercent(at: clock.now),
                                                   stale: isStale))
        }
        .menuBarExtraStyle(.window)
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
