import XCTest
import BookSlideCore
@testable import BookSlideTerminal

final class TextProgressTests: XCTestCase {
    func testPortableAnchorRoundTripsAcrossWhitespaceAndRepeatedText() throws {
        let text="第一段。\n\n相同句子在这里。\n第二段 😀 e\u{301}。\n相同句子在这里。结尾。"
        let book=TextBook(id:"a",title:"test",chapters:[TextChapter(title:"chapter",text:text,href:"Text/章节.xhtml")])
        let offset=text.distance(from:text.startIndex,to:text.range(of:"相同句子",options:.backwards)!.lowerBound)
        var anchor=book.anchor(chapter:0,offset:offset)
        anchor.quote="相同句子在这里。"
        let target=try XCTUnwrap(book.location(for:anchor))
        XCTAssertEqual(target.chapter,0); XCTAssertEqual(target.offset,offset)
        var encoded=anchor; encoded.href="Text/%E7%AB%A0%E8%8A%82.xhtml"
        XCTAssertEqual(book.location(for:encoded)?.offset,offset)
        var missing=anchor; missing.href="missing.xhtml"; XCTAssertNil(book.location(for:missing))
    }
    func testCachedAnchorsMatchPortableFormatAtEveryCharacter() {
        for text in ["", "空 白\n\n标点。😀 e\u{301} 👨‍👩‍👧‍👦\u{202e}结尾", String(repeating:"一段阅读文字。 \n",count:30)] {
            let book = TextBook(id:"test",title:"test",chapters:[TextChapter(title:"chapter",text:text,href:"chapter.xhtml")])
            let index = TextAnchorIndex(text)
            for offset in 0...text.count {
                XCTAssertEqual(index.anchor(href:"chapter.xhtml",offset:offset),book.anchor(chapter:0,offset:offset))
            }
        }
    }
    func testPackageIdentityIsIndependentOfArchiveContainer() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file=root.appendingPathComponent("Sources/BookSlideMac/Resources/Reader/QuietHours.epub")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".epub")
        defer { try? FileManager.default.removeItem(at:directory) }
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments=["-q",file.path,"-d",directory.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let archive=try TextBook.open(file), folder=try TextBook.open(directory)
        XCTAssertEqual(archive.progressKey,folder.progressKey)
        XCTAssertEqual(archive.chapters.map(\.href),folder.chapters.map(\.href))
        XCTAssertEqual(archive.progressKey.count,64)
    }
}
