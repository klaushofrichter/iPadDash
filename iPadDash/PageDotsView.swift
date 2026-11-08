import UIKit

/// Page indicator with per-page alert colors (UIPageControl on iOS 12 can't
/// color single dots). Current page: ink, or bright red if it shows red markup.
/// Other pages: faint ink, or a muted darker red if they have red markup.
final class PageDotsView: UIView {
    var numberOfPages = 0 { didSet { invalidateIntrinsicContentSize(); setNeedsDisplay() } }
    var currentPage = 0 { didSet { if currentPage != oldValue { setNeedsDisplay() } } }
    var alerts: [Bool] = [] { didSet { if alerts != oldValue { setNeedsDisplay() } } }

    private let diameter: CGFloat = 11
    private let spacing: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(max(numberOfPages, 1))
        return CGSize(width: count * diameter + (count - 1) * spacing, height: diameter + 4)
    }

    override func draw(_ rect: CGRect) {
        let width = intrinsicContentSize.width
        var x = (bounds.width - width) / 2
        let y = (bounds.height - diameter) / 2
        for page in 0..<numberOfPages {
            let current = page == currentPage
            let alert = page < alerts.count && alerts[page]
            let color: UIColor
            switch (current, alert) {
            case (true, true): color = alertInk
            case (false, true): color = mutedAlertInk
            case (true, false): color = ink
            case (false, false): color = ink.withAlphaComponent(0.25)
            }
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: x, y: y, width: diameter, height: diameter)).fill()
            x += diameter + spacing
        }
    }
}

/// A darker, quieter red for alerts on pages that aren't showing.
var mutedAlertInk: UIColor {
    return Theme.isDark ? UIColor(red: 0.55, green: 0.12, blue: 0.11, alpha: 1)
                        : UIColor(red: 0.95, green: 0.6, blue: 0.6, alpha: 1)
}
