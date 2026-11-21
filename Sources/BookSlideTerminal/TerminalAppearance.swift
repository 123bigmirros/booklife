import Foundation

public enum TerminalWidth: String, CaseIterable {
    case standard, wide, compact
    public var title: String {
        switch self { case .standard: return "适中"; case .wide: return "宽"; case .compact: return "窄" }
    }
    public var next: TerminalWidth {
        switch self { case .standard: return .wide; case .wide: return .compact; case .compact: return .standard }
    }
    public func columns(in terminal: Int) -> Int {
        let available = max(4, terminal - (terminal < 40 ? 2 : 4))
        switch self {
        case .standard: return min(100, available)
        case .wide: return available
        case .compact: return min(64, available)
        }
    }
}

public enum TerminalTypography {
    /// Unlike EPUB whitespace normalization, drawing must retain alignment spaces.
    public static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of:"\n",with:" ").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0) &&
            ![0x202A,0x202B,0x202C,0x202D,0x202E,0x2066,0x2067,0x2068,0x2069].contains($0.value)
        }.map(String.init).joined()
    }
    /// Metadata truncates at a whole grapheme; prose continues on its next line.
    public static func abbreviated(_ text: String, columns: Int) -> String {
        guard columns > 0 else { return "" }
        let text = singleLine(text)
        guard TextLayout.width(text) > columns else { return text }
        return TextLayout.clipped(text, columns: max(0, columns - TextLayout.width("…"))) + "…"
    }
    /// Reserve the right side so long book/chapter names cannot hide progress.
    public static func joined(_ left: String, right: String, columns: Int) -> String {
        let right = abbreviated(right, columns: columns)
        let room = columns - TextLayout.width(right)
        guard room > 2 else { return right }
        let left = abbreviated(left, columns: room - 2)
        return left + String(repeating: " ", count: max(0, room - TextLayout.width(left))) + right
    }
    public static func windowStart(selection: Int, count: Int, capacity: Int) -> Int {
        max(0, min(selection - capacity / 2, count - capacity))
    }
}
