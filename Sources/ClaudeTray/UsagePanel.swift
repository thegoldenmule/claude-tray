import SwiftUI
import AppKit
import ServiceManagement

struct UsagePanel: View {
    private let model: UsageModel
    private let updates: UpdateModel
    @State private var loginWanted = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @AppStorage(SettingsKey.countWeekends) private var countWeekends = false
    @AppStorage(SettingsKey.tolerance) private var tolerance = PaceSettings().tolerance
    @AppStorage(SettingsKey.menuBarMode) private var menuBarMode = MenuBarMode.auto

    init(model: UsageModel, updates: UpdateModel) {
        self.model = model
        self.updates = updates
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

            updateRow

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
            updates.panelOpened()
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

    // MARK: - Updates

    /// The running version and whether a newer release is out. Never downloads anything:
    /// "Update to X…" opens the release page.
    @ViewBuilder
    private var updateRow: some View {
        if updates.app.version != nil {
            HStack(alignment: .firstTextBaseline) {
                Text(updates.app.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                switch updates.state {
                case .available(let release):
                    Button {
                        updates.openReleasePage(release)
                    } label: {
                        Text(verbatim: "Update to \(release.version)…")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Opens the \(release.tag) release page")
                case .checking:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .failed(let reason):
                    checkForUpdatesButton(label: "Couldn't check — retry")
                        .foregroundStyle(.orange)
                        .help(reason)
                case .upToDate:
                    checkForUpdatesButton(label: "Up to date")
                        .help(lastCheckedHelp)
                case .notChecked, .unversioned:
                    checkForUpdatesButton(label: "Check for Updates")
                }
            }
        }
    }

    private func checkForUpdatesButton(label: String) -> some View {
        Button(label) { updates.checkNow() }
            .buttonStyle(.link)
            .font(.caption)
    }

    private var lastCheckedHelp: String {
        guard let checkedAt = updates.cache.checkedAt else { return "Check for updates" }
        return "Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened)). Click to check again."
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

/// The weekly limit with its pace, condensed into the bar: the used % inside the fill, a tick
/// where usage would be at an even pace, and the gap between them labelled ("43 under"), or
/// the overshoot past the tick coloured and labelled ("+12"). One line below says where the
/// week is heading.
private struct WeeklyRow: View {
    let window: UsageWindow?
    let pace: WeeklyPace?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let window {
                    Text(resetText(window))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let window {
                PaceBar(used: window.displayPercent(at: now), pace: pace)
                    .help(pace.map { "Expected by now at an even pace: \(Int($0.expected.rounded()))%" } ?? "")
                if let pace, let summary = summary(pace) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(pace.severity.textTint)
                        .monospacedDigit()
                }
            } else {
                PaceBar(used: 0, pace: nil)
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func resetText(_ window: UsageWindow) -> String {
        if window.hasReset(at: now) { return "Reset — waiting for update" }
        guard let resetsAt = window.resetsAt else { return "Reset time unknown" }
        // Round to the minute: the API's reset timestamps drift by fractions of a second.
        let rounded = Date(timeIntervalSinceReferenceDate: (resetsAt.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        return "Resets \(resetClockText(rounded, now: now))"
    }

    /// Where the week is heading, in one line.
    private func summary(_ pace: WeeklyPace) -> String? {
        var parts: [String] = []
        switch pace.status {
        case .limitReached:
            parts.append("Limit reached")
        case .tooEarly:
            parts.append("Too early to judge pace")
        case .onTrack:
            parts.append("On pace")
        case .under:
            break
        case .over:
            if let runsOutAt = pace.runsOutAt {
                // The projection isn't minute-accurate; show it to the quarter hour.
                let rounded = Date(timeIntervalSinceReferenceDate: (runsOutAt.timeIntervalSinceReferenceDate / 900).rounded() * 900)
                parts.append("Runs out \(resetClockText(rounded, now: now))")
            }
        }
        if pace.pausedUntil != nil, pace.status != .limitReached {
            parts.append("paused for weekend")
        }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var accessibilityText: String {
        guard let window else { return "Weekly usage, no data" }
        var text = "Weekly usage \(Int(window.displayPercent(at: now).rounded())) percent"
        if let pace {
            text += ", \(pace.accessibilitySummary), expected \(Int(pace.expected.rounded())) percent"
            if let summary = summary(pace) { text += ". \(summary)" }
        }
        return text + ". \(resetText(window))"
    }
}

/// A capsule bar that carries its own labels. Segments, left to right:
/// - fill (used, up to the tick when over pace), labelled with the used %;
/// - under pace: the gap up to the tick, lightly tinted, labelled "N under";
/// - over pace: the overshoot past the tick in orange/red, labelled "+N";
/// - the tick at the expected value, drawn over everything and overhanging the bar.
/// A label that doesn't fit its segment is dropped (the used % moves just past the fill).
private struct PaceBar: View {
    let used: Double
    let pace: WeeklyPace?

    private static let height: CGFloat = 18
    private static let tickOverhang: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usedX = width * Self.fraction(used)
            let expectedX = pace.flatMap { $0.status == .limitReached ? nil : width * Self.fraction($0.expected) }
            let isOver = pace?.status == .over || (pace?.status == .limitReached)
            let baseX = isOver ? min(usedX, expectedX ?? usedX) : usedX
            let overshootColor = pace?.severity.tint ?? .accentColor

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)

                // Under pace: the room left before the tick.
                if let expectedX, !isOver, expectedX > usedX {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: expectedX - usedX)
                        .offset(x: usedX)
                }
                // The fill, up to the tick when over pace (all red at the limit).
                Rectangle()
                    .fill(pace?.status == .limitReached ? overshootColor : Color.accentColor)
                    .frame(width: baseX)
                // Over pace: the overshoot past the tick.
                if isOver, usedX > baseX {
                    Rectangle()
                        .fill(overshootColor)
                        .frame(width: usedX - baseX)
                        .offset(x: baseX)
                }

                labels(width: width, usedX: usedX, baseX: baseX, expectedX: expectedX, isOver: isOver)
            }
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if let expectedX {
                    Capsule()
                        .fill(.primary.opacity(pace?.pausedUntil == nil ? 0.85 : 0.35))
                        .frame(width: 2, height: Self.height + 2 * Self.tickOverhang)
                        .offset(x: min(max(expectedX - 1, 0), width - 2))
                }
            }
        }
        .frame(height: Self.height)
        .padding(.vertical, Self.tickOverhang)
    }

    @ViewBuilder
    private func labels(width: CGFloat, usedX: CGFloat, baseX: CGFloat, expectedX: CGFloat?, isOver: Bool) -> some View {
        let percent = "\(Int(used.rounded()))%"
        let fillFits = baseX >= Self.textWidth(percent) + 10
        // Used %, inside the fill, or just past it when the fill is too narrow.
        if fillFits {
            label(percent, color: .white, width: baseX)
        } else if usedX + Self.textWidth(percent) + 10 <= width {
            label(percent, color: .secondary, width: Self.textWidth(percent) + 10)
                .offset(x: max(usedX, 0))
        }
        // The gap or the overshoot, labelled with how far off pace usage is.
        if fillFits, let pace, let expectedX {
            let points = Int(abs(pace.delta).rounded())
            if isOver, pace.status == .over, usedX > baseX {
                fitted(["+\(points)"], color: .white, from: baseX, to: usedX)
            } else if !isOver, pace.status == .under {
                fitted(["\(points) under", "−\(points)"], color: .secondary, from: usedX, to: expectedX)
            }
        }
    }

    /// The first of `candidates` that fits between `from` and `to`, centred; nothing if none fits.
    @ViewBuilder
    private func fitted(_ candidates: [String], color: some ShapeStyle, from: CGFloat, to: CGFloat) -> some View {
        let available = to - from
        if let text = candidates.first(where: { Self.textWidth($0) + 4 <= available }) {
            label(text, color: color, width: available)
                .offset(x: from)
        }
    }

    private func label(_ text: String, color: some ShapeStyle, width: CGFloat) -> some View {
        Text(verbatim: text)
            .font(Self.labelFont)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: max(width, 0), height: Self.height)
    }

    private static let labelFont = Font.system(size: 11, weight: .semibold)
    private static let measureFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: measureFont]).width)
    }

    private static func fraction(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent / 100, 0), 1))
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
