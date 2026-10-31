import AppKit

final class TerminalStatusView: NSStackView {
    private let dot = NSTextField(labelWithString: "●")
    private let label = NSTextField(labelWithString: "")

    var status: TerminalStatus? {
        didSet {
            Ghostty.logger.info("status view priority=\(self.status?.priority ?? 0)")
            isHidden = status == nil || (status?.label.isEmpty == true && status?.indicator == 0)
            label.stringValue = status?.label ?? ""
            label.textColor = color(status?.textColor ?? 0) ?? .secondaryLabelColor
            dot.textColor = color(status?.indicator ?? 0)
            dot.isHidden = status?.indicator == 0
            toolTip = [status?.label, status?.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            setAccessibilityLabel(toolTip)
        }
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        alignment = .centerY
        dot.font = .systemFont(ofSize: 9)
        label.font = .systemFont(ofSize: 10)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(dot)
        addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func color(_ rgba: UInt32) -> NSColor? {
        guard rgba != 0 else { return nil }
        return NSColor(
            calibratedRed: CGFloat((rgba >> 24) & 255) / 255,
            green: CGFloat((rgba >> 16) & 255) / 255,
            blue: CGFloat((rgba >> 8) & 255) / 255,
            alpha: CGFloat(rgba & 255) / 255
        )
    }
}
