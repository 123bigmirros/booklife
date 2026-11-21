import XCTest
import SwiftUI
import UIKit
@testable import BookSlidePhone

@MainActor final class NotesInputRegressionTests: XCTestCase {

    func testQuickNoteFromLiveReadingCreatesAnEditableDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance = ReaderAppearance()
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await auditWait { !reader.loading && !reader.busy && reader.position != nil }
        reader.readingControlsVisible = true; reader.beginQuickNote()
        let draft = try XCTUnwrap(reader.annotationDraft)
        let map = try await auditReadyMap(host.view)
        try await auditWait { try await auditMapHasFocusedInput(map) }
        let text = "即时输入后关闭，最后的文字也要保留。"
        _ = try await map.callAsyncJavaScript("const input=document.getElementById('input-box'); input.textContent=text; input.dispatchEvent(new Event('input',{bubbles:true}));return true",arguments:["text":text],in:nil,contentWorld:.page)
        XCTAssertTrue(reader.bookNotesIndex.notes.contains { $0.id == draft.id })
        let flush = try XCTUnwrap(reader.mindMapInputFlush)
        let saved = await flush.perform()
        XCTAssertTrue(saved)
        reader.showNoteGraph = false
        try await auditWait { !reader.inlineInkObscured }
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == draft.id }?.title,text)
        let disk = try LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first?.annotations?.first { $0.id == draft.id }
        XCTAssertEqual(disk?.title,text,"Closing the inline graph editor must preserve the latest characters on disk")
        XCTAssertTrue(reader.readingControlsVisible)
    }

    private func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
