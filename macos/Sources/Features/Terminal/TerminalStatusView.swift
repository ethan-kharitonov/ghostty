import AppKit

final class TerminalStatusView: NSTextField {
    var status: TerminalStatus? {
        didSet {
            Ghostty.logger.info("status view priority=\(self.status?.priority ?? 0)")
            isHidden = status == nil || (status?.label.isEmpty == true && status?.indicator == 0)
            let text = NSMutableAttributedString()
            if let indicator = color(status?.indicator ?? 0) {
                text.append(NSAttributedString(string: "● ", attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: indicator
                ]))
            }
            text.append(NSAttributedString(string: status?.label ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color(status?.textColor ?? 0) ?? NSColor.secondaryLabelColor
            ]))
            attributedStringValue = text
            toolTip = [status?.label, status?.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            setAccessibilityLabel(status?.label ?? "")
            setAccessibilityHelp(status?.detail)
        }
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
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
