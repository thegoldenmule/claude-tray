import SwiftUI
import AppKit
import ServiceManagement

struct UsagePanel: View {
    private let model: UsageModel
    @State private var loginWanted = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @AppStorage(SettingsKey.countWeekends) private var countWeekends = false
    @AppStorage(SettingsKey.tolerance) private var tolerance = PaceSettings().tolerance
    @AppStorage(SettingsKey.menuBarMode) private var menuBarMode = MenuBarMode.auto

    init(model: UsageModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Usage")
                .font(.headline)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    // Accounts without a session limit get only the weekly row.
                    if model.snapshot == nil || model.snapshot?.session != nil {
                        UsageRow(title: "Session", window: model.snapshot?.session, now: context.date)
                    }
                    WeeklyRow(window: model.snapshot?.weekly,
                              pace: model.weeklyPace(at: context.date, settings: paceSettings),
                              now: context.date)
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

            paceSettingsSection

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

    // MARK: - Pace settings

    private var paceSettings: PaceSettings {
        PaceSettings(countWeekends: countWeekends, tolerance: tolerance)
    }

    private var paceSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Count weekends in weekly pace", isOn: $countWeekends)
                .toggleStyle(.checkbox)
                .help("Off: the weekly budget is paced over weekdays only, and pace pauses on weekends.")
            Picker("Pace tolerance", selection: $tolerance) {
                ForEach(PaceSettings.toleranceChoices, id: \.self) { points in
                    Text("±\(Int(points))%").tag(points)
                }
            }
            .help("On pace means this week's rate ends the week within this much of the full budget")
            Picker("Menu bar shows", selection: $menuBarMode) {
                ForEach(MenuBarMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help("Auto shows weekly pace when there's no session limit, or when the weekly limit will run out first")
        }
        .pickerStyle(.menu)
        .fixedSize()
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
                    Text("\(Int(window.displayPercent(at: now).rounded()))%")
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            if let window {
                let percent = window.displayPercent(at: now)
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(UsageLevel(percent: percent).tint)
                Text(window.hasReset(at: now) ? "Reset — waiting for update" : resetCaption(for: window.resetsAt, now: now))
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

/// The weekly limit with its pace: a bar with a tick where usage would be at an even pace,
/// then how far off pace it is and where it's heading.
private struct WeeklyRow: View {
    let window: UsageWindow?
    let pace: WeeklyPace?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let window {
                    Text("\(Int(window.displayPercent(at: now).rounded()))%")
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            if let window {
                let percent = window.displayPercent(at: now)
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(pace?.severity.tint ?? UsageLevel(percent: percent).tint)
                    .overlay { paceTick }
                if let pace {
                    paceDetails(pace)
                }
                Text(window.hasReset(at: now) ? "Reset — waiting for update" : resetCaption(for: window.resetsAt, now: now))
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

    @ViewBuilder
    private var paceTick: some View {
        if let pace, pace.status != .limitReached {
            GeometryReader { geometry in
                Capsule()
                    .fill(.primary.opacity(pace.pausedUntil == nil ? 0.85 : 0.35))
                    .frame(width: 2, height: 12)
                    .position(x: geometry.size.width * min(max(pace.expected / 100, 0), 1),
                              y: geometry.size.height / 2)
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func paceDetails(_ pace: WeeklyPace) -> some View {
        Text(headline(pace))
            .font(.caption.weight(.medium))
            .foregroundStyle(pace.severity.textTint)
        if let pausedUntil = pace.pausedUntil {
            caption(pausedUntil >= pace.resetsAt
                    ? "Weekend — pace paused until reset"
                    : "Weekend — pace paused until \(resetClockText(pausedUntil, now: now))")
        }
        if let runway = runway(pace) {
            caption(runway)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headline(_ pace: WeeklyPace) -> String {
        let expected = "expected \(Int(pace.expected.rounded()))%"
        let points = Int(abs(pace.delta).rounded())
        switch pace.status {
        case .limitReached: return "Limit reached"
        case .tooEarly: return "Too early to tell pace · \(expected)"
        case .onTrack: return "On pace · \(expected)"
        case .over: return "\(points) pts over pace · \(expected)"
        case .under: return "\(points) pts under pace · \(expected)"
        }
    }

    /// "At this rate, runs out Thu 2:15 PM" / "At this rate, ends the week at 47%".
    private func runway(_ pace: WeeklyPace) -> String? {
        if let runsOutAt = pace.runsOutAt {
            // The projection isn't minute-accurate; show it to the quarter hour.
            let rounded = Date(timeIntervalSinceReferenceDate: (runsOutAt.timeIntervalSinceReferenceDate / 900).rounded() * 900)
            return "At this rate, runs out \(resetClockText(rounded, now: now))"
        }
        if let projected = pace.projectedAtReset {
            return "At this rate, ends the week at \(Int(min(projected, 100).rounded()))%"
        }
        return nil
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

private extension PaceSeverity {
    var tint: Color {
        switch self {
        case .calm: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }

    var textTint: Color {
        switch self {
        case .calm: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

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
