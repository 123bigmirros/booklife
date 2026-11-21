import Foundation
import Darwin

public struct TextPage {
    public let chapter: Int
    public let offset: Int
    public let end: Int
    public let lines: [String]
    public let headingLevels: [Int]
    public let imageRows: [TextImageRow?]
}
public enum TextLayout {
    public static func width(_ text: String) -> Int {
        text.reduce(0) { result, char in
            result + max(0,char.unicodeScalars.map { Int(wcwidth(Int32($0.value))) }.max() ?? 0)
        }
    }
    public static func clipped(_ text: String, columns: Int) -> String {
        var result = "", count = 0
        for char in text {
            let size = width(String(char)); if count + size > columns { break }
            result.append(char); count += size
        }
        return result
    }
    public static func pages(_ book: TextBook, columns: Int, rows: Int, images: Bool = false, imageMaxRows: Int = 12, cellAspect: Double = 0.5) -> [TextPage] {
        let columns = max(4,columns), rows = max(1,rows)
        let cellAspect = cellAspect.isFinite && cellAspect > 0 ? cellAspect : 0.5
        var pages: [TextPage] = []
        for (chapter,item) in book.chapters.enumerated() {
            var lines: [(Int,String)] = [], levels: [Int] = [], imageRows: [TextImageRow?] = [], start = 0
            let chars = Array(item.text)
            let closing = Set("，。！？；：、）》】」』”’…,.!?;:)]}")
            let opening = Set("（《【「『“‘([{")
            while start < chars.count {
                if images, let illustration = item.illustrations.first(where:{ $0.range.lowerBound == start }), let image = illustration.image {
                    let height = max(1,min(imageMaxRows,Int(ceil(Double(columns)*cellAspect/image.aspectRatio))))
                    let width = max(1,min(columns,Int((Double(height)*image.aspectRatio/cellAspect).rounded())))
                    for row in 0..<height {
                        lines.append((start,"")); levels.append(0)
                        imageRows.append(TextImageRow(image:image,row:row,totalRows:height,columns:width))
                    }
                    start = illustration.range.upperBound
                    if start < chars.count && chars[start] == "\n" { start += 1 }
                    continue
                }
                var end = start, count = 0
                while end < chars.count && chars[end] != "\n" {
                    let size = width(String(chars[end]))
                    if count + size > columns && end > start { break }
                    count += size; end += 1
                }
                if end < chars.count && chars[end] != "\n" {
                    // Keep closing punctuation with its preceding character.
                    if closing.contains(chars[end]) && end-start > 1 { end -= 1 }
                    if end-start > 1 && opening.contains(chars[end-1]) { end -= 1 }
                    // Prefer word boundaries for Latin prose; hard-wrap very long words.
                    if end < chars.count && chars[end].isASCII && chars[end].isLetter && chars[end-1].isASCII && chars[end-1].isLetter,
                       let space = (start..<end).last(where:{ chars[$0] == " " }), space > start + (end-start)/2 { end = space+1 }
                }
                lines.append((start,String(chars[start..<end])))
                levels.append(item.headings.first(where:{ $0.range.contains(start) })?.level ?? 0)
                imageRows.append(nil)
                start = end < chars.count && chars[end] == "\n" ? end+1 : end
            }
            if chapter < book.chapters.count-1, !lines.isEmpty {
                lines.append((chars.count,"")); levels.append(0); imageRows.append(nil)
            }
            var offset = 0
            while offset < lines.count {
                var end = min(offset + rows,lines.count)
                // Keep a heading with at least the first line of its paragraph.
                // Very long headings still wrap normally on small screens.
                if rows > 2, end < lines.count {
                    var last = end-1
                    while last > offset && lines[last].1.isEmpty && imageRows[last] == nil { last -= 1 }
                    if levels[last] > 0 {
                        var first = last
                        while first > offset && levels[first-1] > 0 { first -= 1 }
                        if first > offset { end = first }
                    }
                }
                pages.append(TextPage(chapter:chapter,offset:lines[offset].0,end:end < lines.count ? lines[end].0 : chars.count,lines:Array(lines[offset..<end].map(\.1)),headingLevels:Array(levels[offset..<end]),imageRows:Array(imageRows[offset..<end])))
                offset = end
            }
        }
        return pages
    }
    public static func pageIndex(_ pages: [TextPage], chapter: Int, offset: Int) -> Int {
        var low = 0, high = pages.count
        while low < high {
            let mid = low + (high-low)/2, page = pages[mid]
            if page.chapter < chapter || (page.chapter == chapter && page.offset <= offset) { low = mid+1 }
            else { high = mid }
        }
        var result = max(0,low-1)
        if pages.indices.contains(result) {
            let start = pages[result].offset
            while result > 0 && pages[result-1].chapter == chapter && pages[result-1].offset == start { result -= 1 }
        }
        return result
    }
}
