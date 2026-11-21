import Foundation
#if canImport(BookSlideCore)
import BookSlideCore
#endif

extension TextBook {
    public func anchor(chapter: Int, offset: Int) -> ContentAnchor {
        let item = chapters[chapter]
        let chars = Array(ContentAnchor.canonical(item.text).unicodeScalars)
        let index = ContentAnchor.canonical(String(item.text.prefix(offset))).unicodeScalars.count
        return ContentAnchor(href:item.href,quote:String(String.UnicodeScalarView(chars.dropFirst(index).prefix(96))),fraction:Double(index)/Double(max(1,chars.count)))
    }
    public func location(for anchor: ContentAnchor) -> (chapter: Int, offset: Int)? {
        guard let chapter = chapters.firstIndex(where:{($0.href.removingPercentEncoding ?? $0.href) == (anchor.href.removingPercentEncoding ?? anchor.href)}) else { return nil }
        var chars: [Unicode.Scalar] = [], offsets: [Int] = []
        for (index,char) in chapters[chapter].text.enumerated() {
            for scalar in ContentAnchor.canonical(String(char)).unicodeScalars { chars.append(scalar); offsets.append(index) }
        }
        guard !chars.isEmpty else { return (chapter,0) }
        let expected = min(chars.count-1,max(0,Int(Double(chars.count)*anchor.fraction)))
        let quote = Array(ContentAnchor.canonical(anchor.quote).unicodeScalars)
        var best: Int?
        if !quote.isEmpty, quote.count <= chars.count {
            for i in 0...(chars.count-quote.count) where chars[i] == quote[0] {
                if chars[i..<i+quote.count].elementsEqual(quote), best == nil || abs(i-expected) < abs(best!-expected) { best = i }
            }
        }
        return (chapter,offsets[best ?? expected])
    }
}

/// Built once per visited chapter; moving the viewport never rescans chapter text.
public struct TextAnchorIndex {
    private let scalars: [Unicode.Scalar]
    private let starts: [Int]
    public init(_ text: String) {
        var scalars: [Unicode.Scalar] = [], starts: [Int] = []
        let whitespace = CharacterSet.whitespacesAndNewlines, controls = CharacterSet.controlCharacters
        for char in text {
            starts.append(scalars.count)
            for scalar in char.unicodeScalars where !whitespace.contains(scalar) && !controls.contains(scalar) {
                let value = scalar.value
                if !(0x202A...0x202E).contains(value) && !(0x2066...0x2069).contains(value) { scalars.append(scalar) }
            }
        }
        starts.append(scalars.count)
        self.scalars = scalars; self.starts = starts
    }
    public func anchor(href: String, offset: Int) -> ContentAnchor {
        let index = starts[min(max(0,offset),starts.count-1)]
        return ContentAnchor(href:href,quote:String(String.UnicodeScalarView(scalars.dropFirst(index).prefix(96))),fraction:Double(index)/Double(max(1,scalars.count)))
    }
}
