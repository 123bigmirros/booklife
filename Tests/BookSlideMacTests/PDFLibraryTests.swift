import CoreText
import PDFKit
import XCTest
@testable import BookSlideMac
import BookSlideCore
import BookSlideTerminal

final class PDFLibraryTests: XCTestCase {
    @MainActor func testPDFSharesBookIdentityAcrossImportReadingAndTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
        let library = root.appendingPathComponent("Library", isDirectory:true)
        try FileManager.default.createDirectory(at:library, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("Original.PDF")
        try makePDF(at:source)

        let reader = ReaderModel(directory:library, loadExternalSources:false)
        defer { reader.close(); reader.webView.configuration.userContentController.removeScriptMessageHandler(forName:"reader") }
        reader.importBooks([source])
        try await wait { !reader.importingBooks && !reader.loading }
        let book = try XCTUnwrap(reader.currentBook, reader.importMessage ?? reader.error ?? "")
        XCTAssertEqual(book.format, .pdf)
        XCTAssertEqual(book.title, "Fixed Layout Fixture")
        XCTAssertNotNil(reader.cover(book))
        XCTAssertEqual(reader.position?.page, 1)
        XCTAssertEqual(reader.position?.pageCount, 3)

        let local = library.appendingPathComponent(book.filename)
        let terminal = try TextBook.open(local)
        XCTAssertEqual(terminal.progressKey, book.progressKey)
        XCTAssertEqual(try LibraryCatalog.books(in:library,recentDirectory:root).first { $0.url.lastPathComponent == book.filename }?.title, book.title)
        XCTAssertEqual(reader.sharedCatalog().first { $0.id == book.id }?.format, .pdf)

        reader.search("rare phrase")
        try await wait { !reader.searching }
        let match = try XCTUnwrap(reader.results.first)
        XCTAssertEqual(reader.results.count, 1)
        XCTAssertEqual(terminal.location(for:ContentAnchor(href:match.href, quote:"", fraction:0))?.chapter, 2)
        XCTAssertTrue(reader.go(match.href))
        XCTAssertEqual(reader.position?.page, 3)
        XCTAssertTrue(reader.toggleBookmark())
        let pdf = try XCTUnwrap(reader.pdfBookReader)
        let firstPage = PDFPageLocator.encode(0), secondPage = PDFPageLocator.encode(1)
        XCTAssertEqual(pdf.readingDiscussionExcerpts(through:secondPage,from:"",until:""),["First page","Second page"])
        XCTAssertEqual(pdf.readingDiscussionExcerpts(through:secondPage,from:firstPage,until:secondPage),["First page"])

        let note = try XCTUnwrap(reader.newGraphNote(chapterID:reader.currentNoteSectionID))
        XCTAssertEqual(note.sourceLocator, match.href)
        let excerpt = try await reader.graphSource(locator:note.readingLocator,href:"")
        XCTAssertTrue(excerpt.contains("rare phrase"))
        var first = note
        first.note = "First note"
        XCTAssertTrue(reader.saveAnnotation(first,bookID:book.id))
        var second = try XCTUnwrap(reader.newGraphNote(chapterID:reader.currentNoteSectionID))
        second.note = "Second note"
        XCTAssertTrue(reader.saveAnnotation(second,bookID:book.id))
        XCTAssertEqual(reader.currentBook?.annotations?.count, 2)

        let view = try XCTUnwrap(pdf.view as? PDFView)
        let selectedPage = try XCTUnwrap(view.document?.page(at:2))
        let selection = try XCTUnwrap(selectedPage.selection(for:NSRange(location:2,length:11)))
        view.setCurrentSelection(selection,animate:false)
        var passage = try XCTUnwrap(pdf.selectedAnnotation())
        passage.color = .yellow
        pdf.clearSelection()
        reader.performSelectionAction("annotationChange",selection:passage,bookID:book.id)
        XCTAssertEqual(reader.currentAnnotations.filter { $0.selectionLocator != nil }.count,1)
        XCTAssertTrue(selectedPage.annotations.contains { $0.type == "Highlight" })
        XCTAssertNotNil(reader.recordSelectedEntity(name:"Phrase",kind:.concept,source:passage,bookID:book.id))
        XCTAssertTrue(reader.go(passage.readingLocator))
        XCTAssertEqual(pdf.excerpt(at:passage.readingLocator),"rare phrase")
        reader.performSelectionAction("annotationDiscuss",selection:passage,bookID:book.id)
        XCTAssertEqual(reader.selectionDiscussion?.annotation.selectionLocator,passage.selectionLocator)
        reader.selectionDiscussion = nil
        reader.performSelectionAction("annotationTranslate",selection:passage,bookID:book.id)
        XCTAssertTrue(reader.selectionDiscussion?.translates == true)
        XCTAssertEqual(reader.selectionDiscussion?.annotation.quote,"rare phrase")
        reader.selectionDiscussion = nil

        reader.close()
        let renamed = root.appendingPathComponent("Renamed.pdf")
        try FileManager.default.copyItem(at:source,to:renamed)
        reader.importBooks([renamed])
        try await wait { !reader.importingBooks && !reader.loading }
        XCTAssertEqual(reader.currentID, book.id)
        XCTAssertEqual(reader.position?.page, 3)
        XCTAssertTrue(reader.isBookmarked)

        reader.close()
        let shared = ReadingProgress(bookKey:terminal.progressKey,deviceID:UUID(),deviceName:"iPad",
            updatedAt:Date().addingTimeInterval(1),anchor:terminal.anchor(chapter:1,offset:0),progress:0.5)
        try reader.progressStore.merge([shared])
        reader.open(book.id)
        try await wait { !reader.loading }
        XCTAssertEqual(reader.position?.page, 2)
        XCTAssertEqual(reader.currentBook?.bookmarks.first?.id, match.href)

        reader.close()
        let invalid = root.appendingPathComponent("Invalid.pdf")
        try Data("%PDF-1.7 fake".utf8).write(to:invalid)
        reader.importBooks([invalid])
        try await wait { !reader.importingBooks }
        XCTAssertNotNil(reader.importMessage)
        XCTAssertFalse(reader.books.contains { $0.title == "Invalid" })
    }

    func testScannedPDFGainsSearchableTextWithoutChangingOriginal() throws {
        var bounds = CGRect(x:0,y:0,width:420,height:250)
        let bitmap = try XCTUnwrap(CGContext(data:nil,width:840,height:500,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray:1,alpha:1))
        bitmap.fill(CGRect(x:0,y:0,width:840,height:500))
        let text = CTLineCreateWithAttributedString(NSAttributedString(string:"Library scan test",
            attributes:[.font:NSFont.systemFont(ofSize:56),.foregroundColor:NSColor.black]))
        bitmap.textPosition = CGPoint(x:80,y:300)
        CTLineDraw(text,bitmap)
        let raster = try XCTUnwrap(bitmap.makeImage())

        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data:bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&bounds,nil))
        context.beginPDFPage(nil)
        context.draw(raster,in:bounds)
        context.endPDFPage()
        context.closePDF()

        let original = bytes as Data
        let recognized = try PDFScanText.recognize(in:original)
        let scannedPage = try XCTUnwrap(PDFDocument(data:original)?.page(at:0))
        XCTAssertTrue((scannedPage.string ?? "").isEmpty)
        let searchablePage = try XCTUnwrap(PDFDocument(data:recognized)?.page(at:0))
        XCTAssertTrue(searchablePage.string?.localizedCaseInsensitiveContains("Library scan test") == true)
    }

    private func makePDF(at url: URL) throws {
        var bounds = CGRect(x:0,y:0,width:360,height:520)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox:&bounds,
            [kCGPDFContextTitle: "Fixed Layout Fixture"] as CFDictionary))
        for text in ["First page", "Second page", "A rare phrase on the third page"] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,
                attributes:[.font: NSFont.systemFont(ofSize:16)]))
            context.textPosition = CGPoint(x:30,y:460)
            CTLineDraw(line,context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(30))
        }
        throw ReaderError.message("PDF reader did not become ready")
    }
}
