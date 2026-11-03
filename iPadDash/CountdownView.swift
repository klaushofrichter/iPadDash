import UIKit

/// Small pie showing time until the next auto-move. Cycles alternate: the pie
/// shrinks from full to empty, then grows from empty back to full, and so on.
/// A reset always starts full. Animated by Core Animation, so it is smooth and cheap.
/// While the page is frozen it is red and shrinks once over the freeze time.
/// During the doubled wait after a swipe, a thin ring surrounds it.
final class CountdownView: UIView {
    private let track = CAShapeLayer()
    private let pie = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var shrinking = true
    /// Page frozen (tap): drawn in red.
    var frozen = false { didSet { if frozen != oldValue { applyColors() } } }
    /// This countdown is twice the setting (the page was swiped to): shows the ring.
    var doubled = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.isHidden = !doubled
            CATransaction.commit()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true
        ring.isHidden = true
        for shape in [track, pie, ring] {
            shape.fillColor = UIColor.clear.cgColor
            layer.addSublayer(shape)
        }
        track.lineWidth = 1
        ring.lineWidth = 1
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { return CGSize(width: 16, height: 16) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2 - 1
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        track.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0,
                                  endAngle: 2 * .pi, clockwise: true).cgPath
        ring.path = UIBezierPath(arcCenter: center, radius: radius + 2.5, startAngle: 0,
                                 endAngle: 2 * .pi, clockwise: true).cgPath
        // A stroke as wide as the radius, centered at half the radius, fills a pie;
        // strokeEnd then sets the size of the slice, clockwise from 12 o'clock.
        pie.path = UIBezierPath(arcCenter: center, radius: radius / 2, startAngle: -.pi / 2,
                                endAngle: 1.5 * .pi, clockwise: true).cgPath
        pie.lineWidth = radius
    }

    func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = frozen ? alertInk : ink
        track.strokeColor = color.withAlphaComponent(0.35).cgColor
        pie.strokeColor = color.cgColor
        // White on the dark theme; white wouldn't show on the light theme's paper.
        ring.strokeColor = (Theme.isDark ? UIColor.white : UIColor.black).cgColor
        CATransaction.commit()
    }

    /// Start over from a full pie (timer reset), or partway in when `elapsed` > 0.
    func restart(interval: TimeInterval, elapsed: TimeInterval = 0) {
        shrinking = true
        run(interval, elapsed: elapsed)
    }

    /// Continue with the next cycle (the page just advanced).
    func nextCycle(interval: TimeInterval) {
        doubled = false
        shrinking.toggle()
        run(interval)
    }

    func stop() {
        doubled = false
        pie.removeAllAnimations()
        isHidden = true
    }

    /// The moving edge always sweeps clockwise: shrinking advances the slice's
    /// start (eating it from 12 o'clock on), growing advances its end.
    private func run(_ interval: TimeInterval, elapsed: TimeInterval = 0) {
        let done = min(max(elapsed / interval, 0), 1)
        isHidden = false
        let keyPath = shrinking ? "strokeStart" : "strokeEnd"
        pie.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pie.strokeStart = shrinking ? 1 : 0
        pie.strokeEnd = 1
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = done
        animation.toValue = 1
        animation.duration = interval * (1 - done)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        pie.add(animation, forKey: "countdown")
    }
}
