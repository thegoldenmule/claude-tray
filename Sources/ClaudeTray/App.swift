import AppKit
import SwiftUI

@main
struct ClaudeTrayApp: App {
    @State private var model: UsageModel

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
            Image(nsImage: StatusBarRenderer.image(percent: model.snapshot?.session?.percent,
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
