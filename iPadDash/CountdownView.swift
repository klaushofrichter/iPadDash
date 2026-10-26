import UIKit

/// Small pie showing time until the next auto-move. Cycles alternate: the pie
/// shrinks from full to empty, then grows from empty back to full, and so on.
/// A reset always starts full. Animated by Core Animation, so it is smooth and cheap.
final class CountdownView: UIView {
    private let track = CAShapeLayer()
    private let pie = CAShapeLayer()
    private var shrinking = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true
        for shape in [track, pie] {
            shape.fillColor = UIColor.clear.cgColor
            layer.addSublayer(shape)
        }
        track.lineWidth = 1
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
        // A stroke as wide as the radius, centered at half the radius, fills a pie;
        // strokeEnd then sets the size of the slice, clockwise from 12 o'clock.
        pie.path = UIBezierPath(arcCenter: center, radius: radius / 2, startAngle: -.pi / 2,
                                endAngle: 1.5 * .pi, clockwise: true).cgPath
        pie.lineWidth = radius
    }

    func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = ink.withAlphaComponent(0.35).cgColor
        pie.strokeColor = ink.cgColor
        CATransaction.commit()
    }

    /// Start over from a full pie (timer reset).
    func restart(interval: TimeInterval) {
        shrinking = true
        run(interval)
    }

    /// Continue with the next cycle (the page just advanced).
    func nextCycle(interval: TimeInterval) {
        shrinking.toggle()
        run(interval)
    }

    func stop() {
        pie.removeAllAnimations()
        isHidden = true
    }

    /// The moving edge always sweeps clockwise: shrinking advances the slice's
    /// start (eating it from 12 o'clock on), growing advances its end.
    private func run(_ interval: TimeInterval) {
        isHidden = false
        let keyPath = shrinking ? "strokeStart" : "strokeEnd"
        pie.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pie.strokeStart = shrinking ? 1 : 0
        pie.strokeEnd = 1
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = interval
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        pie.add(animation, forKey: "countdown")
    }
}
