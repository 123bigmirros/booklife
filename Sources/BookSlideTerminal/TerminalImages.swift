import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Decodes bounded EPUB bitmap resources without executing SVG/HTML content.
public final class TerminalImage {
    public let id = UUID()
    private let bitmap: CGImage
    public var aspectRatio: Double { Double(bitmap.width) / Double(bitmap.height) }
    public init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Double(width) * Double(height) <= 80_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:1600
              ] as CFDictionary) else { return nil }
        bitmap = image
    }
    /// Crop the part visible in the viewport, including an image entered halfway
    /// through by scrolling. A single placement keeps adjacent strips seamless.
    public func png(firstRow: Int, rowCount: Int, totalRows: Int) -> Data? {
        guard totalRows > 0, firstRow >= 0, firstRow < totalRows, rowCount > 0 else { return nil }
        let top = bitmap.height * firstRow / totalRows
        let bottom = max(top+1,bitmap.height * min(totalRows,firstRow+rowCount) / totalRows)
        guard bottom > top, let crop = bitmap.cropping(to:CGRect(x:0,y:top,width:bitmap.width,height:bottom-top)) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,crop,nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

public enum TerminalImageProtocol: String {
    case none, kitty, iterm2
    public static func detect(environment: [String:String] = ProcessInfo.processInfo.environment) -> Self {
        if let override = environment["BOOKSLIDE_IMAGES"], let value = Self(rawValue:override) { return value }
        let program = environment["TERM_PROGRAM"]?.lowercased() ?? ""
        let term = environment["TERM"]?.lowercased() ?? ""
        if program.contains("ghostty") || program.contains("kitty") || term.contains("kitty") || term.contains("ghostty") || environment["KITTY_WINDOW_ID"] != nil { return .kitty }
        if program == "iterm.app" || program == "wezterm" { return .iterm2 }
        return .none
    }
    public func delete(id: Int) -> String {
        self == .kitty ? "\u{1B}_Ga=d,d=I,i=\(id),q=2;\u{1B}\\" : ""
    }
    public func display(_ png: Data, id: Int, columns: Int, rows: Int) -> String {
        let encoded = png.base64EncodedString()
        switch self {
        case .none: return ""
        case .iterm2:
            return "\u{1B}]1337;File=inline=1;size=\(png.count);width=\(columns);height=\(rows);preserveAspectRatio=0:" + encoded + "\u{07}"
        case .kitty:
            let bytes = Array(encoded.utf8)
            var result = ""
            for start in stride(from:0,to:bytes.count,by:4096) {
                let end = min(bytes.count,start+4096), more = end < bytes.count ? 1 : 0
                let command = start == 0 ? "a=T,f=100,t=d,i=\(id),c=\(columns),r=\(rows),C=1,q=2," : "q=2,"
                result += "\u{1B}_G" + command + "m=\(more);" + String(decoding:bytes[start..<end],as:UTF8.self) + "\u{1B}\\"
            }
            return result
        }
    }
}

public struct TextImageRow {
    public let image: TerminalImage
    public let row: Int
    public let totalRows: Int
    public let columns: Int
}
