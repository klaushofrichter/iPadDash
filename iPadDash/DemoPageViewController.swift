import UIKit

/// Page 2: a placeholder dashboard with random sample values, in the same style.
final class DemoPageViewController: UIViewController, DashboardPage {
    private let tiles = [
        SampleTileView(title: "Temperature", detail: "Living room") { String(format: "%.1f°", Double.random(in: 18...24)) },
        SampleTileView(title: "Humidity", detail: "Living room") { "\(Int.random(in: 35...60))%" },
        SampleTileView(title: "Power", detail: "Whole house") { "\(Int.random(in: 200...900)) W" },
        SampleTileView(title: "Network", detail: "Downlink") { "\(Int.random(in: 50...300)) Mbit/s" },
    ]
    private let instanceLabel = SpacedLabel(font: font(16))
    private var timer: Timer?

    override func loadView() {
        view = PaperView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = SpacedLabel(font: font(26, .bold), kern: 2)
        title.set("SAMPLE")
        let subtitle = SpacedLabel(font: font(16), alpha: 0.6)
        subtitle.set("Placeholder page with random values")

        let rows = [UIStackView(arrangedSubviews: [tiles[0], tiles[1]]),
                    UIStackView(arrangedSubviews: [tiles[2], tiles[3]])]
        for row in rows {
            row.distribution = .fillEqually
            row.spacing = 16
        }
        let grid = UIStackView(arrangedSubviews: rows)
        grid.axis = .vertical
        grid.distribution = .fillEqually
        grid.spacing = 16

        let rule = InkView()
        let titleBarName = SpacedLabel(font: font(16, .bold))
        titleBarName.textAlignment = .left
        titleBarName.set("Sample")
        instanceLabel.textAlignment = .right
        let titleBar = UIStackView(arrangedSubviews: [titleBarName, instanceLabel])

        for v in [title, subtitle, grid, rule, titleBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 32),
            grid.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            grid.heightAnchor.constraint(equalToConstant: 2 * 200 + 16),
            rule.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24),
            rule.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            rule.heightAnchor.constraint(equalToConstant: 2),
            titleBar.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            titleBar.leadingAnchor.constraint(equalTo: rule.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: rule.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
        reloadNow()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
    }

    func reloadNow() {
        tiles.forEach { $0.refresh() }
        instanceLabel.set("updated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))")
        if view.window != nil { startTimer() }
    }

    @objc private func settingsChanged() {
        if view.window != nil { startTimer() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.reloadNow()
        }
    }
}

/// Bordered tile: title, big value, detail line.
final class SampleTileView: UIView {
    private let titleLabel = SpacedLabel(font: font(18, .bold), kern: 1, uppercase: true)
    private let valueLabel = SpacedLabel(font: font(56, .heavy))
    private let detailLabel = SpacedLabel(font: font(16), alpha: 0.6)
    private let makeValue: () -> String

    init(title: String, detail: String, value: @escaping () -> String) {
        makeValue = value
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
        titleLabel.set(title)
        detailLabel.set(detail)
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        valueLabel.set(makeValue())
    }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 12)
        path.lineWidth = 2
        ink.setStroke()
        path.stroke()
    }
}
