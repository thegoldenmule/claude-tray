import SwiftUI
import AppKit
import ServiceManagement

struct UsagePanel: View {
    private let model: UsageModel
    @State private var loginWanted = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?

    init(model: UsageModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Usage")
                .font(.headline)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    UsageRow(title: "Session", window: model.snapshot?.session, now: context.date)
                    UsageRow(title: "Weekly", window: model.snapshot?.weekly, now: context.date)
                }
            }

            statusLine

            HStack {
                Text(updatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.refresh(userInitiated: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.status == .loading)
                .help("Refresh now")
                .accessibilityLabel("Refresh")
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .toggleStyle(.checkbox)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .help(LaunchAtLogin.isAvailable ? "" : "Only available when running the app bundle")
                launchAtLoginNote
            }

            Button("Quit ClaudeTray") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .onAppear {
            // Read the live registration state every time; the user can change it in System Settings.
            syncLaunchAtLogin()
            Task { await model.refresh(userInitiated: true) }
        }
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .stale(let message):
            StatusMessage(message: message, tint: .secondary)
        case .error(let message):
            StatusMessage(message: message, tint: .orange)
        case .loading, .idle:
            if model.snapshot == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .ok:
            EmptyView()
        }
    }

    private var updatedText: String {
        guard let fetchedAt = model.snapshot?.fetchedAt else { return "Not updated yet" }
        let date: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(fetchedAt) ? .omitted : .abbreviated
        return "Updated \(fetchedAt.formatted(date: date, time: .shortened))"
    }

    // MARK: - Launch at login

    /// Reflects the user's choice; the note below explains when the system isn't honoring it.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginWanted },
            set: { newValue in
                LaunchAtLogin.setWanted(newValue)
                syncLaunchAtLogin()
            }
        )
    }

    private func syncLaunchAtLogin() {
        guard LaunchAtLogin.isAvailable else { return }
        loginWanted = LaunchAtLogin.isWanted
        loginStatus = LaunchAtLogin.status
        loginError = LaunchAtLogin.lastError
    }

    /// Explains why the login item isn't active when the box is ticked.
    @ViewBuilder
    private var launchAtLoginNote: some View {
        if !LaunchAtLogin.isAvailable {
            Text("Not available under `swift run`; use `make run`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if loginWanted, loginStatus == .requiresApproval {
            Button("Allow in System Settings › Login Items") {
                SMAppService.openSystemSettingsLoginItems()
            }
            .buttonStyle(.link)
            .font(.caption)
        } else if loginWanted, loginStatus != .enabled, let loginError {
            StatusMessage(message: "Couldn't enable: \(loginError)", tint: .orange)
        }
    }
}

// MARK: - Rows

private struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let window {
                    Text("\(Int(window.percent.rounded()))%")
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            if let window {
                ProgressView(value: min(max(window.percent / 100, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(UsageLevel(percent: window.percent).tint)
                Text(resetCaption(for: window.resetsAt, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatusMessage: View {
    let message: String
    let tint: Color

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(tint)
    }
}

// MARK: - Helpers

private extension UsageLevel {
    var tint: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// "Resets in 2h 14m · 3:30 PM" / "Resets in 3d 4h · Thu 9:00 AM".
@MainActor
private func resetCaption(for resetsAt: Date?, now: Date) -> String {
    guard let rawResetsAt = resetsAt else { return "Reset time unknown" }
    // The API's reset timestamps drift by a fraction of a second between fetches; round to
    // the nearest minute so the caption doesn't flip between e.g. 3:29 PM and 3:30 PM.
    let resetsAt = Date(timeIntervalSinceReferenceDate: (rawResetsAt.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    let remaining = resetsAt.timeIntervalSince(now)
    let relative: String
    if remaining <= 0 {
        relative = "Resetting now"
    } else if remaining < 60 {
        relative = "Resets in <1m"
    } else {
        relative = "Resets in " + (ResetFormatters.countdown.string(from: remaining) ?? "")
    }
    return "\(relative) · \(resetClockText(resetsAt, now: now))"
}

/// Time of day if today, "Tomorrow 3:30 PM" if tomorrow, otherwise weekday + time.
private func resetClockText(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) {
        return time
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow) {
        return "Tomorrow \(time)"
    }
    if date.timeIntervalSince(now) < 6 * 86_400 {
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

@MainActor
private enum ResetFormatters {
    static let countdown: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
