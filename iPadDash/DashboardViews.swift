import UIKit

// Views reproducing the TRMNL "Steps & Claude" layout from
// klaushofrichter/trmnl-for-steps (black on white, e-ink style), plus a dark
// variant. Sizes are the TRMNL CSS pixel values times `scale` (800x480 -> 1024x768).

let scale: CGFloat = 1.28

/// App-level light/dark theme; iOS 12 has no system dark mode.
enum Theme {
    private static let key = "darkMode"

    static var isDark: Bool {
        get { return UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// Light-gray ink rather than white keeps the dark theme easy on the eyes at night.
var ink: UIColor { return Theme.isDark ? UIColor(white: 0.82, alpha: 1) : .black }
var paper: UIColor { return Theme.isDark ? .black : .white }

/// Re-applies the current theme to a view tree: label colors, drawn views, ink fills.
func applyTheme(to view: UIView) {
    if let label = view as? SpacedLabel { label.refresh() }
    if view is InkView { view.backgroundColor = ink }
    view.setNeedsDisplay()
    view.subviews.forEach(applyTheme)
}

/// A solid line or divider in the ink color.
final class InkView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ink
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
    return UIFont.systemFont(ofSize: size * scale, weight: weight)
}

/// A label with letter spacing and optional uppercasing (CSS letter-spacing / text-transform).
final class SpacedLabel: UILabel {
    var kern: CGFloat = 0
    var uppercase = false
    var alphaOfInk: CGFloat = 1

    convenience init(font: UIFont, kern: CGFloat = 0, uppercase: Bool = false, alpha: CGFloat = 1) {
        self.init(frame: .zero)
        self.font = font
        self.kern = kern * scale
        self.uppercase = uppercase
        self.alphaOfInk = alpha
        textAlignment = .center
        adjustsFontSizeToFitWidth = true
        minimumScaleFactor = 0.5
    }

    private var rawText = ""

    func refresh() { set(rawText) }

    func set(_ text: String) {
        rawText = text
        let shown = uppercase ? text.uppercased() : text
        attributedText = NSAttributedString(string: shown, attributes: [
            .kern: kern,
            .foregroundColor: ink.withAlphaComponent(alphaOfInk),
            .font: font as Any,
        ])
    }
}

/// Two concentric rings: thin outer = pace, thick inner = actual (SVG viewBox 0 0 100 100).
final class RingGaugeView: UIView {
    var pacePct: Int = 0 { didSet { setNeedsDisplay() } }
    var actualPct: Int = 0 { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let unit = min(bounds.width, bounds.height) / 100
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        func ring(radius: CGFloat, width: CGFloat, fraction: CGFloat, minLength: CGFloat) {
            let r = radius * unit
            ctx.setLineWidth(width * unit)
            ctx.setLineCap(.butt)
            ctx.setStrokeColor(ink.withAlphaComponent(0.15).cgColor)
            ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()

            guard fraction > 0 else { return }
            // The Liquid markup enforces a minimum visible dash on the pace ring.
            let circumference = 2 * .pi * radius
            let length = max(circumference * fraction, minLength)
            let start = -CGFloat.pi / 2
            ctx.setStrokeColor(ink.cgColor)
            ctx.addArc(center: center, radius: r, startAngle: start,
                       endAngle: start + 2 * .pi * min(length / circumference, 1), clockwise: false)
            ctx.strokePath()
        }

        ring(radius: 46.5, width: 5, fraction: CGFloat(pacePct) / 100, minLength: 4)
        ring(radius: 38, width: 7.5, fraction: CGFloat(min(actualPct, 100)) / 100, minLength: 0)
    }
}

/// Bordered bar with a diagonal-hatch fill (CSS repeating-linear-gradient 135deg).
final class HatchedBarView: UIView {
    var percent: Double = 0 { didSet { setNeedsDisplay() } }
    private let lineWidth: CGFloat
    private let gap: CGFloat
    private let fillAlpha: CGFloat

    init(lineWidth: CGFloat, gap: CGFloat, alpha: CGFloat) {
        self.lineWidth = lineWidth
        self.gap = gap
        self.fillAlpha = alpha
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let border = 2 * scale
        let outline = UIBezierPath(roundedRect: bounds.insetBy(dx: border / 2, dy: border / 2),
                                   cornerRadius: 4 * scale)

        ctx.saveGState()
        outline.addClip()
        let fillWidth = bounds.width * CGFloat(min(max(percent, 0), 100)) / 100
        ctx.clip(to: CGRect(x: 0, y: 0, width: fillWidth, height: bounds.height))
        ctx.setStrokeColor(ink.withAlphaComponent(fillAlpha).cgColor)
        // Stripes running bottom-left to top-right; period measured perpendicular to them.
        let period = (lineWidth + gap) * scale * sqrt(2)
        ctx.setLineWidth(lineWidth * scale)
        var x = -bounds.height
        while x < fillWidth + bounds.height {
            ctx.move(to: CGPoint(x: x, y: bounds.height))
            ctx.addLine(to: CGPoint(x: x + bounds.height, y: 0))
            x += period
        }
        ctx.strokePath()
        ctx.restoreGState()

        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(border)
        ctx.addPath(outline.cgPath)
        ctx.strokePath()
    }
}

/// One "Weekly" / "Session" block: name + status, pace bar, actual bar, caption.
final class UsageMetricView: UIView {
    private let nameLabel = SpacedLabel(font: font(16))
    private let statusLabel = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true)
    private let paceBar = HatchedBarView(lineWidth: 2, gap: 5, alpha: 0.55)
    private let actualBar = HatchedBarView(lineWidth: 3, gap: 3, alpha: 1)
    private let captionLabel = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true, alpha: 0.85)

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.textAlignment = .left
        statusLabel.textAlignment = .right
        captionLabel.textAlignment = .left
        let head = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        head.distribution = .fill
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [head, paceBar, actualBar, captionLabel])
        stack.axis = .vertical
        stack.spacing = 6 * scale
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            paceBar.heightAnchor.constraint(equalToConstant: 20 * scale),
            actualBar.heightAnchor.constraint(equalToConstant: 20 * scale),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with window: UsageWindow) {
        nameLabel.set(window.name)
        statusLabel.set(window.status)
        paceBar.percent = window.expired ? 0 : Double(window.pace)
        actualBar.percent = window.actual ?? 0
        captionLabel.set(window.caption)
    }
}

/// A column: content stacked at the top, freshness line pinned to the bottom.
class PanelView: UIView {
    let body = UIStackView()
    let titleLabel = SpacedLabel(font: font(26, .bold), kern: 2)
    let heroLabel = SpacedLabel(font: font(36, .heavy))
    let freshnessLabel = SpacedLabel(font: font(24), kern: 1)

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.set(title)
        body.axis = .vertical
        body.alignment = .center
        body.addArrangedSubview(titleLabel)
        body.addArrangedSubview(heroLabel)
        body.setCustomSpacing(23 * scale, after: titleLabel)
        body.setCustomSpacing(16 * scale, after: heroLabel)

        body.translatesAutoresizingMaskIntoConstraints = false
        freshnessLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        addSubview(freshnessLabel)
        let pad = 16 * scale
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 10 * scale),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            freshnessLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            freshnessLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            freshnessLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            freshnessLabel.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 8 * scale),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showError(_ message: String) {
        heroLabel.set("—")
        freshnessLabel.set(message)
    }
}

final class StepsPanelView: PanelView {
    private let gauge = RingGaugeView()
    private let stepsLabel = SpacedLabel(font: font(28, .bold))
    private let goalLabel = SpacedLabel(font: font(11))
    private let captionLabel = SpacedLabel(font: font(9), kern: 0.5, uppercase: true, alpha: 0.6)
    private let statusLabel = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true)

    init() {
        super.init(title: "STEPS")
        let size = 180 * scale * 1.3   // the iPad has spare height; give the gauge more of it
        gauge.translatesAutoresizingMaskIntoConstraints = false
        let center = UIStackView(arrangedSubviews: [stepsLabel, goalLabel])
        center.axis = .vertical
        center.alignment = .center
        center.translatesAutoresizingMaskIntoConstraints = false
        gauge.addSubview(center)
        stepsLabel.font = font(28 * 1.3, .bold)
        goalLabel.font = font(11 * 1.3)
        NSLayoutConstraint.activate([
            gauge.widthAnchor.constraint(equalToConstant: size),
            gauge.heightAnchor.constraint(equalToConstant: size),
            center.centerXAnchor.constraint(equalTo: gauge.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: gauge.centerYAnchor),
            center.widthAnchor.constraint(equalToConstant: size * 0.55),
        ])
        body.addArrangedSubview(gauge)
        body.addArrangedSubview(captionLabel)
        body.addArrangedSubview(statusLabel)
        body.setCustomSpacing(6 * scale, after: gauge)
        body.setCustomSpacing(4 * scale, after: captionLabel)
        captionLabel.set("outer = pace, inner = actual")
        goalLabel.set("of \(stepsGoal)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with summary: StepsSummary) {
        heroLabel.set(summary.hero)
        stepsLabel.set("\(summary.steps)")
        gauge.pacePct = summary.pacePct
        gauge.actualPct = summary.actualPct
        statusLabel.set(summary.status)
        freshnessLabel.set(summary.freshness)
    }
}

final class ClaudePanelView: PanelView {
    private let weeklyView = UsageMetricView()
    private let sessionView = UsageMetricView()

    init() {
        super.init(title: "CLAUDE")
        for view in [weeklyView, sessionView] {
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        body.setCustomSpacing(22 * scale * 1.5, after: weeklyView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with summary: ClaudeSummary) {
        heroLabel.set(summary.hero)
        weeklyView.configure(with: summary.weekly)
        sessionView.configure(with: summary.session)
        freshnessLabel.set(summary.freshness)
    }
}
