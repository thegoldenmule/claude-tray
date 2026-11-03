import AppKit

/// Severity bucket for a usage percentage. Shared by the status bar renderer and the panel
/// so both use identical thresholds.
enum UsageLevel: Sendable, Equatable {
    case normal     // < 80%
    case warning    // >= 80%
    case critical   // >= 95%

    init(percent: Double) {
        if percent >= 95 {
            self = .critical
        } else if percent >= 80 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

extension UsageWindow {
    /// True once `resetsAt` has passed: the usage counted here no longer applies,
    /// even if no newer snapshot has arrived yet (e.g. offline overnight).
    func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// The percentage to show at `now`: 0 once the window has reset.
    func displayPercent(at now: Date) -> Double {
        hasReset(at: now) ? 0 : percent
    }
}

/// What the status item shows.
enum StatusBarContent: Sendable, Equatable {
    /// Session (5-hour) usage, 0...100, or nil if unknown.
    case session(Double?)
    /// Weekly usage, with its pace when there is one.
    case weekly(Double?, pace: WeeklyPace?)
}

extension WeeklyPace {
    /// Short label for the menu bar: "+30" over / "−46" under / "✓" on pace; the plain
    /// percentage when it's too early to judge or the limit is reached.
    var menuBarLabel: String {
        switch status {
        case .tooEarly, .limitReached: "\(Int(used.rounded()))%"
        case .onTrack: "✓"
        case .over, .under: Self.signedPoints(delta)
        }
    }

    /// "+30" / "−46" / "0" (with a real minus sign).
    static func signedPoints(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded > 0 { return "+\(rounded)" }
        if rounded < 0 { return "\u{2212}\(-rounded)" }
        return "0"
    }

    var accessibilitySummary: String {
        let points = Int(abs(delta).rounded())
        switch status {
        case .tooEarly: return "too early to tell pace"
        case .limitReached: return "limit reached"
        case .onTrack: return "on pace"
        case .over: return "\(points) points over pace" + (runsOutAt != nil ? ", will run out before reset" : "")
        case .under: return "\(points) points under pace"
        }
    }
}

enum StatusBarRenderer {
    private static let barWidth: CGFloat = 36
    private static let barHeight: CGFloat = 8
    private static let imageHeight: CGFloat = 18
    private static let labelGap: CGFloat = 4
    private static let staleAlpha: CGFloat = 0.4
    /// The pace tick overhangs the bar by this much above and below.
    private static let tickOverhang: CGFloat = 3
    private static let tickWidth: CGFloat = 1.5
    /// Gap knocked out of the bar around the tick so it reads over the fill.
    private static let tickGap: CGFloat = 3

    private enum Fill { case template, orange, red }

    /// stale: draw dimmed.
    @MainActor static func image(content: StatusBarContent, stale: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        let percent: Double?
        let label: String
        var fill: Fill = .template
        var tick: (fraction: Double, dimmed: Bool)?
        var description: String
        switch content {
        case .session(let value):
            percent = value
            label = value.map { "\(Int($0.rounded()))%" } ?? "–"
            fill = value.map { Self.fill(for: UsageLevel(percent: $0)) } ?? .template
            description = value.map { "Claude session usage \(Int($0.rounded())) percent" }
                ?? "Claude session usage unavailable"
        case .weekly(let value, let pace):
            percent = value
            if let pace {
                label = pace.menuBarLabel
                switch pace.severity {
                case .calm: fill = .template
                case .warning: fill = .orange
                case .critical: fill = .red
                }
                if pace.status != .limitReached {
                    tick = (min(max(pace.expected / 100, 0), 1), pace.pausedUntil != nil)
                }
                description = "Claude weekly usage \(Int(pace.used.rounded())) percent, \(pace.accessibilitySummary)"
            } else {
                label = value.map { "\(Int($0.rounded()))%" } ?? "–"
                fill = value.map { Self.fill(for: UsageLevel(percent: $0)) } ?? .template
                description = value.map { "Claude weekly usage \(Int($0.rounded())) percent" }
                    ?? "Claude weekly usage unavailable"
            }
        }

        // Reserve room for the widest label so the status item never changes width as the value moves.
        let measureAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let reservedWidth = ["100%", "+100"].map { ceil(($0 as NSString).size(withAttributes: measureAttrs).width) }.max() ?? 0
        let labelWidth = ceil((label as NSString).size(withAttributes: measureAttrs).width)
        let textAreaWidth = max(reservedWidth, labelWidth)
        let size = NSSize(width: barWidth + labelGap + textAreaWidth, height: imageHeight)

        // Colored rendering only for fresh values that need attention; everything else is a template.
        let colored = !stale && fill != .template
        let fraction = min(max((percent ?? 0) / 100, 0), 1)

        let image = NSImage(size: size, flipped: false) { _ in
            // Template images only use alpha; color is irrelevant, so draw in black.
            // Colored images resolve labelColor against the current drawing appearance,
            // which AppKit sets to the menu bar's appearance when it draws the image.
            let base: NSColor = colored ? .labelColor : .black
            let contentAlpha: CGFloat = stale ? staleAlpha : 1

            let barY = (imageHeight - barHeight) / 2
            let barRect = NSRect(x: 0, y: barY, width: barWidth, height: barHeight)
            let radius = barHeight / 2

            // Track outline (inset half a point so the 1pt stroke lands on pixel boundaries).
            let outline = NSBezierPath(roundedRect: barRect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            base.withAlphaComponent(colored ? 0.55 : (stale ? 0.5 : 0.85)).setStroke()
            outline.stroke()

            // Fill, clipped to the pill so the leading edge is rounded and the trailing edge square.
            if fraction > 0 {
                let fillColor: NSColor
                switch (colored, fill) {
                case (true, .red):    fillColor = .systemRed
                case (true, .orange): fillColor = .systemOrange
                default:              fillColor = NSColor.black.withAlphaComponent(contentAlpha)
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).addClip()
                fillColor.setFill()
                // Never thinner than the pill's height so tiny values still read as a dot.
                NSRect(x: 0, y: barY, width: max(barHeight, barWidth * fraction), height: barHeight).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Pace tick: where usage would be at an even pace. Taller than the bar, with a
            // clear gap cut around it so it shows against both the fill and the track.
            if let tick {
                let x = min(max(barWidth * tick.fraction, tickWidth), barWidth - tickWidth)
                NSRect(x: x - tickGap / 2, y: barY, width: tickGap, height: barHeight).fill(using: .clear)
                base.withAlphaComponent(contentAlpha * (tick.dimmed ? 0.45 : 1)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x - tickWidth / 2, y: barY - tickOverhang,
                                                 width: tickWidth, height: barHeight + 2 * tickOverhang),
                             xRadius: tickWidth / 2, yRadius: tickWidth / 2).fill()
            }

            // Label, vertically centred on cap height, left-aligned in the reserved area.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: base.withAlphaComponent(contentAlpha),
            ]
            let baseline = ((imageHeight - font.capHeight) / 2).rounded()
            let origin = NSPoint(x: barWidth + labelGap, y: baseline + font.descender)
            (label as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = !colored

        if stale { description += ", out of date" }
        image.accessibilityDescription = description
        return image
    }

    private static func fill(for level: UsageLevel) -> Fill {
        switch level {
        case .normal: .template
        case .warning: .orange
        case .critical: .red
        }
    }
}
