import Foundation
import CryptoKit
import PDFKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

public struct TextHeading {
    public let range: Range<Int>
    public let level: Int
}
public struct TextIllustration {
    public let range: Range<Int>
    public let image: TerminalImage?
}
public struct TextChapter {
    public let title: String
    public let text: String
    public let href: String
    public let spineIndex: Int
    public let headings: [TextHeading]
    public let illustrations: [TextIllustration]
    public init(title: String, text: String, href: String = "", spineIndex: Int = 0, headings: [TextHeading] = [], illustrations: [TextIllustration] = []) {
        self.title = title; self.text = text; self.href = href; self.spineIndex = spineIndex
        self.headings = headings; self.illustrations = illustrations
    }
}
public struct TextContentsEntry {
    public let title: String
    public let chapter: Int
    public let offset: Int
    public let depth: Int
}
public struct TextBook {
    public let id: String
    public let progressKey: String
    public let spineCount: Int
    public let title: String
    public let chapters: [TextChapter]
    public let contents: [TextContentsEntry]
    public init(id: String, title: String, chapters: [TextChapter], contents: [TextContentsEntry]? = nil, progressKey: String? = nil, spineCount: Int? = nil) {
        self.spineCount = spineCount ?? chapters.count
        self.progressKey = progressKey ?? id
        self.id = id; self.title = title; self.chapters = chapters
        self.contents = contents ?? chapters.enumerated().map { TextContentsEntry(title:$1.title,chapter:$0,offset:0,depth:0) }
    }

    public static func open(_ url: URL) throws -> TextBook {
        switch BookFormat(filename:url.lastPathComponent) {
        case .epub: return try openEPUB(url)
        case .pdf: return try openPDF(url)
        case nil: throw BookImportFile.Failure.format
        }
    }

    private static func openPDF(_ url: URL) throws -> TextBook {
        let data = try BookImportFile.read(url)
        let document = try BookImportFile.pdfDocument(data)
        var hasText = false
        let chapters = (0..<document.pageCount).map { index in
            let text = document.page(at:index)?.string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            if !text.isEmpty { hasText = true }
            return TextChapter(title:"第 \(index + 1) 页",text:text.isEmpty ? "此页没有可提取的文字" : text,
                               href:PDFPageLocator.encode(index),spineIndex:index)
        }
        guard hasText else { throw TextError("这份 PDF 没有可提取的文字，请用书籍人生图形界面阅读。") }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines)
        let key = BookImportFile.fingerprint(data)
        return TextBook(id:key,title:title.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent,chapters:chapters)
    }

    private static func openEPUB(_ url: URL) throws -> TextBook {
        let isDirectory = (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true
        let data = isDirectory ? Data() : try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 50 * 1024 * 1024 else { throw TextError("EPUB 超过 50 MB") }
        var directoryDigest = SHA256()
        var total = 0
        func extract(_ path: String, includeInDigest: Bool = true) throws -> Data {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator:"/").contains(".."), !path.contains("\0") else { throw TextError("EPUB 资源路径无效") }
            if isDirectory {
                let root = url.resolvingSymlinksInPath().standardizedFileURL
                let resource = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard resource.path.hasPrefix(root.path + "/") else { throw TextError("EPUB 资源超出书籍目录") }
                guard FileManager.default.fileExists(atPath:resource.path) else { throw TextError("书籍尚未完整下载，请先在 Apple Books 下载后重试") }
                let size = try resource.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size <= 20 * 1024 * 1024, total + size <= 100 * 1024 * 1024 else { throw TextError("EPUB 文本资源过大") }
                let result = try Data(contentsOf:resource)
                total += result.count
                if includeInDigest { directoryDigest.update(data:result) }
                return result
            }
            let task = Process(), pipe = Pipe()
            task.executableURL = URL(fileURLWithPath:"/usr/bin/unzip")
            // unzip treats member names as patterns even without a shell. Escape
            // its metacharacters so valid filenames select exactly one resource.
            let member = path.map { "\\*?[".contains($0) ? "\\" + String($0) : String($0) }.joined()
            task.arguments = ["-p",url.path,member]
            task.standardOutput = pipe; task.standardError = FileHandle.nullDevice; task.standardInput = FileHandle.nullDevice
            try task.run()
            var result = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount:65536), !chunk.isEmpty {
                total += chunk.count
                if result.count + chunk.count > 20 * 1024 * 1024 || total > 100 * 1024 * 1024 {
                    task.terminate(); task.waitUntilExit(); throw TextError("EPUB 文本资源过大")
                }
                result.append(chunk)
            }
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw TextError("无法读取 EPUB 资源：\(path)") }
            return result
        }
        let container = XMLTree()
        try container.parse(extract("META-INF/container.xml"))
        guard let package = container.items.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else { throw TextError("EPUB 缺少内容清单") }
        let packageData = try extract(package)
        let opf = XMLTree(); try opf.parse(packageData)
        guard !opf.items.contains(where: { $0.attributes["property"] == "rendition:layout" && $0.text.trimmingCharacters(in:.whitespacesAndNewlines) == "pre-paginated" }) else { throw TextError("终端版暂不支持固定版式 EPUB") }
        let manifest = opf.items.filter { $0.name == "item" }
        let base = (package as NSString).deletingLastPathComponent
        let title = clean(opf.items.first { $0.name == "title" }?.text ?? url.deletingPathExtension().lastPathComponent)
        // Resolve links relative to the navigation document, not the OPF. Decode
        // after splitting the fragment so encoded filenames retain their meaning.
        func target(_ href: String, relativeTo file: String) -> (path: String, fragment: String)? {
            guard let components = URLComponents(string:href), components.scheme == nil, components.host == nil,
                  !href.hasPrefix("/") else { return nil }
            let parts = href.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)
            let resource = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let rawPath = resource.isEmpty ? file : ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(resource)
            guard !rawPath.hasPrefix("/") else { return nil }
            var segments: [Substring] = []
            for segment in rawPath.split(separator:"/") {
                if segment == ".." { guard !segments.isEmpty else { return nil }; segments.removeLast() }
                else if segment != "." { segments.append(segment) }
            }
            let path = segments.joined(separator:"/")
            let fragment = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            return (path,fragment)
        }
        struct Navigation { let title: String; let path: String; let fragment: String; let depth: Int }
        func navigation(_ item: XMLTree.Item, ncx: Bool) -> [Navigation] {
            guard let href = item.attributes["href"], let file = target(href,relativeTo:package)?.path,
                  let data = try? extract(file,includeInDigest:false) else { return [] }
            let tree = XMLTree(); guard (try? tree.parse(data)) != nil else { return [] }
            var result: [Navigation] = []
            for (index,node) in tree.items.enumerated() {
                var label = "", link: String?, depth = 0
                if ncx && node.name == "navPoint" {
                    let children = tree.items.filter { $0.parent == index }
                    label = clean(children.first { $0.name == "navLabel" }?.text ?? "")
                    link = children.first { $0.name == "content" }?.attributes["src"]
                    depth = tree.ancestors(index).filter { tree.items[$0].name == "navPoint" }.count
                } else if !ncx && node.name == "a" {
                    let ancestors = tree.ancestors(index)
                    guard ancestors.contains(where: { ancestor in
                        let candidate = tree.items[ancestor]
                        return candidate.name == "nav" && (candidate.attributes["epub:type"] ?? candidate.attributes["type"] ?? "").split(separator:" ").contains("toc")
                    }) else { continue }
                    label = clean(node.text); link = node.attributes["href"]
                    depth = max(0,ancestors.filter { tree.items[$0].name == "ol" }.count - 1)
                }
                guard !label.isEmpty, let link, let resolved = target(link,relativeTo:file) else { continue }
                result.append(Navigation(title:label,path:resolved.path,fragment:resolved.fragment,depth:depth))
            }
            return result
        }
        var navigationItems: [Navigation] = []
        if let nav = manifest.first(where: { ($0.attributes["properties"] ?? "").split(separator:" ").contains("nav") }) {
            navigationItems = navigation(nav,ncx:false)
        }
        if navigationItems.isEmpty {
            let tocID = opf.items.first { $0.name == "spine" }?.attributes["toc"]
            if let ncx = manifest.first(where: { $0.attributes["id"] == tocID && tocID != nil }) ?? manifest.first(where: { $0.attributes["media-type"] == "application/x-dtbncx+xml" }) {
                navigationItems = navigation(ncx,ncx:true)
            }
        }
        var imageCache: [String:TerminalImage] = [:]
        var chapters: [TextChapter] = []
        var locations: [String:(chapter:Int, anchors:[String:Int])] = [:]
        let spine = opf.items.filter { $0.name == "itemref" && $0.attributes["linear"] != "no" }
        for (spineIndex,entry) in spine.enumerated() {
            guard let item = manifest.first(where: { $0.attributes["id"] == entry.attributes["idref"] }),
                  let href = item.attributes["href"], item.attributes["media-type"] == "application/xhtml+xml" else { continue }
            guard let resource = href.split(separator:"#",maxSplits:1).first, !resource.isEmpty else { throw TextError("EPUB 章节路径为空") }
            let decoded = String(resource).removingPercentEncoding ?? String(resource)
            let path = ((base as NSString).appendingPathComponent(decoded) as NSString).standardizingPath
            let document = XMLTree(); try document.parse(extract(path))
            let text = clean(document.body)
            guard !text.isEmpty else { continue }
            let heading = document.items.first { ["h1","h2","h3","h4","h5","h6"].contains($0.name) && $0.bodyOffset != nil && !clean($0.text).isEmpty }
            let documentTitle = clean(document.items.first { $0.name == "title" }?.text ?? "")
            let fallback = documentTitle.isEmpty || documentTitle == title ? "第 \(chapters.count + 1) 节" : documentTitle
            let chapterTitle = navigationItems.first { $0.path == path }?.title ?? heading.map { clean($0.text) } ?? fallback
            let chars = Array(text)
            func offset(_ raw: Int) -> Int {
                var result = clean(String(document.body.prefix(raw))).count
                while result < chars.count && chars[result].isWhitespace { result += 1 }
                return min(result,chars.count)
            }
            var headings = document.items.compactMap { node -> TextHeading? in
                guard let start = node.bodyOffset, let end = node.bodyEnd,
                      let level = Int(node.name.dropFirst()), node.name.first == "h", (1...6).contains(level) else { return nil }
                let lower = offset(start), upper = min(chars.count,clean(String(document.body.prefix(end))).count)
                guard lower < upper else { return nil }
                return TextHeading(range:lower..<upper,level:level)
            }
            // Many converted EPUBs use styled <p> tags for every subchapter.
            // A matching TOC label is reliable heading evidence without applying
            // arbitrary CSS or guessing from paragraph length.
            for node in document.items where ["p","div"].contains(node.name) {
                guard let start = node.bodyOffset, let end = node.bodyEnd,
                      let entry = navigationItems.first(where:{ $0.path == path && $0.title == clean(node.text) }) else { continue }
                let lower = offset(start), upper = min(chars.count,clean(String(document.body.prefix(end))).count)
                guard lower < upper, !headings.contains(where:{ $0.range.overlaps(lower..<upper) }) else { continue }
                headings.append(TextHeading(range:lower..<upper,level:min(6,entry.depth+1)))
            }
            let illustrations = document.items.compactMap { node -> TextIllustration? in
                guard ["img","image"].contains(node.name), let start = node.bodyOffset, let end = node.bodyEnd else { return nil }
                let source = node.attributes["src"] ?? node.attributes["href"] ?? node.attributes["xlink:href"] ?? ""
                var image: TerminalImage?
                if let resource = target(source,relativeTo:path), !source.isEmpty {
                    image = imageCache[resource.path]
                    if image == nil, let bytes = try? extract(resource.path,includeInDigest:false) {
                        image = TerminalImage(data:bytes)
                        imageCache[resource.path] = image
                    }
                }
                return TextIllustration(range:offset(start)..<min(chars.count,clean(String(document.body.prefix(end))).count),image:image)
            }
            var anchors: [String:Int] = [:]
            for node in document.items {
                guard let id = node.attributes["id"] ?? node.attributes["xml:id"] ?? (node.name == "a" ? node.attributes["name"] : nil),
                      let rawOffset = node.bodyOffset else { continue }
                anchors[id] = min(offset(rawOffset),max(0,chars.count-1))
            }
            locations[path] = (chapters.count,anchors)
            chapters.append(TextChapter(title:chapterTitle,text:text,href:decoded,spineIndex:spineIndex,headings:headings,illustrations:illustrations))
        }
        guard !chapters.isEmpty else { throw TextError("没有可读正文；请使用无 DRM、可重排版 EPUB") }
        let contents = navigationItems.compactMap { item -> TextContentsEntry? in
            guard let location = locations[item.path] else { return nil }
            let offset: Int
            if item.fragment.isEmpty { offset = 0 }
            else if let anchor = location.anchors[item.fragment] { offset = anchor }
            else { return nil } // Never silently jump to the wrong chapter/anchor.
            return TextContentsEntry(title:item.title,chapter:location.chapter,offset:offset,depth:item.depth)
        }
        let digest = isDirectory ? directoryDigest.finalize() : SHA256.hash(data:data)
        return TextBook(id:digest.map { String(format:"%02x",$0) }.joined(),title:title,chapters:chapters,contents:contents.isEmpty ? nil : contents,progressKey:ReadingProgress.bookKey(package:packageData),spineCount:spine.count)
    }
}

public struct TextError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// Remove terminal control sequences supplied by a book, including OSC and bidi controls.
public func clean(_ text: String) -> String {
    text.unicodeScalars.filter { scalar in
        scalar == "\n" || (!CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.illegalCharacters.contains(scalar) && ![0x202A,0x202B,0x202C,0x202D,0x202E,0x2066,0x2067,0x2068,0x2069].contains(scalar.value))
    }.map(String.init).joined().components(separatedBy:"\n").map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ") }.joined(separator:"\n").replacingOccurrences(of:"\n{3,}",with:"\n\n",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
}

private final class XMLTree: NSObject, XMLParserDelegate {
    struct Item { var name: String; var attributes: [String:String]; var parent: Int?; var bodyOffset: Int?; var bodyEnd: Int?; var text = "" }
    var items: [Item] = [], stack: [Int] = [], body = "", bodyDepth = 0, ignored = 0
    let blocks: Set<String> = ["p","div","h1","h2","h3","h4","h5","h6","li","blockquote","section","article","figure","figcaption","pre","tr"]
    func ancestors(_ index: Int) -> [Int] {
        var result: [Int] = [], parent = items[index].parent
        while let current = parent { result.append(current); parent = items[current].parent }
        return result
    }
    func parse(_ data: Data) throws {
        let parser = XMLParser(data:data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw TextError("EPUB XML 无法解析：\(parser.parserError?.localizedDescription ?? "格式错误")") }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        let name = String(elementName.split(separator:":").last ?? "")
        items.append(Item(name:name,attributes:attributes,parent:stack.last,bodyOffset:bodyDepth > 0 || name == "body" ? body.count : nil)); stack.append(items.count - 1)
        if name == "body" { bodyDepth = stack.count }
        if ["script","style","head"].contains(name) { ignored += 1 }
        if bodyDepth > 0 && ignored == 0 {
            if blocks.contains(name) { body += "\n\n" }
            if name == "br" { body += "\n" }
            if ["img","image"].contains(name) { body += "\n\n[\(clean(attributes["alt"] ?? "").isEmpty ? "图片" : clean(attributes["alt"]!))]"; items[stack.last!].bodyEnd = body.count; body += "\n\n" }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in stack { items[index].text += string }
        if bodyDepth > 0 && ignored == 0 {
            // XHTML indentation is source formatting, not a paragraph boundary.
            // Collapse it even across parser callbacks and inline elements.
            if stack.contains(where:{ items[$0].name == "pre" }) { body += string }
            else {
                for char in string {
                    if char.isWhitespace {
                        if let last = body.last, !last.isWhitespace { body += " " }
                    } else { body.append(char) }
                }
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = String(elementName.split(separator:":").last ?? "")
        if let index = stack.last, items[index].bodyEnd == nil { items[index].bodyEnd = body.count }
        if bodyDepth > 0 && ignored == 0 && blocks.contains(name) { body += "\n\n" }
        if ["script","style","head"].contains(name) { ignored -= 1 }
        if name == "body" { bodyDepth = 0 }
        _ = stack.popLast()
    }
}
