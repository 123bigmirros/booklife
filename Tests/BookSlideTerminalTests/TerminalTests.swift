import XCTest
import Darwin
@testable import BookSlideTerminal

final class TerminalTests: XCTestCase {
    override func setUp() { setlocale(LC_ALL,"en_US.UTF-8") }
    private func fixture(navigation: String?, epub3: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("META-INF"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("EPUB/nav"),withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        func write(_ path: String, _ value: String) throws { try value.write(to:root.appendingPathComponent(path),atomically:true,encoding:.utf8) }
        try write("META-INF/container.xml","<container><rootfiles><rootfile full-path=\"EPUB/content.opf\"/></rootfiles></container>")
        let navItem = navigation == nil ? "" : "<item id=\"toc\" href=\"nav/toc.\(epub3 ? "xhtml" : "ncx")\" media-type=\"\(epub3 ? "application/xhtml+xml" : "application/x-dtbncx+xml")\" \(epub3 ? "properties=\"nav\"" : "")/>"
        try write("EPUB/content.opf","<package><metadata><title>共同书名</title></metadata><manifest>\(navItem)<item id=\"one\" href=\"chapter%20one.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"two\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine toc=\"toc\"><itemref idref=\"one\"/><itemref idref=\"two\"/></spine></package>")
        try write("EPUB/chapter one.xhtml","<html><head><title>共同书名</title></head><body><h1 id=\"first\">正文第一章</h1><p>\(String(repeating:"前段文字。",count:100))</p><h2 id=\"后段\">正文第二节</h2><p>这里是第二节正文。</p></body></html>")
        try write("EPUB/two.xhtml","<html><head><title>共同书名</title></head><body><h1>正文第二章</h1><p>下一章文字</p></body></html>")
        if let navigation { try write("EPUB/nav/toc.\(epub3 ? "xhtml" : "ncx")",navigation) }
        return root
    }
    private var illustrationPNG: Data {
        Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAABAAAAAICAYAAADwdn+XAAAAGUlEQVR4nGP4z8DwHx8mIP2foIpRA4aCAQCNpv8BMqhbfwAAAABJRU5ErkJggg==")!
    }
    func testSourceIndentationDoesNotSplitParagraphsAndAllHeadingLevelsAreStyled() throws {
        let root = try fixture(navigation:nil)
        try """
        <html><body>
          <h5 id="small">小章节标题</h5>
          <p>One
            <em>continuous</em> paragraph.</p>
          <h6>更小的标题</h6><p>下一段<br/>换行</p><h6> </h6>
        </body></html>
        """.write(to:root.appendingPathComponent("EPUB/chapter one.xhtml"),atomically:true,encoding:.utf8)
        let chapter = try TextBook.open(root).chapters[0]
        XCTAssertEqual(chapter.text,"小章节标题\n\nOne continuous paragraph.\n\n更小的标题\n\n下一段\n换行")
        XCTAssertEqual(chapter.headings.map(\.level),[5,6])
        XCTAssertEqual(chapter.headings.map { String(Array(chapter.text)[$0.range]) },["小章节标题","更小的标题"])
        let pages = TextLayout.pages(TextBook(id:"x",title:"x",chapters:[chapter]),columns:20,rows:5)
        XCTAssertFalse(pages.contains { page in
            let last = page.lines.indices.last(where:{ !page.lines[$0].isEmpty })
            return last.map { page.headingLevels[$0] > 0 } ?? false
        })
    }
    func testTOCRecognizesConvertedParagraphSubheadings() throws {
        let root = try fixture(navigation:"<ncx><navMap><navPoint><navLabel><text>小章节</text></navLabel><content src=\"../chapter%20one.xhtml#small\"/></navPoint></navMap></ncx>")
        try "<html><body><p>前文</p><p id=\"small\" class=\"calibre_3\">小章节</p><p>章节正文</p></body></html>".write(to:root.appendingPathComponent("EPUB/chapter one.xhtml"),atomically:true,encoding:.utf8)
        let book = try TextBook.open(root), chapter = book.chapters[0]
        XCTAssertEqual(chapter.headings.count,1)
        XCTAssertEqual(String(Array(chapter.text)[chapter.headings[0].range]),"小章节")
        XCTAssertEqual(chapter.headings[0].range.lowerBound,book.contents[0].offset)
    }
    func testIllustrationsResolveRelativePathsInDirectoryAndArchiveWithoutChangingIdentity() throws {
        let root = try fixture(navigation:nil)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("EPUB/images"),withIntermediateDirectories:true)
        let chapterURL = root.appendingPathComponent("EPUB/chapter one.xhtml")
        try "<html><body><h2>插图</h2><p>前文</p><img src=\"images/a%20b.png\" alt=\"红蓝插图\"/><p>后文</p></body></html>".write(to:chapterURL,atomically:true,encoding:.utf8)
        let withoutImage = try TextBook.open(root)
        try illustrationPNG.write(to:root.appendingPathComponent("EPUB/images/a b.png"))
        let book = try TextBook.open(root)
        XCTAssertEqual(book.id,withoutImage.id)
        XCTAssertEqual(book.chapters[0].text,withoutImage.chapters[0].text)
        XCTAssertNotNil(book.chapters[0].illustrations.first?.image)
        XCTAssertTrue(book.chapters[0].text.contains("[红蓝插图]"))
        let pages = TextLayout.pages(book,columns:24,rows:1,images:true,imageMaxRows:4)
        let imagePages = pages.filter { $0.imageRows[0] != nil }
        XCTAssertEqual(imagePages.count,4)
        XCTAssertEqual(imagePages.compactMap { $0.imageRows[0]?.row },[0,1,2,3])
        XCTAssertEqual(TextLayout.pageIndex(pages,chapter:0,offset:imagePages[0].offset),pages.firstIndex { $0.imageRows[0] != nil })
        XCTAssertTrue(pages.flatMap(\.lines).joined().contains("后文"))
        XCTAssertFalse(pages.flatMap(\.lines).joined().contains("[红蓝插图]"))
        XCTAssertTrue(TextLayout.pages(book,columns:24,rows:10).flatMap(\.lines).joined().contains("[红蓝插图]"))
        let image = try XCTUnwrap(book.chapters[0].illustrations.first?.image)
        for row in 0..<16 { XCTAssertNotNil(image.png(firstRow:row,rowCount:1,totalRows:16)) }
        XCTAssertNil(image.png(firstRow:0,rowCount:1,totalRows:0))
        let cropped = try XCTUnwrap(image.png(firstRow:1,rowCount:2,totalRows:4))
        XCTAssertEqual(try XCTUnwrap(TerminalImage(data:cropped)).aspectRatio,4,accuracy:0.01)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".epub")
        addTeardownBlock { try? FileManager.default.removeItem(at:archive) }
        try EPUBArchive.data(at:root).write(to:archive)
        XCTAssertNotNil(try TextBook.open(archive).chapters[0].illustrations.first?.image)
    }
    func testSVGImageReferencesAndUnsafeOrMissingImagesFallBackToDescriptions() throws {
        let root = try fixture(navigation:nil)
        try illustrationPNG.write(to:root.appendingPathComponent("EPUB/picture.png"))
        try """
        <html xmlns:xlink="http://www.w3.org/1999/xlink"><body>
        <svg><image xlink:href="picture.png"/></svg>
        <img src="https://example.com/image.png" alt="外部图片"/>
        <img src="../../outside.png" alt="越界图片"/>
        <img src="missing.png" alt="缺失图片"/>
        </body></html>
        """.write(to:root.appendingPathComponent("EPUB/chapter one.xhtml"),atomically:true,encoding:.utf8)
        let book = try TextBook.open(root)
        XCTAssertEqual(book.chapters[0].illustrations.count,4)
        XCTAssertNotNil(book.chapters[0].illustrations[0].image)
        XCTAssertTrue(book.chapters[0].illustrations.dropFirst().allSatisfy { $0.image == nil })
        let text = TextLayout.pages(book,columns:24,rows:20,images:true).flatMap(\.lines).joined()
        XCTAssertTrue(text.contains("[外部图片]"))
        XCTAssertTrue(text.contains("[越界图片]"))
        XCTAssertTrue(text.contains("[缺失图片]"))
    }
    func testImageProtocolsDetectGhosttyAndChunkPNGWithoutTerminalReplies() {
        XCTAssertEqual(TerminalImageProtocol.detect(environment:["TERM_PROGRAM":"ghostty"]),.kitty)
        XCTAssertEqual(TerminalImageProtocol.detect(environment:["TERM":"xterm-ghostty"]),.kitty)
        XCTAssertEqual(TerminalImageProtocol.detect(environment:["TERM_PROGRAM":"iTerm.app"]),.iterm2)
        XCTAssertEqual(TerminalImageProtocol.detect(environment:["TERM_PROGRAM":"ghostty","BOOKSLIDE_IMAGES":"none"]),.none)
        XCTAssertEqual(TerminalImageProtocol.detect(environment:[:]),.none)
        let output = TerminalImageProtocol.kitty.display(Data(repeating:42,count:10000),id:123,columns:20,rows:8)
        let chunks = output.components(separatedBy:"\u{1B}\\").filter { !$0.isEmpty }
        XCTAssertGreaterThan(chunks.count,1)
        XCTAssertTrue(chunks[0].contains("a=T,f=100,t=d,i=123,c=20,r=8,C=1,q=2,m=1;"))
        XCTAssertTrue(chunks.last!.contains("m=0;"))
        XCTAssertTrue(chunks.allSatisfy { $0.contains("q=2") && $0.split(separator:";").last!.count <= 4096 })
        let payload = chunks.map { String($0.split(separator:";").last!) }.joined()
        XCTAssertEqual(Data(base64Encoded:payload),Data(repeating:42,count:10000))
        XCTAssertTrue(TerminalImageProtocol.iterm2.display(illustrationPNG,id:1,columns:20,rows:8).contains("inline=1;size="))
    }
    func testNCXUsesLabelsAndNestedTargetsInsteadOfRepeatedHTMLTitle() throws {
        let root = try fixture(navigation:"""
        <ncx><navMap><navPoint><navLabel><text>第一夜</text></navLabel><content src="../chapter%20one.xhtml"/>
          <navPoint><navLabel><text>心理创伤并不存在</text></navLabel><content src="../chapter%20one.xhtml#%E5%90%8E%E6%AE%B5"/></navPoint>
        </navPoint><navPoint><navLabel><text>第二夜</text></navLabel><content src="../two.xhtml"/></navPoint></navMap></ncx>
        """)
        let book = try TextBook.open(root)
        XCTAssertEqual(book.contents.map(\.title),["第一夜","心理创伤并不存在","第二夜"])
        XCTAssertEqual(book.contents.map(\.depth),[0,1,0])
        XCTAssertEqual(book.contents.map(\.chapter),[0,0,1])
        XCTAssertEqual(book.chapters.map(\.title),["第一夜","第二夜"])
        let target = book.contents[1]
        XCTAssertTrue(String(book.chapters[0].text.dropFirst(target.offset)).hasPrefix("正文第二节"))
        let pages = TextLayout.pages(book,columns:24,rows:4)
        let destination = pages[TextLayout.pageIndex(pages,chapter:target.chapter,offset:target.offset)]
        XCTAssertGreaterThan(destination.offset,0)
        XCTAssertTrue(destination.lines.joined().contains("正文第二节"))
    }
    func testEPUB3TOCExcludesLandmarksAndResolvesAnchors() throws {
        let root = try fixture(navigation:"""
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="landmarks"><ol><li><a href="../two.xhtml">不是目录</a></li></ol></nav>
        <nav epub:type="toc"><ol><li><a href="../chapter%20one.xhtml#first">真正的第一章</a>
        <ol><li><a href="../chapter%20one.xhtml#后段">第二节</a></li></ol></li>
        <li><a href="../two.xhtml">真正的第二章</a></li>
        <li><a href="../two.xhtml#missing">无效锚点</a></li>
        <li><a href="https://example.com">外部链接</a></li></ol></nav></body></html>
        """,epub3:true)
        let book = try TextBook.open(root)
        XCTAssertEqual(book.contents.map(\.title),["真正的第一章","第二节","真正的第二章"])
        XCTAssertEqual(book.contents.map(\.depth),[0,1,0])
        XCTAssertTrue(String(book.chapters[0].text.dropFirst(book.contents[1].offset)).hasPrefix("正文第二节"))
    }
    func testMissingTOCFallsBackToBodyHeadingsWithoutChangingBookIdentity() throws {
        let root = try fixture(navigation:nil)
        let first = try TextBook.open(root)
        XCTAssertEqual(first.contents.map(\.title),["正文第一章","正文第二章"])
        // Navigation-only corrections must not invalidate existing directory EPUB progress.
        let withTOC = try fixture(navigation:"<ncx><navMap><navPoint><navLabel><text>目录名</text></navLabel><content src=\"../two.xhtml\"/></navPoint></navMap></ncx>")
        let before = try TextBook.open(withTOC)
        try "<ncx><navMap><navPoint><navLabel><text>新目录名</text></navLabel><content src=\"../two.xhtml\"/></navPoint></navMap></ncx>".write(to:withTOC.appendingPathComponent("EPUB/nav/toc.ncx"),atomically:true,encoding:.utf8)
        XCTAssertEqual(before.id,try TextBook.open(withTOC).id)
    }
    func testChineseAndCombiningCharactersFitColumns() {
        let book = TextBook(id:"test",title:"书",chapters:[TextChapter(title:"一",text:"中文阅读 e\u{301} hello world\n\n再读一页")])
        let pages = TextLayout.pages(book,columns:8,rows:2)
        XCTAssertTrue(pages.flatMap(\.lines).allSatisfy { TextLayout.width($0) <= 8 })
        XCTAssertEqual(TextLayout.width("中文"),4)
        XCTAssertEqual(TextLayout.width("e\u{301}"),1)
        XCTAssertTrue(pages.count > 1)
    }
    func testPageLookupAtChapterAndLineBoundaries() {
        let book = TextBook(id:"test",title:"test",chapters:[TextChapter(title:"one",text:"abcdef\nghij"),TextChapter(title:"two",text:"klmnop\nqrst")])
        let pages = TextLayout.pages(book,columns:4,rows:1)
        for chapter in -1...3 {
            for offset in -1...30 {
                let expected = pages.lastIndex { $0.chapter < chapter || ($0.chapter == chapter && $0.offset <= offset) } ?? 0
                XCTAssertEqual(TextLayout.pageIndex(pages,chapter:chapter,offset:offset),expected)
            }
        }
        XCTAssertEqual(TextLayout.pageIndex([],chapter:0,offset:0),0)
    }
    func testResizeKeepsContentAnchorAndChapterOrder() {
        let book = TextBook(id:"test",title:"书",chapters:[TextChapter(title:"一",text:String(repeating:"文字",count:80)),TextChapter(title:"二",text:"末章")])
        let old = TextLayout.pages(book,columns:20,rows:3)[2]
        let pages = TextLayout.pages(book,columns:12,rows:4)
        let page = pages[TextLayout.pageIndex(pages,chapter:old.chapter,offset:old.offset)]
        XCTAssertEqual(page.chapter,old.chapter)
        XCTAssertLessThanOrEqual(page.offset,old.offset)
        XCTAssertGreaterThan(page.end,old.offset)
        XCTAssertEqual(pages.last?.chapter,1)
    }
    func testChinesePunctuationDoesNotStartWrappedLine() {
        let book = TextBook(id:"x",title:"x",chapters:[TextChapter(title:"x",text:"阅读文字，继续阅读。")])
        let lines = TextLayout.pages(book,columns:8,rows:20).flatMap(\.lines)
        XCTAssertFalse(lines.contains { $0.hasPrefix("，") || $0.hasPrefix("。") })
        XCTAssertEqual(lines.joined(),book.chapters[0].text)
    }
    func testBookTextCannotInjectTerminalEscapes() {
        XCTAssertFalse(clean("text\u{1B}[2J\u{07}\u{202E}end").contains("\u{1B}"))
        XCTAssertFalse(clean("\u{202E}text").contains("\u{202E}"))
    }
    func testBundledEPUBSpineAndText() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let book = try TextBook.open(root.appendingPathComponent("Sources/BookSlideMac/Resources/Reader/QuietHours.epub"))
        XCTAssertEqual(book.chapters.count,3)
        XCTAssertEqual(book.title,"留一点时间，给阅读")
        XCTAssertTrue(book.chapters[0].text.contains("窗边的光"))
        XCTAssertTrue(book.chapters[1].text.contains("书页之间"))
        XCTAssertEqual(book.id.count,64)
    }
    func testLiteralWildcardFilenamesInDirectoryAndArchiveEPUB() throws {
        for name in ["chapter*.xhtml", "chapter?.xhtml", "chapter[1].xhtml", "chapter\\name.xhtml"] {
            let href = name.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
            let root = try fixture(navigation:"<ncx><navMap><navPoint><navLabel><text>特殊文件名章节</text></navLabel><content src=\"../\(href)#first\"/></navPoint></navMap></ncx>")
            let opfURL = root.appendingPathComponent("EPUB/content.opf")
            let opf = try String(contentsOf:opfURL).replacingOccurrences(of:"chapter%20one.xhtml",with:href)
            try opf.write(to:opfURL,atomically:true,encoding:.utf8)
            try FileManager.default.moveItem(at:root.appendingPathComponent("EPUB/chapter one.xhtml"),to:root.appendingPathComponent("EPUB/" + name))
            // Unescaped ZIP wildcards would select this extra file (or select it
            // instead of the literal bracketed name), breaking chapter parsing.
            try "<html><body><p>错误的章节</p></body></html>".write(to:root.appendingPathComponent("EPUB/chapter1.xhtml"),atomically:true,encoding:.utf8)
            let directory = try TextBook.open(root)
            XCTAssertEqual(directory.chapters.count,2)
            XCTAssertEqual(directory.contents.first?.title,"特殊文件名章节")
            XCTAssertEqual(directory.chapters.first?.href,name)
            XCTAssertTrue(directory.chapters[0].text.contains("这里是第二节正文"))
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
            addTeardownBlock { try? FileManager.default.removeItem(at:archive) }
            try EPUBArchive.data(at:root).write(to:archive)
            let zipped = try TextBook.open(archive)
            XCTAssertEqual(zipped.chapters.map(\.text),directory.chapters.map(\.text),name)
            XCTAssertEqual(zipped.contents.map(\.title),directory.contents.map(\.title),name)
        }
    }
    func testResourcePathsStillRejectTraversalAndAbsolutePaths() throws {
        for path in ["../outside.opf", "/outside.opf"] {
            let root = try fixture(navigation:nil)
            try "<container><rootfiles><rootfile full-path=\"\(path)\"/></rootfiles></container>".write(to:root.appendingPathComponent("META-INF/container.xml"),atomically:true,encoding:.utf8)
            XCTAssertThrowsError(try TextBook.open(root)) { error in
                XCTAssertEqual(error.localizedDescription,"EPUB 资源路径无效")
            }
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
            addTeardownBlock { try? FileManager.default.removeItem(at:archive) }
            try EPUBArchive.data(at:root).write(to:archive)
            XCTAssertThrowsError(try TextBook.open(archive)) { error in
                XCTAssertEqual(error.localizedDescription,"EPUB 资源路径无效")
            }
        }
    }
    func testDirectoryEPUBMatchesArchiveAndRejectsEscapingSymlinks() throws {
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = project.appendingPathComponent("Sources/BookSlideMac/Resources/Reader/QuietHours.epub")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("test.epub")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath:"/usr/bin/unzip")
        unzip.arguments = ["-q",source.path,"-d",package.path]; try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus,0)
        let archive = try TextBook.open(source), directory = try TextBook.open(package)
        XCTAssertEqual(directory.title,archive.title)
        XCTAssertEqual(directory.chapters.map(\.text),archive.chapters.map(\.text))
        let prepared = root.appendingPathComponent("prepared.epub")
        try EPUBArchive.data(at:package).write(to:prepared)
        XCTAssertEqual(try TextBook.open(prepared).chapters.map(\.text),archive.chapters.map(\.text))
        let chapter = package.appendingPathComponent("EPUB/chapter0.xhtml")
        let outside = root.appendingPathComponent("outside.xhtml")
        try FileManager.default.moveItem(at:chapter,to:outside)
        try FileManager.default.createSymbolicLink(at:chapter,withDestinationURL:outside)
        XCTAssertThrowsError(try TextBook.open(package))
    }
}
