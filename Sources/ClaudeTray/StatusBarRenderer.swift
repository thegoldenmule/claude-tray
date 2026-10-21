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

enum StatusBarRenderer {
    private static let barWidth: CGFloat = 36
    private static let barHeight: CGFloat = 8
    private static let imageHeight: CGFloat = 18
    private static let labelGap: CGFloat = 4
    private static let staleAlpha: CGFloat = 0.4

    /// percent: 0...100 or nil if unknown. stale: draw dimmed.
    @MainActor static func image(percent: Double?, stale: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let label = percent.map { "\(Int($0.rounded()))%" } ?? "–"

        // Reserve room for "100%" so the status item never changes width as the value moves.
        let measureAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let reservedWidth = ceil(("100%" as NSString).size(withAttributes: measureAttrs).width)
        let labelWidth = ceil((label as NSString).size(withAttributes: measureAttrs).width)
        let textAreaWidth = max(reservedWidth, labelWidth)
        let size = NSSize(width: barWidth + labelGap + textAreaWidth, height: imageHeight)

        let level = percent.map(UsageLevel.init(percent:)) ?? .normal
        // Colored rendering only for fresh, known, elevated values; everything else is a template.
        let colored = !stale && percent != nil && level != .normal
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
                switch (colored, level) {
                case (true, .critical): fillColor = .systemRed
                case (true, _):         fillColor = .systemOrange
                default:                fillColor = NSColor.black.withAlphaComponent(contentAlpha)
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).addClip()
                fillColor.setFill()
                // Never thinner than the pill's height so tiny values still read as a dot.
                NSRect(x: 0, y: barY, width: max(barHeight, barWidth * fraction), height: barHeight).fill()
                NSGraphicsContext.restoreGraphicsState()
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

        var description = percent.map { "Claude session usage \(Int($0.rounded())) percent" }
            ?? "Claude session usage unavailable"
        if stale { description += ", out of date" }
        image.accessibilityDescription = description
        return image
    }
}
