import UIKit

/// "CPU ........ 26%" over a single hatched bar; red above the usage limit.
final class UsageBarView: UIView {
    private let nameLabel = SpacedLabel(font: font(16))
    private let valueLabel = SpacedLabel(font: font(16, .bold), kern: 1)
    private let bar = HatchedBarView(lineWidth: 3, gap: 3, alpha: 1)

    init(name: String) {
        super.init(frame: .zero)
        nameLabel.textAlignment = .left
        valueLabel.textAlignment = .right
        nameLabel.set(name)
        let head = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [head, bar])
        stack.axis = .vertical
        stack.spacing = 6 * scale
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 20 * scale),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(percent: Double?) {
        let high = (percent ?? 0) > ClusterLimits.usagePct
        valueLabel.set(percent.map { "\(Int($0.rounded()))%" } ?? "n/a")
        valueLabel.alert = high
        nameLabel.alert = high
        bar.alert = high
        bar.percent = percent ?? 0
    }
}

/// "name ............ value" in one line; red when flagged.
final class KeyValueRow: UIView {
    let keyLabel: SpacedLabel
    let valueLabel: SpacedLabel

    init(size: CGFloat = 16) {
        keyLabel = SpacedLabel(font: font(size))
        valueLabel = SpacedLabel(font: font(size, .bold), kern: 1, uppercase: true)
        super.init(frame: .zero)
        keyLabel.textAlignment = .left
        valueLabel.textAlignment = .right
        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // A long value ("The Internet connection appears to be offline.") is cut short;
        // the name stays.
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.lineBreakMode = .byTruncatingTail
        let row = UIStackView(arrangedSubviews: [keyLabel, valueLabel])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ key: String, _ value: String, alert: Bool = false) {
        keyLabel.set(key)
        valueLabel.set(value)
        keyLabel.alert = alert
        valueLabel.alert = alert
    }
}

/// Left panel: CPU, memory and disk bars plus load averages.
final class LoadPanelView: PanelView {
    private let cpu = UsageBarView(name: "CPU")
    private let memory = UsageBarView(name: "Memory")
    private let disk = UsageBarView(name: "Disk")
    private let loadLabel = SpacedLabel(font: font(14, .bold), kern: 1, uppercase: true, alpha: 0.85)

    init() {
        super.init(title: "LOAD")
        for view in [cpu, memory, disk] {
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            body.setCustomSpacing(16 * scale, after: view)
        }
        body.addArrangedSubview(loadLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with snapshot: ClusterSnapshot, now: Date) {
        alerting = snapshot.stale
        let peak = [snapshot.cpuPct, snapshot.memPct, snapshot.diskPct].compactMap { $0 }.max()
        heroLabel.set(peak.map { $0 > ClusterLimits.usagePct ? "High load" : "Normal" } ?? "n/a")
        heroLabel.alert = (peak ?? 0) > ClusterLimits.usagePct
        cpu.configure(percent: snapshot.cpuPct)
        memory.configure(percent: snapshot.memPct)
        disk.configure(percent: snapshot.diskPct)
        let load = snapshot.load.map { String(format: "%.2f", $0) }.joined(separator: " · ")
        loadLabel.set(load.isEmpty ? "load n/a" : "load \(load)")
        freshnessLabel.set(snapshot.sampleAge.map { freshnessText(since: now.addingTimeInterval(-$0), now: now) } ?? "no data")
    }
}

/// Right panel: HTTPS probe result per public service.
final class ServicesPanelView: PanelView {
    private let list = UIStackView()

    init() {
        super.init(title: "SERVICES")
        list.axis = .vertical
        list.spacing = 6 * scale
        body.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with snapshot: ClusterSnapshot) {
        alerting = snapshot.stale
        let down = snapshot.servicesDown.count
        let total = snapshot.services.count
        heroLabel.set(total == 0 ? "n/a" : "\(total - down) / \(total) up")
        heroLabel.alert = down > 0

        while list.arrangedSubviews.count < total { list.addArrangedSubview(KeyValueRow(size: 15)) }
        for (index, view) in list.arrangedSubviews.enumerated() {
            guard let row = view as? KeyValueRow else { continue }
            row.isHidden = index >= total
            if index < total {
                let probe = snapshot.services[index]
                row.set(probe.name, probe.up ? "up" : "down", alert: !probe.up)
            }
        }
        freshnessLabel.set(down == 0 ? "all reachable" : "\(down) not reachable")
        freshnessLabel.alert = down > 0
    }
}

/// 24-hour line graph, 0–100 %, with a hatched area, grid and a dashed limit line.
final class LineGraphView: UIView {
    var points: [(Date, Double)] = [] { didSet { setNeedsDisplay() } }
    var alert = false { didSet { setNeedsDisplay() } }
    /// The dashed red line, in percent.
    var limit = ClusterLimits.usagePct { didSet { setNeedsDisplay() } }
    /// Labels the 0, 50 and 100 % lines and the limit, and draws the limit line solid red.
    var showsScale = false { didSet { setNeedsDisplay() } }
    /// Hatches the area red where the line is under the limit (battery).
    var redBelowLimit = false { didSet { setNeedsDisplay() } }
    let span: TimeInterval = 24 * 3600

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let lineInk = alert ? alertInk : ink
        let plot = bounds.insetBy(dx: 1, dy: 2)
        let end = Date()
        let start = end.addingTimeInterval(-span)
        func point(_ date: Date, _ value: Double) -> CGPoint {
            let x = plot.minX + plot.width * CGFloat(date.timeIntervalSince(start) / span)
            let y = plot.maxY - plot.height * CGFloat(min(max(value, 0), 100) / 100)
            return CGPoint(x: x, y: y)
        }

        // Grid: 0, 50, 100 % and a vertical line every 6 hours.
        ctx.setStrokeColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(1)
        for pct in [0.0, 50, 100] {
            let y = point(end, pct).y
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        for hours in stride(from: 6.0, to: 24, by: 6) {
            let x = point(end.addingTimeInterval(-hours * 3600), 0).x
            ctx.move(to: CGPoint(x: x, y: plot.minY))
            ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        ctx.strokePath()

        // Limit line.
        let limitY = point(end, limit).y
        ctx.saveGState()
        ctx.setStrokeColor(alertInk.withAlphaComponent(showsScale ? 0.9 : 0.5).cgColor)
        if showsScale { ctx.setLineWidth(2) }
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: CGPoint(x: plot.minX, y: limitY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: limitY))
        ctx.strokePath()
        ctx.restoreGState()

        // Scale labels on top of everything: 0, 50, 100 % at the left, the limit at the right.
        defer {
            if showsScale {
                func label(_ text: String, at value: Double, color: UIColor, right: Bool = false) {
                    let attributes: [NSAttributedString.Key: Any] = [.font: font(13, .semibold), .foregroundColor: color]
                    let size = (text as NSString).size(withAttributes: attributes)
                    let y = min(max(point(end, value).y - size.height - 2, plot.minY), plot.maxY - size.height)
                    let x = right ? plot.maxX - size.width - 4 : plot.minX + 4
                    paper.withAlphaComponent(0.8).setFill()
                    UIBezierPath(roundedRect: CGRect(x: x - 3, y: y, width: size.width + 6, height: size.height),
                                 cornerRadius: 3).fill()
                    (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                }
                for pct in [100.0, 50, 0] { label("\(Int(pct))%", at: pct, color: ink.withAlphaComponent(0.6)) }
                label("\(Int(limit))%", at: limit, color: alertInk, right: true)
            }
        }

        let visible = points.filter { $0.0 >= start }
        guard visible.count > 1 else { return }
        let line = UIBezierPath()
        for (i, p) in visible.enumerated() {
            let pt = point(p.0, p.1)
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }

        // Hatched area under the line.
        let area = line.copy() as! UIBezierPath
        area.addLine(to: CGPoint(x: point(visible.last!.0, 0).x, y: plot.maxY))
        area.addLine(to: CGPoint(x: point(visible.first!.0, 0).x, y: plot.maxY))
        area.close()
        func hatch(_ color: UIColor, in columns: [ClosedRange<CGFloat>]?) {
            ctx.saveGState()
            area.addClip()
            if let columns = columns {
                guard !columns.isEmpty else { return ctx.restoreGState() }
                ctx.clip(to: columns.map { CGRect(x: $0.lowerBound, y: plot.minY,
                                                  width: $0.upperBound - $0.lowerBound, height: plot.height) })
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5)
            var x = plot.minX - plot.height
            while x < plot.maxX {
                ctx.move(to: CGPoint(x: x, y: plot.maxY))
                ctx.addLine(to: CGPoint(x: x + plot.height, y: plot.minY))
                x += 7
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        hatch(lineInk.withAlphaComponent(0.35), in: nil)
        if redBelowLimit {
            // Red over the stretches where the line is under the limit.
            var columns: [ClosedRange<CGFloat>] = []
            var from: CGFloat?
            for (a, b) in zip(visible, visible.dropFirst()) {
                let pa = point(a.0, a.1), pb = point(b.0, b.1)
                let crossX = a.1 == b.1 ? pa.x : pa.x + (pb.x - pa.x) * CGFloat((limit - a.1) / (b.1 - a.1))
                if a.1 < limit, from == nil { from = pa.x }
                if (a.1 < limit) != (b.1 < limit) {
                    if let f = from { columns.append(f...crossX); from = nil } else { from = crossX }
                }
            }
            if let f = from { columns.append(f...point(visible.last!.0, 0).x) }
            hatch(paper, in: columns)                       // clear the grey stripes there first
            hatch(alertInk.withAlphaComponent(0.8), in: columns)
        }

        lineInk.setStroke()
        line.lineWidth = 2.5
        line.lineJoinStyle = .round
        line.stroke()
    }
}

/// Graph with a "CPU — now 26% · peak 54%" caption above it.
final class GraphBlockView: UIView {
    private let caption = KeyValueRow(size: 15)
    private let graph = LineGraphView()
    private let name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [caption, graph])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(history: [(Date, Double)], current: Double?) {
        let peak = history.map { $0.1 }.max()
        let high = (current ?? 0) > ClusterLimits.usagePct
        let now = current.map { "now \(Int($0.rounded()))%" } ?? "now n/a"
        let peakText = peak.map { " · 24 h peak \(Int($0.rounded()))%" } ?? ""
        caption.set(name, now + peakText, alert: high)
        graph.points = history
        graph.alert = high
    }
}
