import GhosttyKit

struct TerminalStatus: Equatable {
    let label: String
    let detail: String
    let indicator: UInt32
    let textColor: UInt32
    let priority: UInt8

    init(_ status: ghostty_action_session_status_s) {
        label = Self.displayText(status.label)
        detail = Self.displayText(status.detail)
        indicator = status.indicator
        textColor = status.text_color
        priority = status.priority
    }

    private static func displayText(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        let text = String(cString: pointer)
        let scalars = text.unicodeScalars.filter {
            switch $0.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

