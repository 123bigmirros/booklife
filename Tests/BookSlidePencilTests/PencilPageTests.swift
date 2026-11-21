import XCTest
import UIKit
import PencilKit
import SwiftUI
import Combine
@testable import BookSlidePhone

@MainActor
final class PencilPageTests: XCTestCase {
    private let size = CGSize(width:600,height:800)
    private func drawing() -> PKDrawing {
        let points = (0...48).map { index -> PKStrokePoint in
            let t = Double(index)/48 * 2 * Double.pi
            return PKStrokePoint(location:CGPoint(x:240+140*cos(t),y:210+65*sin(t)),timeOffset:Double(index)/60,
                size:CGSize(width:3,height:3),opacity:1,force:0.7,azimuth:0.4,altitude:0.8)
        }
        return PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.systemRed),path:PKStrokePath(controlPoints:points,creationDate:Date()))])
    }
    private func page() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size:size,format:format).image { context in
            UIColor(red:0.95,green:0.89,blue:0.78,alpha:1).setFill(); context.fill(CGRect(origin:.zero,size:size))
            let text = "直接在书页上写字、圈画\n\n阅读有一种很轻的力量。\n它不催促，不提醒。\n\n把想法留在这一页。"
            (text as NSString).draw(in:CGRect(x:50,y:80,width:500,height:650),withAttributes:[.font:UIFont.systemFont(ofSize:25),.foregroundColor:UIColor.darkText])
        }
    }
    func testPencilDrawingRoundTripPreservesEditableStrokesAndOriginalPage() throws {
        let original = drawing()
        let controller = PagePencilCanvasController(drawing:original,size:size,color:.black)
        XCTAssertEqual(controller.canvas.drawingPolicy,.pencilOnly)
        let files = try controller.files(page:page())
        let restored = try PKDrawing(data:files.drawing)
        XCTAssertEqual(restored.strokes.count,1)
        XCTAssertEqual(restored.strokes[0].path.count,original.strokes[0].path.count)
        XCTAssertEqual(restored.strokes[0].path[12].force,original.strokes[0].path[12].force,accuracy:0.001)
        XCTAssertEqual(restored.strokes[0].path[12].altitude,original.strokes[0].path[12].altitude,accuracy:0.001)
        XCTAssertNotNil(UIImage(data:files.ink))
        XCTAssertNotEqual(files.page,files.preview)
        let attachment = XCTAttachment(image:try XCTUnwrap(UIImage(data:files.preview)))
        attachment.name = "书页圈画与原页合成预览"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testProductionSaveRestoresInkForFurtherEditingAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let id = UUID()
        reader.books.append(LibraryBook(id:id,title:"Pencil 验证",author:"测试",filename:"")); reader.currentID = id
        let anchor = ReaderPageAnchor(locator:"epubcfi(/6/2!/4/2/1:0)",chapter:"原页",progress:0.2,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"fixture")
        let note = ReaderPageNote(assetID:UUID(),anchor:anchor)
        let controller = PagePencilCanvasController(drawing:drawing(),size:size,color:.black)
        XCTAssertTrue(reader.savePageNote(note,files:try controller.files(page:page()),bookID:id))
        let saved = try XCTUnwrap(reader.currentPageNotes.first)
        let draft = try XCTUnwrap(reader.pageHandwritingDraft(for:saved))
        XCTAssertEqual(draft.drawing.strokes.count,1)
        XCTAssertEqual(draft.bookID,id)
        XCTAssertNotNil(reader.pageNoteImage(saved))
        XCTAssertTrue(reader.removePageNote(saved.id))
        XCTAssertTrue(reader.currentPageNotes.isEmpty)
        XCTAssertNoThrow(try reader.pageNoteStore.load(saved.assetID))
        XCTAssertTrue(reader.restoreRemovedNote(try XCTUnwrap(reader.noteUndoID)))
        XCTAssertEqual(reader.pageHandwritingDraft(for:try XCTUnwrap(reader.currentPageNotes.first))?.drawing.strokes.count,1)
    }
    func testUnfinishedInkRecoversAfterRestartAndFinishingRemovesItsDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"手写草稿",author:"",filename:"")]
        reader.currentID = bookID; reader.save()
        let anchor = ReaderPageAnchor(locator:"epubcfi(/6/2!/4/2/1:0)",chapter:"未完成的一页",progress:0.2,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"fixture")
        let note = ReaderPageNote(assetID:UUID(),anchor:anchor)
        try reader.keepInkDraft(ReaderInkNoteDraft(bookID:bookID,note:note,page:try XCTUnwrap(page().pngData()),drawing:drawing().dataRepresentation()))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        reopened.loadNoteDrafts(bookID:bookID)
        let draft = try XCTUnwrap(reopened.inkHandwritingDraft(for:try XCTUnwrap(reopened.inkNoteDrafts.first)))
        XCTAssertTrue(draft.recovered)
        XCTAssertEqual(draft.note.id,note.id)
        XCTAssertEqual(draft.drawing.strokes.count,1)
        let controller = PagePencilCanvasController(drawing:draft.drawing,size:size,color:.black)
        XCTAssertTrue(reopened.savePageNote(draft.note,files:try controller.files(page:draft.page),bookID:bookID))
        XCTAssertEqual(reopened.noteDraftCount,0)
        XCTAssertTrue(try reopened.noteDraftStore.inkDrafts(bookID:bookID).isEmpty)
    }


    func testPencilDefaultsToReadingWithToolsClosed() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        XCTAssertEqual(reader.inlineInkTool,.reading)
        XCTAssertFalse(reader.inlineInkToolsVisible)
        let host = ReaderPencilHost(reader:reader)
        XCTAssertTrue((reader.webView as? ReaderTextWebView)?.pencilReadingEnabled == true)
        XCTAssertFalse(host.ink.ready)
        reader.selectInkTool(.pen)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        reader.selectInkTool(.reading)
        XCTAssertEqual(reader.inlineInkTool,.reading)
    }

    func testSectionNotesUseExactSubsectionAndKeepOriginalReadingProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let bookID = UUID(); reader.books = [LibraryBook(id:bookID,title:"章节关联",author:"",filename:"")]; reader.currentID = bookID
        reader.chapters = [ChapterItem(id:"parent",href:"chapter.xhtml",title:"第一章",depth:0),
                           ChapterItem(id:"a",href:"chapter.xhtml#a",title:"第一节",depth:1),
                           ChapterItem(id:"b",href:"chapter.xhtml#b",title:"第二节",depth:1)]
        reader.position = EnginePosition(chapterHref:"chapter.xhtml#b",mode:.paged,locator:"epubcfi(/6/2!/4/2)",chapter:"第二节",page:2,pageCount:4,progress:0.34,canGoNext:true,canGoPrevious:true)
        reader.beginQuickNote()
        let draft = try XCTUnwrap(reader.annotationDraft)
        XCTAssertEqual(draft.annotation.chapterHref,"chapter.xhtml#b")
        XCTAssertEqual(draft.annotation.progress,0.34)
        XCTAssertEqual(reader.bookNotesIndex.notes.first { $0.id == draft.id }?.chapterID,2)
        var note = draft.annotation; note.note = "补充第二节的理解"
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID; reopened.chapters = reader.chapters
        XCTAssertEqual(reopened.bookNotesIndex.notes.first { $0.id == draft.id }?.chapterID,2)
        let shared = BookStructure(entries:[.init(title:"章",href:"same",depth:0),.init(title:"小节",href:"same",depth:1)])
        XCTAssertEqual(shared.sectionID(href:"same",title:"小节"),1)
    }

    func testIPadNotesKeepTheLiveBookVisibleBesideAndAboveTheEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance.mode = .paged
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let controller = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { unmount(reader,window,previous) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        reader.beginQuickNote()
        let noteID = try XCTUnwrap(reader.annotationDraft?.id)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let map = try await auditReadyMap(controller.view)
        try await auditWait { try await auditMapHasFocusedInput(map) }
        // Check full-height layouts without the software keyboard. Its real
        // appearance and rotation are covered separately by the UI walkthrough.
        window.endEditing(true)
        try await Task.sleep(for:.milliseconds(600))
        for dimensions in [CGSize(width:1180,height:820),CGSize(width:820,height:1180),CGSize(width:1210,height:440)] {
            window.frame = CGRect(origin:.zero,size:dimensions)
            window.layoutIfNeeded()
            try await Task.sleep(for:.milliseconds(2800))
            XCTAssertNotNil(reader.webView.window,"The original EPUB remains mounted while editing notes")
            XCTAssertNil(controller.presentedViewController,"iPad notes must not cover the book with a modal")
            XCTAssertGreaterThan(reader.webView.bounds.width,300)
            XCTAssertGreaterThan(reader.webView.bounds.height,200)
            if dimensions.width > 900 { XCTAssertLessThan(reader.webView.bounds.width,dimensions.width-300) }
            else { XCTAssertLessThan(reader.webView.bounds.height,dimensions.height * 0.65) }
            XCTAssertEqual(reader.annotationDraft?.id,noteID,"Reflow must not change the note being edited")
            XCTAssertTrue(auditFindMap(controller.view) === map,"Rotation must preserve the same editable map")
            XCTAssertGreaterThan(map.bounds.width,250)
            XCTAssertGreaterThan(map.bounds.height,150)
            XCTAssertFalse(descendants(window).compactMap { $0 as? UISegmentedControl }.contains { control in
                (0..<control.numberOfSegments).contains { control.titleForSegment(at:$0) == "本节笔记" }
            })
            let visibleText = try await reader.webView.callAsyncJavaScript("""
                return Array.from(document.querySelectorAll('iframe')).some(frame => {
                    const doc = frame.contentDocument;
                    return Array.from(doc?.querySelectorAll('p,h1,h2') || []).some(node => {
                        const rect = node.getBoundingClientRect();
                        return node.textContent.trim() && rect.width > 0 && rect.right > 0 && rect.left < frame.clientWidth && rect.bottom > 0 && rect.top < frame.clientHeight;
                    });
                });
                """,arguments:[:],in:nil,contentWorld:.page)
            XCTAssertEqual(visibleText as? Bool,true,"Live EPUB text must remain within the visible reading viewport")
            let capture = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:capture); attachment.name = dimensions.width > 900 ? "iPad 原文与小节笔记并排" : "iPad 原文与小节笔记上下排列"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let bookID = try XCTUnwrap(reader.currentID)
        let reading = BookEntity(name:"阅读",kind:.concept), time = BookEntity(name:"自主时间",kind:.concept)
        XCTAssertNotNil(reader.saveKnowledgeEntity(reading)); XCTAssertNotNil(reader.saveKnowledgeEntity(time))
        var rich = ReaderAnnotation(cfi:"",quote:"留一点时间，给没有进度要求的阅读。读得慢一些，允许一句话停留。",chapter:reader.position?.chapter ?? "",progress:reader.position?.progress ?? 0,note:"读得慢一些，是把时间重新留给自己。阅读时的专注，让零散的想法有机会连起来。")
        rich.title = "把时间留给自己"; rich.chapterHref = reader.position?.chapterHref; rich.entityIDs = [reading.id,time.id]
        XCTAssertTrue(reader.saveGraphAnnotation(rich,bookID:bookID,relation:BookRelation(sourceID:reading.id,targetID:time.id,label:"带来",evidenceIDs:[rich.id])))
        reader.annotationDraft = ReaderAnnotationDraft(bookID:bookID,annotation:rich); reader.graphNoteID = rich.id
        window.frame = CGRect(x:0,y:0,width:1180,height:820); window.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(1800))
        let detailed = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let detailAttachment = XCTAttachment(image:detailed); detailAttachment.name = "iPad 摘录想法与关联信息"; detailAttachment.lifetime = .keepAlways; add(detailAttachment)
        window.rootViewController = UIHostingController(rootView:BookNotesWorkspace(reader:reader) {})
        window.layoutIfNeeded(); try await Task.sleep(for:.milliseconds(1200))
        let overview = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let overviewAttachment = XCTAttachment(image:overview); overviewAttachment.name = "整合结构图与笔记详情"; overviewAttachment.lifetime = .keepAlways; add(overviewAttachment)
    }

    func testTypingInLargeBookCoalescesAutosavesAndReusesTheGraphIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let bookID = UUID()
        let annotations = (0..<2000).map { id -> ReaderAnnotation in
            var note = ReaderAnnotation(cfi:"",quote:"原文 \(id)",chapter:"小节 \(id % 160)",progress:0.4,note:"想法 \(id)")
            note.chapterHref = "chapter.xhtml#s\(id % 160)"; return note
        }
        var book = LibraryBook(id:bookID,title:"大量笔记输入检查",author:"",filename:"")
        book.annotations = annotations; reader.books = [book]; reader.currentID = bookID
        reader.chapters = (0..<160).map { ChapterItem(id:"s\($0)",href:"chapter.xhtml#s\($0)",title:"小节 \($0)",depth:0) }
        reader.graphNoteID = annotations[0].id
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:1180,height:820)
        window.rootViewController = UIHostingController(rootView:BookGraphNoteInspector(reader:reader,original:annotations[0],palette:.init(dark:false),includeFuture:false,compact:true,nodeMode:true,select:{ _ in }))
        window.makeKeyAndVisible()
        defer { unmount(reader,window,previous) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        try await waitUntil { descendants(window).contains { $0 is UITextView } }
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextView }.first)
        XCTAssertFalse(descendants(window).compactMap { $0 as? UITextField }.contains { ($0.accessibilityLabel ?? "").contains("标题") })
        try await Task.sleep(for:.milliseconds(800))
        _ = reader.bookNotesIndex
        let builds = reader.notesIndexBuildCount
        let warmStart = Date()
        for _ in 0..<1000 { XCTAssertEqual(reader.bookNotesIndex.notes.count,2000) }
        print("NOTES_CACHE_1000_READS_MS=\(Date().timeIntervalSince(warmStart)*1000)")
        XCTAssertEqual(reader.notesIndexBuildCount,builds)
        var publications = 0
        let subscription = reader.$books.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        editor.becomeFirstResponder()
        let typingStart = Date()
        var longestInsertion: TimeInterval = 0
        for _ in 0..<120 {
            let start = Date(); editor.insertText("记")
            longestInsertion = max(longestInsertion,Date().timeIntervalSince(start))
            try await Task.sleep(for:.milliseconds(8))
        }
        print("NOTES_TYPING_MAX_INSERT_MS=\(longestInsertion*1000) TOTAL_MS=\(Date().timeIntervalSince(typingStart)*1000)")
        XCTAssertEqual(publications,0,"Continuous typing must not publish the graph or write every key to disk")
        XCTAssertEqual(reader.notesIndexBuildCount,builds,"The whole-book index must stay unchanged while typing")
        try await waitUntil { reader.currentAnnotations.first?.note.hasSuffix(String(repeating:"记",count:120)) == true }
        XCTAssertEqual(publications,1,"One typing burst produces one durable note update")
        XCTAssertEqual(try LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first?.annotations?.first?.note,editor.text)
        XCTAssertTrue(reader.textNoteDrafts.isEmpty,"Successful autosaves must be actual notes, not pending drafts")
        let after = reader.notesIndexBuildCount
        _ = reader.bookNotesIndex
        XCTAssertLessThanOrEqual(reader.notesIndexBuildCount,after+1)
        reader.chapters[0].title = "重新命名的小节"
        XCTAssertEqual(reader.bookNotesIndex.structure.nodes[0].entry.title,"重新命名的小节")
        XCTAssertGreaterThan(reader.notesIndexBuildCount,after)
        editor.insertText("立刻收起")
        try await Task.sleep(for:.milliseconds(20))
        window.rootViewController = UIViewController()
        try await Task.sleep(for:.milliseconds(100))
        let kept = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first?.annotations?.first)
        XCTAssertTrue(kept.note.hasSuffix("立刻收起"),"Closing before the debounce must flush the latest characters into the saved note")
        window.rootViewController = UIHostingController(rootView:BookGraphNoteInspector(reader:reader,original:annotations[0],palette:.init(dark:false),includeFuture:false,select:{ _ in }))
        try await waitUntil { descendants(window).compactMap { $0 as? UITextView }.contains { $0.text.hasSuffix("立刻收起") } }
    }

    private func mountedReader() async throws -> (ReaderModel, ReaderPencilHost, UIWindow, UIWindow?) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance.mode = .paged
        reader.selectInkTool(.pen) // Ink fixtures explicitly opt into writing.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(), host = ReaderPencilHost(reader:reader)
        container.view.addSubview(host)
        host.frame = CGRect(x:0,y:0,width:600,height:800)
        window.rootViewController = container; window.makeKeyAndVisible()
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && host.ink.ready }
        return (reader,host,window,previous)
    }
    private func unmount(_ reader: ReaderModel,_ window: UIWindow,_ previous: UIWindow?) {
        reader.close()
        reader.webView.stopLoading()
        // Each fixture owns a one-shot reader. WKUserContentController retains
        // its handler, so detach it here rather than accumulating WebKit
        // processes across every native-selection test in this class.
        reader.webView.configuration.userContentController.removeScriptMessageHandler(forName:"reader")
        window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        try? FileManager.default.removeItem(at:reader.directory)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<180 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("Timed out waiting for the live reader ink layer")
        throw ReaderError.message("Live ink timeout")
    }
    private func write(_ drawing: PKDrawing,on ink: ReaderInlineInkController) {
        ink.canvasViewDidBeginUsingTool(ink.canvas)
        ink.canvas.drawing = drawing
        ink.canvasViewDrawingDidChange(ink.canvas)
        ink.canvasViewDidEndUsingTool(ink.canvas)
    }
    func testCloseWhileWritingExplainsTheBlockAndWorksAfterPenLifts() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let id = reader.currentID, session = reader.sessionID
        host.ink.canvasViewDidBeginUsingTool(host.ink.canvas)
        host.ink.canvas.drawing = drawing()
        reader.close()
        XCTAssertEqual(reader.currentID,id)
        XCTAssertEqual(reader.sessionID,session)
        XCTAssertEqual(reader.error,"请先抬起笔，再返回书库。")
        XCTAssertFalse(host.ink.canvas.drawing.strokes.isEmpty)
        reader.error = nil
        host.ink.canvasViewDidEndUsingTool(host.ink.canvas)
        reader.close()
        XCTAssertNil(reader.currentID)
        XCTAssertNil(reader.error)
        let saved = try XCTUnwrap(LibraryIndexStore(directory:reader.directory).load([LibraryBook].self))
        XCTAssertEqual(saved.value.first(where:{ $0.id == id })?.pageNotes?.count,1,
                       "Closing must commit the final stroke before leaving the book")
    }
    func testBlockedAppearanceChangeRestoresTheActualReadingMode() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let before = reader.appearance
        host.ink.canvasViewDidBeginUsingTool(host.ink.canvas)
        host.ink.canvas.drawing = drawing()
        reader.appearance.mode = before.mode == .scroll ? .paged : .scroll
        reader.updateAppearance()
        XCTAssertEqual(reader.appearance,before,"The toolbar must not claim a mode which WebKit never received")
        XCTAssertNotNil(reader.readingNotice)
        XCTAssertTrue(host.ink.isDrawing)
        XCTAssertFalse(host.ink.canvas.drawing.strokes.isEmpty)
        host.ink.canvasViewDidEndUsingTool(host.ink.canvas)
    }
    func testOldProgressCompletionCannotReleaseTheNextSessionsBusyState() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let bookID = try XCTUnwrap(reader.currentID)
        let key = try XCTUnwrap(reader.currentBook?.progressKey)
        let record = ReadingProgress(bookKey:key,deviceID:UUID(),deviceName:"测试设备",anchor:.init(href:"chapter1.xhtml",quote:"",fraction:0.2),progress:0.2)
        _ = try await reader.webView.evaluateJavaScript("window.restoreStarted=false; reader.restore=async ()=>{window.restoreStarted=true; await new Promise(r=>setTimeout(r,400)); return null;}; true")
        reader.pendingProgress = record
        let pending = Task { @MainActor in await reader.resumeSharedProgress() }
        for _ in 0..<20 {
            if try await reader.webView.evaluateJavaScript("window.restoreStarted") as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(reader.busy)
        reader.close()
        reader.currentID = bookID
        reader.busy = true; reader.restoringProgress = true
        await pending.value
        XCTAssertTrue(reader.busy,"Completion of an old request must not unlock the next reading session")
        XCTAssertTrue(reader.restoringProgress)
        reader.busy = false; reader.restoringProgress = false
    }
    func testFailedSharedProgressKeepsThePendingRecordAndReportsFailure() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let position = try XCTUnwrap(reader.position)
        let record = ReadingProgress(bookKey:try XCTUnwrap(reader.currentBook?.progressKey),deviceID:UUID(),deviceName:"测试设备",anchor:try XCTUnwrap(position.anchor),cfi:position.locator,progress:position.progress)
        _ = try await reader.webView.evaluateJavaScript("window.originalRestore=reader.restore; reader.restore=async ()=>null; true")
        reader.pendingProgress = record
        let resumed = await reader.resumeSharedProgress()
        XCTAssertFalse(resumed)
        XCTAssertEqual(reader.pendingProgress?.id,record.id)
        XCTAssertNotEqual(reader.appliedProgressID,record.id)
        XCTAssertFalse(reader.busy)
        XCTAssertFalse(reader.restoringProgress)
        XCTAssertTrue(reader.progressStatus.contains("未能定位"))
        _ = try await reader.webView.evaluateJavaScript("reader.restore=window.originalRestore; true")
        let retried = await reader.resumeSharedProgress()
        XCTAssertTrue(retried)
        XCTAssertNil(reader.pendingProgress)
        XCTAssertEqual(reader.appliedProgressID,record.id)
        XCTAssertEqual(reader.progressStatus,"已继续同步位置")
    }
    func testFailedInkSaveExplainsBlockedNoteNavigationAndAllowsRetry() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        write(drawing(),on:host.ink)
        try await waitUntil { reader.currentPageNotes.count == 1 && reader.inkNoteDrafts.isEmpty }
        host.ink.canvas.drawing = drawing().transformed(using:CGAffineTransform(translationX:0,y:10))
        let unsaved = host.ink.canvas.drawing.dataRepresentation()
        let assets = reader.pageNoteStore.directory, backup = assets.appendingPathExtension("test-backup")
        try FileManager.default.moveItem(at:assets,to:backup)
        try Data([0]).write(to:assets)
        reader.beginQuickNote()
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertNil(reader.annotationDraft)
        XCTAssertNotNil(reader.readingNotice)
        XCTAssertTrue(host.ink.ready)
        XCTAssertEqual(host.ink.canvas.drawing.dataRepresentation(),unsaved)
        try FileManager.default.removeItem(at:assets)
        try FileManager.default.moveItem(at:backup,to:assets)
        reader.beginQuickNote()
        XCTAssertTrue(reader.showNoteGraph)
        XCTAssertNotNil(reader.annotationDraft)
    }
    func testLivePencilSharesTheEPUBViewportAndSavesWithoutAPresentation() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        XCTAssertTrue(host.ink.canvas.drawingGestureRecognizer.view === host)
        XCTAssertTrue(host.ink.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(reader.webView.scrollView.panGestureRecognizer.allowedTouchTypes.contains(NSNumber(value:UITouch.TouchType.pencil.rawValue)))
        XCTAssertTrue(reader.webView.superview === host)
        XCTAssertTrue(host.ink.canvas.superview === host)
        XCTAssertEqual(host.ink.canvas.frame,reader.webView.frame)
        XCTAssertEqual(host.ink.canvas.drawingPolicy,.pencilOnly)
        XCTAssertFalse(reader.handwritingActive)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertTrue(reader.currentPageNotes.isEmpty)
        // Pencil is enabled before opening the tools and remains enabled after
        // they close. Writing does not force a second toolbar onto the page.
        XCTAssertFalse(reader.inlineInkToolsVisible)
        write(drawing(),on:host.ink)
        XCTAssertFalse(reader.inlineInkToolsVisible)
        try await waitUntil { reader.currentPageNotes.count == 1 && reader.inkNoteDrafts.isEmpty }
        // Finger/accessibility hit testing goes to the existing reader hierarchy.
        let target = try XCTUnwrap(host.hitTest(CGPoint(x:300,y:300),with:nil))
        XCTAssertTrue(target === reader.webView || target.isDescendant(of:reader.webView))
        XCTAssertFalse(reader.inlineInkToolsVisible)
        reader.beginPageHandwriting()
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertTrue(reader.inlineInkToolsVisible)
        XCTAssertFalse(host.ink.canvas.isFirstResponder)
        XCTAssertFalse(reader.handwritingActive)
        write(drawing(),on:host.ink)
        try await waitUntil { reader.currentPageNotes.count == 1 && reader.inkNoteDrafts.isEmpty }
        XCTAssertEqual(reader.currentPageNotes.count,1)
        XCTAssertTrue(reader.inkNoteDrafts.isEmpty)
        XCTAssertFalse(reader.handwritingActive)
        XCTAssertTrue(reader.inlineInkToolsVisible)
        let saved = try XCTUnwrap(reader.currentPageNotes.first)
        XCTAssertEqual(reader.pageHandwritingDraft(for:saved)?.drawing.strokes.count,1)
        XCTAssertTrue(host.ink.ready)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        let image = UIGraphicsImageRenderer(bounds:host.bounds).image { _ in
            host.drawHierarchy(in:host.bounds,afterScreenUpdates:true)
        }
        let attachment = XCTAttachment(image:image); attachment.name = "正文与 Pencil 共用书页"; attachment.lifetime = .keepAlways; add(attachment)
        let preview = XCTAttachment(image:try XCTUnwrap(reader.pageNoteImage(saved)))
        preview.name = "同一坐标中的正文和笔迹"; preview.lifetime = .keepAlways; add(preview)
        // UIView captures omit PencilKit's Metal layer. Leave a short window
        // for the simulator harness to capture the composed system screen.
        print("BOOKSLIDE_LIVE_INK_SCREENSHOT_READY")
        try await Task.sleep(for:.seconds(3))
        reader.beginPageHandwriting()
        XCTAssertFalse(reader.inlineInkToolsVisible)
        XCTAssertTrue(host.ink.ready)
    }
    func testTurnSavesInkAndReturnContinuesTheSameEditableNote() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let original = try XCTUnwrap(reader.position?.locator)
        // Leave a changed canvas uncommitted to exercise the navigation flush.
        host.ink.canvas.drawing = drawing()
        let result = await reader.turn(.next)
        XCTAssertNil(result)
        XCTAssertNotEqual(reader.position?.locator,original)
        let note = try XCTUnwrap(reader.currentPageNotes.first)
        XCTAssertEqual(reader.pageHandwritingDraft(for:note)?.drawing.strokes.count,1)
        try await waitUntil { host.ink.ready }
        reader.go(original)
        try await waitUntil { !reader.busy && host.ink.ready && host.ink.draft?.id == note.id }
        XCTAssertEqual(host.ink.canvas.drawing.strokes.count,1)
        write(PKDrawing(strokes:drawing().strokes + drawing().strokes),on:host.ink)
        try await waitUntil { reader.inkNoteDrafts.isEmpty }
        XCTAssertEqual(reader.currentPageNotes.count,1)
        XCTAssertEqual(reader.pageHandwritingDraft(for:try XCTUnwrap(reader.currentPageNotes.first))?.drawing.strokes.count,2)
        // The live page is not a raster background and remains selectable.
        let allowed = try await reader.webView.callAsyncJavaScript("return reader.allowsReadingGesture(300,300)",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(allowed as? Bool,true)
    }
    func testFailedInlineSaveRetainsInkAndPreventsNavigation() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let original = reader.position?.locator
        try Data([0]).write(to:reader.pageNoteStore.directory)
        write(drawing(),on:host.ink)
        XCTAssertFalse(host.ink.persist())
        XCTAssertTrue(host.ink.ready)
        XCTAssertEqual(host.ink.canvas.drawing.strokes.count,1)
        XCTAssertEqual(reader.inkNoteDrafts.count,1)
        XCTAssertNotNil(reader.inlineInkStatus)
        let result = await reader.turn(.next)
        XCTAssertNotNil(result)
        XCTAssertEqual(reader.position?.locator,original)
        XCTAssertTrue(host.ink.ready)
        try FileManager.default.removeItem(at:reader.pageNoteStore.directory)
        XCTAssertTrue(host.ink.persist())
        XCTAssertTrue(reader.inkNoteDrafts.isEmpty)
        XCTAssertEqual(reader.currentPageNotes.count,1)
    }
    func testResizeAndTypographyNeverPutOldInkOnDifferentWords() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        write(drawing(),on:host.ink)
        try await waitUntil { reader.currentPageNotes.count == 1 }
        let note = try XCTUnwrap(reader.currentPageNotes.first)
        reader.appearance.fontSize += 4; reader.updateAppearance()
        try await waitUntil { host.ink.ready && host.ink.draft?.note.anchor.layoutKey != note.anchor.layoutKey }
        XCTAssertTrue(host.ink.canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(reader.pageHandwritingDraft(for:note)?.drawing.strokes.count,1)
        host.frame.size = CGSize(width:800,height:600); host.setNeedsLayout(); host.layoutIfNeeded()
        try await waitUntil { host.ink.ready && host.ink.draft?.note.anchor.viewportWidth == 800 }
        XCTAssertEqual(host.ink.canvas.frame,reader.webView.frame)
        XCTAssertTrue(host.ink.canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(reader.currentPageNotes.count,1)
    }
    func testScrollContinuesInkWithoutCroppingNewStrokesAndRecoversDrafts() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.appearance.mode = .scroll; reader.updateAppearance()
        try await waitUntil { host.ink.ready && host.ink.draft?.note.anchor.layoutKey.contains("scroll") == true }
        write(drawing(),on:host.ink)
        try await waitUntil { reader.currentPageNotes.count == 1 && reader.inkNoteDrafts.isEmpty }
        let note = try XCTUnwrap(reader.currentPageNotes.first)
        let result = await reader.turn(.next,scrollLines:4)
        XCTAssertNil(result)
        try await waitUntil { host.ink.ready && host.ink.draft?.id == note.id }
        let expanded = try XCTUnwrap(host.ink.draft)
        XCTAssertGreaterThan(expanded.note.anchor.viewportHeight,note.anchor.viewportHeight)
        // A new stroke near the bottom of the newly visible text used to fall
        // outside the saved page rectangle when editing a partially visible note.
        let bottom = PKDrawing(strokes:drawing().strokes).transformed(using:CGAffineTransform(translationX:0,y:500))
        write(PKDrawing(strokes:host.ink.canvas.drawing.strokes + bottom.strokes),on:host.ink)
        try await waitUntil { reader.inkNoteDrafts.isEmpty }
        let saved = try XCTUnwrap(reader.currentPageNotes.first(where:{ $0.id==note.id }))
        XCTAssertEqual(saved.id,note.id)
        XCTAssertEqual(reader.currentPageNotes.count,2,"Separate passages on an expanded canvas become separate graph nodes")
        XCTAssertEqual(reader.pageHandwritingDraft(for:saved)?.drawing.strokes.count,2)
        XCTAssertGreaterThan(saved.anchor.viewportHeight,note.anchor.viewportHeight)
        let files = try reader.pageNoteStore.load(saved.assetID)
        let png = try XCTUnwrap(UIImage(data:files.ink))
        XCTAssertGreaterThan(png.size.height,png.size.width)
        // A local recovery draft takes priority over the last exported ink.
        XCTAssertTrue(host.ink.suspend())
        let recovered = PKDrawing(strokes:drawing().strokes + drawing().strokes + drawing().strokes)
        try reader.keepInkDraft(ReaderInkNoteDraft(bookID:try XCTUnwrap(reader.currentID),note:saved,
            page:files.page,drawing:recovered.dataRepresentation()))
        try await waitUntil { host.ink.ready && host.ink.draft?.recovered == true }
        XCTAssertEqual(host.ink.canvas.drawing.strokes.count,3)
        XCTAssertTrue(host.ink.persist())
        XCTAssertTrue(reader.inkNoteDrafts.isEmpty)
        XCTAssertEqual(reader.currentPageNotes.count,1,"The recovered drawing replaced the bottom passage's strokes")
    }
    func testTextSelectionKeepsWebKitFocusAndTemporarilyHidesTheInkTools() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.beginPageHandwriting()
        let selected = try await reader.webView.callAsyncJavaScript("""
            const doc = document.querySelector('iframe').contentDocument;
            const range = doc.createRange(); range.selectNodeContents(doc.querySelector('p'));
            const selection = doc.defaultView.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return selection.toString();
            """,arguments:[:],in:nil,contentWorld:.page)
        XCTAssertFalse((selected as? String ?? "").isEmpty)
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertFalse(host.ink.ready)
        XCTAssertTrue(reader.inlineInkSelectionActive)
        XCTAssertFalse(host.ink.canvas.isFirstResponder)
        let htmlMenuHidden = try await reader.webView.callAsyncJavaScript("return document.getElementById('annotation-menu').hidden",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(htmlMenuHidden as? Bool,true)
        _ = try await reader.webView.callAsyncJavaScript("document.querySelector('iframe').contentWindow.getSelection().removeAllRanges(); reader.dismissAnnotations();",arguments:[:],in:nil,contentWorld:.page)
        try await waitUntil { host.ink.ready }
        XCTAssertTrue(reader.inlineInkToolsVisible)
        XCTAssertFalse(host.ink.canvas.isFirstResponder)
    }
    func testPencilReadingModeSavesInkRoutesNavigationAndRestoresTheEditablePage() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        write(drawing(),on:host.ink)
        reader.selectInkTool(.reading)
        XCTAssertEqual(reader.inlineInkTool,.reading)
        XCTAssertFalse(host.ink.ready)
        XCTAssertFalse(host.ink.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(reader.webView.scrollView.panGestureRecognizer.allowedTouchTypes.contains(NSNumber(value:UITouch.TouchType.pencil.rawValue)))
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertFalse(host.ink.ready,"Polling must not re-enable drawing in reading mode")
        XCTAssertEqual(reader.currentPageNotes.count,1)
        XCTAssertTrue(reader.inkNoteDrafts.isEmpty)
        reader.selectInkTool(.eraser)
        try await waitUntil { host.ink.ready }
        XCTAssertTrue(host.ink.canvas.tool is PKEraserTool)
        XCTAssertEqual(host.ink.canvas.drawing.strokes.count,1)
        XCTAssertFalse(reader.webView.scrollView.panGestureRecognizer.allowedTouchTypes.contains(NSNumber(value:UITouch.TouchType.pencil.rawValue)))
        reader.selectInkTool(.pen)
        XCTAssertTrue(host.ink.canvas.tool is PKInkingTool)
        XCTAssertEqual(host.ink.canvas.drawing.strokes.count,1)
    }
    func testReadingModeCannotDiscardInkWhenItsSaveFails() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        try Data([0]).write(to:reader.pageNoteStore.directory)
        write(drawing(),on:host.ink)
        reader.selectInkTool(.reading)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        XCTAssertTrue(host.ink.ready)
        XCTAssertEqual(host.ink.canvas.drawing.strokes.count,1)
        XCTAssertFalse(reader.webView.scrollView.panGestureRecognizer.allowedTouchTypes.contains(NSNumber(value:UITouch.TouchType.pencil.rawValue)))
        try FileManager.default.removeItem(at:reader.pageNoteStore.directory)
        reader.selectInkTool(.reading)
        XCTAssertEqual(reader.inlineInkTool,.reading)
        XCTAssertEqual(reader.currentPageNotes.count,1)
    }
    func testFingerDragDefersSelectionMetadataUntilTheMenuRequestsIt() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let result = try await reader.webView.callAsyncJavaScript("""
            const frame=document.querySelector('iframe'), doc=frame.contentDocument;
            const text=[...doc.querySelectorAll('p')].find(p=>p.firstChild?.nodeType===3 && p.firstChild.length>20).firstChild;
            const capture=BookSlideProgress.capture;
            let metadataCalls=0, backgroundMetadata=0;
            BookSlideProgress.capture=(...args)=>{
              metadataCalls++;
              const stack=new Error().stack || '';
              if (stack.includes('reader-annotations.js') && !stack.includes('annotationContext')) backgroundMetadata++;
              return capture(...args);
            };
            try {
              for (const end of [4,8,12,16]) {
                frame.contentWindow.getSelection().setBaseAndExtent(text,0,text,end);
                await new Promise(resolve=>setTimeout(resolve,200));
              }
              const duringDrag=backgroundMetadata, beforeMenu=metadataCalls;
              const context=reader.annotationContext();
              return {duringDrag,afterMenu:metadataCalls-beforeMenu,quote:context.quote,expected:text.textContent.slice(0,16)};
            } finally { BookSlideProgress.capture=capture; reader.dismissAnnotations(); }
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(result?["duringDrag"] as? Int,0,"Dragging native selection handles must not repeatedly generate CFI/progress metadata")
        XCTAssertLessThanOrEqual(result?["afterMenu"] as? Int ?? 100,1,"An on-demand menu query resolves the final range at most once")
        XCTAssertEqual(result?["quote"] as? String,result?["expected"] as? String)
    }
    func testSavingOneHighlightKeepsExistingHighlightLayers() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let result = try await reader.webView.callAsyncJavaScript("""
            const frame=document.querySelector('iframe'), doc=frame.contentDocument;
            const text=[...doc.querySelectorAll('p')].find(p=>p.firstChild?.nodeType===3 && p.firstChild.length>24).firstChild;
            const contexts=[];
            for (const [start,end] of [[0,6],[8,14]]) {
              frame.contentWindow.getSelection().setBaseAndExtent(text,start,text,end);
              contexts.push(reader.annotationContext());
            }
            reader.dismissAnnotations();
            const first={...contexts[0],color:'yellow'}, second={...contexts[1],color:'blue'};
            reader.setAnnotations([first],first.session);
            const original=document.querySelector('.bookslide-highlight');
            reader.setAnnotations([first,second],first.session);
            const kept=[...document.querySelectorAll('.bookslide-highlight')].includes(original);
            const count=document.querySelectorAll('.bookslide-highlight').length;
            reader.setAnnotations([{...first,note:'只修改笔记文字'},second],first.session);
            const keptAfterNote=[...document.querySelectorAll('.bookslide-highlight')].includes(original);
            reader.setAnnotations([{...first,color:'green'},second],first.session);
            const colorChanged=!original.isConnected;
            return {kept,count,keptAfterNote,colorChanged};
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(result?["kept"] as? Bool,true,"Adding one highlight must not tear down existing SVG layers")
        XCTAssertEqual(result?["count"] as? Int,2)
        XCTAssertEqual(result?["keptAfterNote"] as? Bool,true,"Changing note text must not repaint an unchanged highlight")
        XCTAssertEqual(result?["colorChanged"] as? Bool,true,"An actual color change still updates its mark")
    }
    func testClosingAnOldAnnotationMenuDoesNotClearTheNextSelection() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.selectInkTool(.reading)
        let web = try XCTUnwrap(reader.webView as? ReaderTextWebView)
        let old = try await web.callAsyncJavaScript("""
            const frame=document.querySelector('iframe'), doc=frame.contentDocument;
            const text=[...doc.querySelectorAll('p')].find(p=>p.firstChild?.nodeType===3 && p.firstChild.length>24).firstChild;
            frame.contentWindow.getSelection().setBaseAndExtent(text,0,text,6);
            return reader.annotationContext();
            """,arguments:[:],in:nil,contentWorld:.page)
        let context = try XCTUnwrap(old as? [String:Any])
        web.presentAnnotationMenu(context:context,x:120,y:180)
        try await Task.sleep(for:.milliseconds(100))
        let next = try await web.callAsyncJavaScript("""
            const frame=document.querySelector('iframe'), doc=frame.contentDocument;
            const text=[...doc.querySelectorAll('p')].find(p=>p.firstChild?.nodeType===3 && p.firstChild.length>24).firstChild;
            frame.contentWindow.getSelection().setBaseAndExtent(text,12,text,22);
            return text.textContent.slice(12,22);
            """,arguments:[:],in:nil,contentWorld:.page)
        web.dismissAnnotationMenu()
        try await Task.sleep(for:.milliseconds(250))
        let selected = try await web.callAsyncJavaScript("return [...document.querySelectorAll('iframe')].map(f=>f.contentWindow.getSelection().toString()).join('')",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(selected as? String,next as? String,"A delayed dismissal belongs to the old range, not the new drag")
        XCTAssertNotNil(reader.currentID)
    }
    func testPencilDragAdjustsTheExistingSelectionWithoutClearingIt() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.selectInkTool(.reading)
        let result = try await reader.webView.callAsyncJavaScript("""
            const frame=document.querySelector('iframe'), doc=frame.contentDocument;
            const text=[...doc.querySelectorAll('p')].find(p=>p.firstChild?.nodeType===3 && p.firstChild.length>16).firstChild;
            function point(offset) {
              const range=doc.createRange(); range.setStart(text,offset); range.setEnd(text,offset+1);
              const rect=range.getClientRects()[0], box=frame.getBoundingClientRect();
              return {x:box.left+rect.left+rect.width/2,y:box.top+rect.top+rect.height/2};
            }
            const selection=frame.contentWindow.getSelection(), remove=selection.removeAllRanges, set=selection.setBaseAndExtent;
            let clears=0, updates=0;
            selection.removeAllRanges=function(...args) { clears++; return remove.apply(this,args); };
            selection.setBaseAndExtent=function(...args) { updates++; return set.apply(this,args); };
            const start=point(1), end=point(8);
            try {
              reader.pencilSelect(start.x,start.y,'begin');
              const clearsAtStart=clears;
              for (let i=0;i<80;i++) reader.pencilSelect(start.x,start.y,'extend');
              reader.pencilSelect(end.x,end.y,'extend');
              return {clearsAtStart,clears,updates,quote:selection.toString(),expected:text.textContent.slice(1,9)};
            } finally {
              selection.removeAllRanges=remove; selection.setBaseAndExtent=set;
              reader.pencilSelect(end.x,end.y,'cancel');
            }
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(result?["clears"] as? Int,result?["clearsAtStart"] as? Int,"Extending a range must not deselect and reselect the text")
        XCTAssertEqual(result?["updates"] as? Int,2,"Repeated samples over the same glyph must not reset native selection handles")
        XCTAssertEqual(result?["quote"] as? String,result?["expected"] as? String)
    }
    func testPencilDragKeepsLatestPositionInsteadOfReplayingMoveBacklog() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.selectInkTool(.reading)
        let input = ReaderTouchInput(reader:reader)
        input.attach(to:reader.webView)
        defer { input.detach() }
        _ = try await reader.webView.callAsyncJavaScript("""
            window.pencilCalls = [];
            reader.pencilSelect = async (x,y,phase) => {
              window.pencilCalls.push({x,y,phase});
              await new Promise(resolve => setTimeout(resolve,35));
              return true;
            };
            """,arguments:[:],in:nil,contentWorld:.page)
        input.enqueuePencilSelection(at:CGPoint(x:0,y:0),phase:"begin")
        try await Task.sleep(for:.milliseconds(15))
        for index in 1...100 { input.enqueuePencilSelection(at:CGPoint(x:index,y:20),phase:"extend") }
        input.enqueuePencilSelection(at:CGPoint(x:120,y:30),phase:"end")
        try await Task.sleep(for:.milliseconds(300))
        let result = try await reader.webView.callAsyncJavaScript("return window.pencilCalls",arguments:[:],in:nil,contentWorld:.page) as? [[String:Any]]
        XCTAssertEqual(result?.map { $0["phase"] as? String },["begin","extend","end"])
        XCTAssertEqual(result?[1]["x"] as? Int,100)
        XCTAssertEqual(result?.last?["x"] as? Int,120)
    }
    func testPencilSelectionTracksCharactersShrinksAcrossLinesAndIncludesLiftPoint() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.selectInkTool(.reading)
        let value = try await reader.webView.callAsyncJavaScript("""
            const frame = document.querySelector('iframe'), doc = frame.contentDocument;
            const p = doc.querySelector('p');
            p.innerHTML = '<span>ABCDEFGHIJ</span><span>中文字符用于测试跨行选取是否准确跟随笔尖移动并且能够回拖缩小范围不多选也不少选。</span><span>👩‍💻éZ</span>';
            Object.assign(p.style,{fontFamily:'monospace',fontSize:'20px',lineHeight:'32px',width:'260px',letterSpacing:'0',whiteSpace:'normal',textTransform:'none'});
            const nodes = Array.from(p.children).map(span=>span.firstChild);
            function point(node,start,end=start+1) {
              const range = doc.createRange(); range.setStart(node,start); range.setEnd(node,end);
              const rect = range.getClientRects()[0], box = frame.getBoundingClientRect();
              return {x:box.left+rect.left+rect.width*0.45,y:box.top+rect.top+rect.height*0.5};
            }
            function at(point,phase) { if (!reader.pencilSelect(point.x,point.y,phase)) throw Error('Selection failed at '+phase); }
            function quote() { return reader.annotationContext().quote; }
            const e = point(nodes[0],4), f = point(nodes[0],5), h = point(nodes[0],7), c = point(nodes[0],2), chinese = point(nodes[1],30);
            const result = {};
            at(e,'begin'); result.start = quote();
            at(h,'extend'); result.forward = quote();
            at(f,'extend'); result.shrunk = quote();
            at(c,'extend'); result.reverse = quote();
            at(chinese,'extend'); result.multiline = quote();
            const expected = doc.createRange(); expected.setStart(nodes[0],4); expected.setEnd(nodes[1],31);
            result.multilineExpected = expected.toString();
            at(f,'extend'); result.returned = quote();
            reader.pencilSelect(f.x,f.y,'cancel');
            const emoji = point(nodes[2],0,5), accent = point(nodes[2],5,7);
            at(emoji,'begin'); result.emoji = quote();
            reader.pencilSelect(emoji.x,emoji.y,'cancel');
            at(accent,'begin'); result.accent = quote();
            reader.pencilSelect(accent.x,accent.y,'cancel');
            at(e,'begin'); at(f,'extend');
            at(h,'end'); result.lift = quote();
            return result;
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(value?["start"] as? String,"E")
        XCTAssertEqual(value?["forward"] as? String,"EFGH")
        XCTAssertEqual(value?["shrunk"] as? String,"EF")
        XCTAssertEqual(value?["reverse"] as? String,"CDE")
        XCTAssertEqual(value?["multiline"] as? String,value?["multilineExpected"] as? String)
        XCTAssertEqual(value?["returned"] as? String,"EF")
        XCTAssertEqual(value?["emoji"] as? String,"👩‍💻")
        XCTAssertEqual(value?["accent"] as? String,"é")
        XCTAssertEqual(value?["lift"] as? String,"EFGH")
        try await waitUntil { reader.currentAnnotations.count == 1 && reader.inlineInkMenuActive }
        XCTAssertEqual(reader.currentAnnotations.first?.quote,"EFGH")
    }
    func testPencilSelectionAutomaticallyHighlightsAndOffersOptionsAfterLift() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.selectInkTool(.reading)
        let web = try XCTUnwrap(reader.webView as? ReaderTextWebView)
        let value = try await web.callAsyncJavaScript("""
            const frame = document.querySelector('iframe'), doc = frame.contentDocument;
            const walker = doc.createTreeWalker(doc.querySelector('p'), NodeFilter.SHOW_TEXT);
            let text; while ((text = walker.nextNode()) && text.textContent.trim().length < 12) {}
            if (!text) throw Error('No selectable paragraph');
            const box = frame.getBoundingClientRect();
            function point(offset) {
              const range = doc.createRange(); range.setStart(text,offset); range.setEnd(text,offset+1);
              const rect = range.getClientRects()[0];
              return {x:box.left+rect.left+rect.width/2,y:box.top+rect.top+rect.height/2};
            }
            const start = point(1), end = point(11);
            if (!reader.pencilSelect(start.x,start.y,'begin')) throw Error('Pencil selection failed');
            const initial = reader.annotationContext();
            if (!reader.pencilSelect(end.x,end.y,'extend')) throw Error('Pencil range extension failed');
            const extended = reader.annotationContext();
            if (extended.quote.length <= initial.quote.length) throw Error('Range did not extend');
            if (!reader.pencilSelect(end.x,end.y,'end')) throw Error('Pencil automatic highlight failed');
            if (reader.pencilSelect(end.x,end.y,'end')) throw Error('Repeated lift must not submit again');
            return {...extended,start,end};
            """,arguments:[:],in:nil,contentWorld:.page)
        let context = try XCTUnwrap(value as? [String:Any])
        XCTAssertTrue((context["cfi"] as? String)?.hasPrefix("epubcfi(") == true)
        try await waitUntil { reader.currentAnnotations.count == 1 && reader.inlineInkMenuActive }
        let saved = try XCTUnwrap(reader.currentAnnotations.first)
        XCTAssertEqual(saved.quote,context["quote"] as? String)
        XCTAssertEqual(saved.cfi,context["cfi"] as? String)
        XCTAssertNotEqual(saved.color,.underline)
        let rendered = try await web.callAsyncJavaScript("""
            return {marks:document.querySelectorAll('.bookslide-highlight rect').length,
                    selection:Array.from(document.querySelectorAll('iframe')).map(frame=>frame.contentWindow.getSelection().toString()).join('')};
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertGreaterThan(rendered?["marks"] as? Int ?? 0,0,"The committed highlight must be visible without choosing a color")
        XCTAssertEqual(rendered?["selection"] as? String,"","Clear the temporary text selection so it does not obscure the highlight")
        let interaction = try XCTUnwrap(web.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        let menu = try XCTUnwrap(web.editMenuInteraction(interaction,menuFor:UIEditMenuConfiguration(identifier:nil,sourcePoint:.zero),suggestedActions:[]))
        XCTAssertEqual(menu.children.map(\.title),["问 AI","翻译","高亮","写笔记","移除标记","拷贝"])
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "Pencil 抬笔自动高亮与选项"; attachment.lifetime = .keepAlways; add(attachment)
        var options = context; options["existing"] = true
        XCTAssertEqual(web.annotationMenuElements(context:options).map(\.title),["问 AI","翻译","高亮","写笔记","移除标记"])
        web.dismissAnnotationMenu()
        try await waitUntil { !reader.inlineInkMenuActive }
        let reopened = ReaderModel(directory:reader.directory,loadExternalSources:false); reopened.currentID = reader.currentID
        XCTAssertEqual(reopened.currentAnnotations.first?.id,saved.id,"Closing the options must keep the committed highlight")
        options["color"] = "blue"
        web.performAnnotation("annotationChange",context:options)
        try await waitUntil { reader.currentAnnotations.first?.color == .blue }
        _ = try await web.callAsyncJavaScript("""
            reader.pencilSelect(start.x,start.y,'begin');
            reader.pencilSelect(end.x,end.y,'extend');
            return reader.pencilSelect(end.x,end.y,'end');
            """,arguments:["start":try XCTUnwrap(context["start"]),"end":try XCTUnwrap(context["end"])],in:nil,contentWorld:.page)
        try await waitUntil { reader.inlineInkMenuActive }
        XCTAssertEqual(reader.currentAnnotations.count,1)
        XCTAssertEqual(reader.currentAnnotations.first?.id,saved.id)
        XCTAssertEqual(reader.currentAnnotations.first?.color,.blue)
        web.performAnnotation("annotationRemove",context:options)
        try await waitUntil { reader.currentAnnotations.isEmpty }
        XCTAssertTrue(reader.currentPageNotes.isEmpty)
        XCTAssertFalse(host.ink.ready)
    }
    func testFingerSelectionAndCancelledPencilSelectionDoNotAutomaticallyHighlight() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.selectInkTool(.reading)
        let web = reader.webView
        let result = try await web.callAsyncJavaScript("""
            const frame = document.querySelector('iframe'), doc = frame.contentDocument;
            const paragraph = doc.querySelector('p'), range = doc.createRange(); range.selectNodeContents(paragraph);
            const selection = doc.defaultView.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            reader.annotationContext();
            const glyph = doc.createRange(), text = paragraph.firstChild;
            glyph.setStart(text,1); glyph.setEnd(text,2);
            const rect = glyph.getClientRects()[0], box = frame.getBoundingClientRect();
            const x = box.left+rect.left+rect.width/2, y = box.top+rect.top+rect.height/2;
            reader.dismissAnnotations();
            if (!reader.pencilSelect(x,y,'begin')) throw Error('Selection begin failed');
            reader.pencilSelect(x,y,'cancel');
            return reader.pencilSelect(x,y,'end');
            """,arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(result as? Bool,false)
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        XCTAssertFalse(reader.inlineInkMenuActive)
    }
    func testUnifiedToolsApplyToTheLiveCanvasWithoutTakingTextFocus() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.inlineInkTool = .marker; reader.inlineInkColor = .blue; reader.inlineInkWidth = 5
        host.ink.updateTools()
        let marker = try XCTUnwrap(host.ink.canvas.tool as? PKInkingTool)
        XCTAssertEqual(marker.inkType,.marker)
        XCTAssertEqual(marker.width,25)
        XCTAssertEqual(marker.color,UIColor(reader.inlineInkColor.color(appearance:reader.appearance)))
        reader.inlineInkTool = .eraser; host.ink.updateTools()
        XCTAssertTrue(host.ink.canvas.tool is PKEraserTool)
        reader.inlineInkTool = .lasso; host.ink.updateTools()
        XCTAssertTrue(host.ink.canvas.tool is PKLassoTool)
        reader.inlineInkTool = .pen; reader.inlineInkWidth = 1.5; host.ink.updateTools()
        XCTAssertEqual((host.ink.canvas.tool as? PKInkingTool)?.width,1.5)
        XCTAssertEqual(host.ink.canvas.drawingPolicy,.pencilOnly)
        XCTAssertFalse(host.ink.canvas.isFirstResponder)
        host.ink.canvasViewDidBeginUsingTool(host.ink.canvas)
        reader.inlineInkTool = .marker
        host.ink.updateTools()
        XCTAssertEqual((host.ink.canvas.tool as? PKInkingTool)?.inkType,.pen,"A SwiftUI update must not replace a tool during the active stroke")
        host.ink.canvasViewDidEndUsingTool(host.ink.canvas)
        try await waitUntil { (host.ink.canvas.tool as? PKInkingTool)?.inkType == .marker }
    }
    func testPencilDoubleTapRestoresInkSettingsAndSupportsPreviousToolPreference() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        XCTAssertTrue(host.interactions.contains { $0 === host.ink.pencilInteraction })
        XCTAssertTrue(host.ink.pencilInteraction.delegate === host.ink)
        reader.inlineInkTool = .marker; reader.inlineInkColor = .blue; reader.inlineInkWidth = 5
        host.ink.updateTools()
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.eraser)
        XCTAssertTrue(host.ink.canvas.tool is PKEraserTool)
        XCTAssertEqual(reader.readingNotice,"橡皮擦")
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.marker)
        XCTAssertEqual(reader.inlineInkColor,.blue)
        XCTAssertEqual((host.ink.canvas.tool as? PKInkingTool)?.width,25)
        reader.inlineInkTool = .pen; reader.inlineInkColor = .red; reader.inlineInkWidth = 1.5
        host.ink.updateTools()
        host.ink.performPencilAction(.switchPrevious)
        XCTAssertEqual(reader.inlineInkTool,.marker)
        XCTAssertEqual(reader.inlineInkColor,.blue)
        host.ink.performPencilAction(.switchPrevious)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        XCTAssertEqual(reader.inlineInkColor,.red)
        XCTAssertEqual(reader.inlineInkWidth,1.5)
        host.ink.performPencilAction(.ignore)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        reader.inlineInkObscured = true
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.pen,"A Pencil gesture must not switch tools behind a reading panel")
    }
    func testPencilActionsWaitForLiftAndSqueezeActsOnlyOnceOnRelease() async throws {
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        host.ink.canvasViewDidBeginUsingTool(host.ink.canvas)
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        XCTAssertEqual((host.ink.canvas.tool as? PKInkingTool)?.inkType,.pen)
        host.ink.canvasViewDidEndUsingTool(host.ink.canvas)
        try await waitUntil { reader.inlineInkTool == .eraser }
        host.ink.performPencilAction(.showColorPalette)
        XCTAssertTrue(reader.inlineInkToolsVisible)
        host.ink.performPencilAction(.showInkAttributes)
        XCTAssertFalse(reader.inlineInkToolsVisible)
        if #available(iOS 17.5, *) {
            host.ink.handlePencilSqueeze(.began,action:.showContextualPalette)
            host.ink.handlePencilSqueeze(.changed,action:.showContextualPalette)
            host.ink.handlePencilSqueeze(.cancelled,action:.showContextualPalette)
            XCTAssertFalse(reader.inlineInkToolsVisible)
            host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
            XCTAssertEqual(reader.inlineInkTool,.reading)
            XCTAssertFalse(reader.inlineInkToolsVisible)
            host.ink.performPencilAction(.runSystemShortcut)
            XCTAssertEqual(reader.inlineInkTool,.reading)
            host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
            XCTAssertEqual(reader.inlineInkTool,.pen)
            XCTAssertFalse(reader.inlineInkToolsVisible)
        }
        XCTAssertEqual(host.ink.canvas.drawingPolicy,.pencilOnly)
        XCTAssertTrue(host.ink.canvas.drawingGestureRecognizer.view === host)
    }
    func testSqueezeSwitchesReadingAndWritingWithoutOpeningToolsAndDoubleTapKeepsEraserShortcut() async throws {
        guard #available(iOS 17.5, *) else { return }
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.inlineInkTool = .marker; reader.inlineInkColor = .blue; reader.inlineInkWidth = 5
        host.ink.updateTools()
        write(drawing(),on:host.ink)
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        XCTAssertEqual(reader.inlineInkTool,.reading)
        XCTAssertFalse(reader.inlineInkToolsVisible)
        XCTAssertFalse(host.ink.ready)
        XCTAssertEqual(reader.currentPageNotes.count,1)
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        XCTAssertEqual(reader.inlineInkTool,.marker)
        XCTAssertEqual(reader.inlineInkColor,.blue)
        XCTAssertEqual(reader.inlineInkWidth,5)
        XCTAssertFalse(reader.inlineInkToolsVisible)
        try await waitUntil { host.ink.ready }
        XCTAssertEqual((host.ink.canvas.tool as? PKInkingTool)?.width,25)
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.eraser)
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.marker)
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        XCTAssertEqual(reader.inlineInkTool,.reading)
        host.ink.performPencilAction(.switchEraser)
        XCTAssertEqual(reader.inlineInkTool,.marker,"Double tap in reading mode resumes the last writing tool")
        XCTAssertFalse(reader.inlineInkToolsVisible)
    }
    func testSqueezeWaitsForPencilLiftKeepsItsMeaningAndRespectsSaveFailure() async throws {
        guard #available(iOS 17.5, *) else { return }
        let (reader,host,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        host.ink.canvasViewDidBeginUsingTool(host.ink.canvas)
        host.ink.canvas.drawing = drawing()
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        host.ink.canvasViewDidEndUsingTool(host.ink.canvas)
        try await waitUntil { reader.inlineInkTool == .reading }
        XCTAssertFalse(reader.inlineInkToolsVisible)
        XCTAssertEqual(reader.currentPageNotes.count,1)
        host.ink.handlePencilSqueeze(.ended,action:.ignore)
        host.ink.handlePencilSqueeze(.ended,action:.runSystemShortcut)
        XCTAssertEqual(reader.inlineInkTool,.reading)
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        try await waitUntil { host.ink.ready }
        let drawingData = host.ink.canvas.drawing.dataRepresentation()
        host.ink.canvas.drawing = drawing().transformed(using:CGAffineTransform(translationX:0,y:10))
        let assets = reader.pageNoteStore.directory, moved = assets.appendingPathExtension("test-backup")
        try FileManager.default.moveItem(at:assets,to:moved)
        defer { try? FileManager.default.removeItem(at:assets); try? FileManager.default.moveItem(at:moved,to:assets) }
        try Data([0]).write(to:assets)
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        XCTAssertEqual(reader.inlineInkTool,.pen)
        XCTAssertTrue(host.ink.ready)
        XCTAssertNotEqual(host.ink.canvas.drawing.dataRepresentation(),drawingData)
        XCTAssertFalse(reader.inlineInkToolsVisible)
        reader.inlineInkObscured = true
        host.ink.handlePencilSqueeze(.ended,action:.showContextualPalette)
        XCTAssertEqual(reader.inlineInkTool,.pen)
    }
    func testMinimumMarginsUseTheFullIPadWindowInBothReadingModes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance.margin = 0; reader.appearance.font = "sans"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let controller = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { unmount(reader,window,previous) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        for mode in [ReadingMode.scroll,.paged] {
            reader.appearance.mode = mode; reader.updateAppearance()
            try await waitUntil { !reader.busy && reader.position?.mode == mode }
            XCTAssertEqual(reader.webView.bounds.width,controller.view.safeAreaLayoutGuide.layoutFrame.width,accuracy:2,"No fixed-width wrapper outside the margin setting")
            let value = try await reader.webView.callAsyncJavaScript("""
                const frame = [...document.querySelectorAll('iframe')].find(f=>f.getBoundingClientRect().right>0 && f.getBoundingClientRect().left<innerWidth);
                const body = frame.contentDocument.body, css = frame.contentWindow.getComputedStyle(body);
                return {viewport:innerWidth,frame:frame.getBoundingClientRect().width,left:parseFloat(css.paddingLeft),margin:parseFloat(css.marginLeft),body:body.clientWidth,column:parseFloat(css.columnWidth)||0};
                """,arguments:[:],in:nil,contentWorld:.page)
            let metrics = try XCTUnwrap(value as? [String:Double])
            XCTAssertEqual(try XCTUnwrap(metrics["viewport"]),reader.webView.bounds.width,accuracy:2)
            if mode == .scroll {
                XCTAssertEqual(try XCTUnwrap(metrics["frame"]),reader.webView.bounds.width,accuracy:2)
            } else {
                // A paginated chapter's iframe spans all of its pages.
                // Each visible column, rather than the whole chapter, fills the viewport.
                XCTAssertEqual(try XCTUnwrap(metrics["column"]),reader.webView.bounds.width,accuracy:2)
            }
            XCTAssertEqual(metrics["left"],0)
            XCTAssertEqual(metrics["margin"],0)
            print("BOOKSLIDE_MARGIN_CAPTURE_\(mode == .scroll ? "scroll" : "paged")")
            try await Task.sleep(for:.seconds(2))
        }
        reader.appearance.mode = .scroll; reader.appearance.margin = 80; reader.appearance.fontSize = 20; reader.updateAppearance()
        try await waitUntil { !reader.busy && reader.position?.mode == .scroll }
        let padding = try await reader.webView.callAsyncJavaScript("const f=document.querySelector('iframe'); return parseFloat(f.contentWindow.getComputedStyle(f.contentDocument.body).paddingLeft)",arguments:[:],in:nil,contentWorld:.page)
        let expectedInset = max(0,(reader.webView.bounds.width-960)/2)+40
        XCTAssertEqual(try XCTUnwrap(padding as? Double),expectedInset,accuracy:1,"Wide iPad text is centered; the selected margin is added inside that reading measure")
        reader.appearance.margin = 32; reader.updateAppearance()
        var adjusted: Double?
        for _ in 0..<100 {
            adjusted = try await reader.webView.callAsyncJavaScript("const f=document.querySelector('iframe'); return parseFloat(f.contentWindow.getComputedStyle(f.contentDocument.body).paddingLeft)",arguments:[:],in:nil,contentWorld:.page) as? Double
            if let adjusted, abs(adjusted-(expectedInset-24)) <= 1 { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertEqual(try XCTUnwrap(adjusted),expectedInset-24,accuracy:1,"Changing the margin must still move the text, even on a wide display")
        let typography = try await reader.webView.callAsyncJavaScript("""
            const f = document.querySelector('iframe'), doc = f.contentDocument;
            const body = f.contentWindow.getComputedStyle(doc.body), p = doc.querySelector('p');
            const css = f.contentWindow.getComputedStyle(p);
            return {width:innerWidth,measure:doc.body.clientWidth-parseFloat(body.paddingLeft)-parseFloat(body.paddingRight),
              paragraphGap:parseFloat(css.marginBottom)/parseFloat(css.fontSize),overflow:doc.body.scrollWidth-doc.body.clientWidth};
            """,arguments:[:],in:nil,contentWorld:.page) as? [String:Double]
        let metrics = try XCTUnwrap(typography)
        if try XCTUnwrap(metrics["width"]) > 1100 {
            let fraction = try XCTUnwrap(metrics["measure"]) / XCTUnwrap(metrics["width"])
            XCTAssertGreaterThan(fraction,0.75,"Default landscape text should fill the page without becoming edge-to-edge")
            XCTAssertLessThan(fraction,0.85,"Keep enough room to follow the next line comfortably")
        }
        XCTAssertGreaterThan(try XCTUnwrap(metrics["paragraphGap"]),0.5)
        XCTAssertLessThan(try XCTUnwrap(metrics["paragraphGap"]),0.8,"Paragraph gaps should not leave a full blank line between short passages")
        XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["overflow"]),1,"Fuller typography must not introduce horizontal scrolling")
    }
    func testNativeAnnotationMenuUsesTheCurrentSelectionAndPreservesTheRange() async throws {
        let (reader,_,window,previous) = try await mountedReader()
        defer { unmount(reader,window,previous) }
        let web = try XCTUnwrap(reader.webView as? ReaderTextWebView)
        let value = try await web.callAsyncJavaScript("""
            const doc = document.querySelector('iframe').contentDocument;
            const range = doc.createRange(); range.selectNodeContents(doc.querySelector('p'));
            const selection = doc.defaultView.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return reader.annotationContext();
            """,arguments:[:],in:nil,contentWorld:.page)
        var context = try XCTUnwrap(value as? [String:Any])
        let elements = web.annotationMenuElements(context:context)
        let palette = try XCTUnwrap(elements.compactMap { $0 as? UIMenu }.first { $0.title == "高亮" })
        XCTAssertEqual(palette.children.count,6)
        XCTAssertTrue(palette.options.contains(.displayAsPalette))
        XCTAssertEqual(elements.map(\.title),["问 AI","翻译","高亮","写笔记"])
        context["color"] = "green"
        web.performAnnotation("annotationChange",context:context)
        try await waitUntil { reader.currentAnnotations.count == 1 && !reader.inlineInkSelectionActive }
        let saved = try XCTUnwrap(reader.currentAnnotations.first)
        XCTAssertEqual(saved.cfi,context["cfi"] as? String)
        XCTAssertEqual(saved.quote,context["quote"] as? String)
        XCTAssertEqual(saved.color,.green)
        context["existing"] = true; context["note"] = "已有想法"
        let editing = web.annotationMenuElements(context:context)
        XCTAssertEqual(editing.map(\.title),["问 AI","翻译","高亮","编辑笔记","移除标记"])
        web.performAnnotation("annotationEntity",context:context)
        try await waitUntil { reader.annotationDraft != nil && reader.showNoteGraph }
        XCTAssertNil(reader.selectionEntity,"The former node action now uses the shared note editor")
        XCTAssertEqual(reader.annotationDraft?.annotation.cfi,saved.cfi)
        XCTAssertEqual(reader.annotationDraft?.annotation.quote,saved.quote)
        web.performAnnotation("annotationEdit",context:context)
        try await waitUntil { reader.showNoteGraph }
        XCTAssertEqual(reader.annotationDraft?.annotation.cfi,saved.cfi)
        XCTAssertEqual(reader.graphNoteID,saved.id)
        XCTAssertNil(reader.quickNoteDraft)
        web.performAnnotation("annotationDiscuss",context:context)
        try await waitUntil { reader.selectionDiscussion?.id == saved.id }
        XCTAssertEqual(reader.selectionDiscussion?.annotation.cfi,saved.cfi)
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertNil(reader.annotationDraft)
    }
    func testProductionReadingSceneKeepsPencilInsideTheSamePage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance.mode = .paged
        reader.selectInkTool(.pen) // Writing fixtures opt in; the app defaults to reading.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { unmount(reader,window,previous) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.inlineInk?.ready == true }
        let ink = try XCTUnwrap(reader.inlineInk)
        reader.readingControlsVisible = true
        write(drawing(),on:ink)
        try await waitUntil { reader.currentPageNotes.count == 1 && reader.inkNoteDrafts.isEmpty }
        XCTAssertEqual(ink.canvas.bounds.size,reader.webView.bounds.size)
        XCTAssertNil(host.presentedViewController)
        XCTAssertFalse(reader.handwritingActive)
        XCTAssertEqual(reader.recoverableNoteDraftCount,0)
        reader.beginPageHandwriting()
        for (theme,orientation) in [("paper",UIInterfaceOrientationMask.portrait),("night",.landscapeLeft)] {
            reader.appearance.theme = theme
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:orientation))
            try await Task.sleep(for:.milliseconds(800))
            try await waitUntil { !reader.busy && ink.ready }
            print("BOOKSLIDE_UNIFIED_CAPTURE_\(theme)")
            try await Task.sleep(for:.seconds(2))
            let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
            }
            let attachment = XCTAttachment(image:image)
            attachment.name = "统一画笔面板-\(theme)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        reader.selectInkTool(.reading)
        try await Task.sleep(for:.milliseconds(300))
        let readingImage = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let readingAttachment = XCTAttachment(image:readingImage); readingAttachment.name = "Pencil 笔橡皮擦阅读三模式"; readingAttachment.lifetime = .keepAlways; add(readingAttachment)
        reader.selectInkTool(.pen)
        try await waitUntil { ink.ready }
        let web = try XCTUnwrap(reader.webView as? ReaderTextWebView)
        let selected = try await web.callAsyncJavaScript("""
            const doc = document.querySelector('iframe').contentDocument;
            const range = doc.createRange(); range.selectNodeContents(doc.querySelector('p'));
            const selection = doc.defaultView.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return reader.annotationContext();
            """,arguments:[:],in:nil,contentWorld:.page)
        var context = try XCTUnwrap(selected as? [String:Any])
        context["existing"] = true
        _ = try await web.callAsyncJavaScript("reader.dismissAnnotations()",arguments:[:],in:nil,contentWorld:.page)
        web.presentAnnotationMenu(context:context,x:web.bounds.midX,y:220)
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertTrue(reader.inlineInkMenuActive)
        XCTAssertFalse(ink.ready)
        print("BOOKSLIDE_UNIFIED_CAPTURE_menu")
        try await Task.sleep(for:.seconds(2))
        let menuImage = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
            window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
        }
        let menuAttachment = XCTAttachment(image:menuImage)
        menuAttachment.name = "单一原生高亮菜单"; menuAttachment.lifetime = .keepAlways; add(menuAttachment)
        print("BOOKSLIDE_PRODUCTION_INK_SCREENSHOT_READY")
        try await Task.sleep(for:.seconds(3))
    }
}

@MainActor
func makeInkGraphFixture() throws -> (ReaderModel,UUID,[ReaderPageNote]) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let reader=ReaderModel(directory:root,loadExternalSources:false),book=UUID()
    reader.books=[LibraryBook(id:book,title:"手写与阅读脉络",author:"",filename:"")];reader.currentID=book
    reader.chapters=[.init(id:"one",href:"one.xhtml",title:"阅读与理解",depth:0)]
    var anchor=ReaderPageAnchor(locator:"epubcfi(/6/2!/4/2/1:0)",chapter:"阅读与理解",progress:0,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"fixture")
    anchor.chapterHref="one.xhtml"
    anchor.textSpans=[.init(id:"epubcfi(/6/2!/4/2,/1:0,/1:8)",block:"first",offset:0,text:"第一处阅读原文",boxes:[.init(x:40,y:108,width:180,height:26)]),.init(id:"epubcfi(/6/2!/4/4,/1:0,/1:8)",block:"second",offset:0,text:"第二处阅读原文",boxes:[.init(x:40,y:408,width:180,height:26)])]
    let strokes=[134.0,434.0].enumerated().map { index,y in
        let points=(0...24).map { i in PKStrokePoint(location:.init(x:40+Double(i)*7.5,y:y),timeOffset:Double(i)/60,size:.init(width:3,height:3),opacity:1,force:0.7,azimuth:0,altitude:1) }
        return PKStroke(ink:.init(.pen,color:.systemRed),path:.init(controlPoints:points,creationDate:Date(timeIntervalSince1970:Double(index+100))))
    }
    let format=UIGraphicsImageRendererFormat();format.scale=1
    let page=UIGraphicsImageRenderer(size:.init(width:600,height:800),format:format).image { context in
        UIColor.white.setFill();context.fill(.init(x:0,y:0,width:600,height:800))
        for (text,y) in [("第一处阅读原文",108.0),("第二处阅读原文",408.0)] {
            (text as NSString).draw(at:.init(x:40,y:y),withAttributes:[.font:UIFont.systemFont(ofSize:20),.foregroundColor:UIColor.black])
        }
    }
    let note=ReaderPageNote(assetID:UUID(),anchor:anchor)
    let files=try PagePencilCanvasController(drawing:PKDrawing(strokes:strokes),size:page.size,color:.black).files(page:page)
    guard reader.savePageNote(note,files:files,bookID:book) else { throw NSError(domain:"InkFixture",code:1,userInfo:[NSLocalizedDescriptionKey:reader.error ?? "save failed"]) }
    return (reader,book,reader.currentPageNotes)
}

extension PencilPageTests {
    func testInkGroupsDeleteRestoreReopenAndKeepEditableStrokes() throws {
        let (reader,book,notes)=try makeInkGraphFixture()
        defer { reader.close();try? FileManager.default.removeItem(at:reader.directory) }
        XCTAssertEqual(notes.count,2)
        XCTAssertEqual(Set(notes.map(\.excerpt)),["第一处阅读原文","第二处阅读原文"])
        let first=try XCTUnwrap(notes.first)
        XCTAssertEqual(reader.pageHandwritingDraft(for:first)?.drawing.strokes.count,2)
        let image=try XCTUnwrap(reader.pageNoteImage(first))
        XCTAssertLessThan(image.size.height,200,"The graph preview contains the marked passage, not a whole page")
        XCTAssertTrue(reader.removePageNote(first.id))
        XCTAssertEqual(reader.pageHandwritingDraft(for:try XCTUnwrap(reader.currentPageNotes.first))?.drawing.strokes.count,1)
        XCTAssertTrue(reader.restoreRemovedNote(try XCTUnwrap(reader.noteUndoID)))
        let draft=try XCTUnwrap(reader.pageHandwritingDraft(for:first))
        XCTAssertEqual(draft.drawing.strokes.count,2)
        let ids=Set(reader.currentPageNotes.map(\.id))
        let files=try PagePencilCanvasController(drawing:draft.drawing,size:draft.page.size,color:.black).files(page:draft.page)
        XCTAssertTrue(reader.savePageNote(draft.note,files:files,bookID:book))
        XCTAssertEqual(Set(reader.currentPageNotes.map(\.id)),ids,"Saving again preserves graph connections through stable group IDs")
        let reopened=ReaderModel(directory:reader.directory,loadExternalSources:false);reopened.currentID=book
        XCTAssertEqual(Set(reopened.currentPageNotes.map(\.id)),ids)
        XCTAssertEqual(reopened.pageHandwritingDraft(for:try XCTUnwrap(reopened.currentPageNotes.first))?.drawing.strokes.count,2)
        reopened.close()
    }
}

extension PencilPageTests {
    func testReturningToTheSamePassageAfterReflowKeepsItsGraphNode() throws {
        let (reader,book,notes)=try makeInkGraphFixture()
        defer { reader.close();try? FileManager.default.removeItem(at:reader.directory) }
        let first=try XCTUnwrap(notes.first(where:{ $0.excerpt.contains("第一处") })),other=try XCTUnwrap(notes.first(where:{ $0.id != first.id }))
        let link=try XCTUnwrap(reader.connectReadingNodes(from:.init(.ink,first.id.uuidString),to:.init(.ink,other.id.uuidString),label:"相关",bookID:book))
        let files=try reader.pageNoteStore.load(first.assetID)
        var anchor=first.anchor;anchor.layoutKey="larger-font"
        anchor.textSpans=first.inkParts.flatMap(\.sources).map { span in var span=span;span.boxes=span.boxes.map { .init($0.rect.offsetBy(dx:0,dy:100)) };return span }
        let canvas=ReaderPageNote(assetID:UUID(),anchor:anchor)
        let newInk=try PKDrawing(data:files.drawing).transformed(using:.init(translationX:0,y:100))
        let page=try XCTUnwrap(UIImage(data:files.page))
        XCTAssertTrue(reader.savePageNote(canvas,files:try PagePencilCanvasController(drawing:newInk,size:page.size,color:.black).files(page:page),bookID:book))
        XCTAssertEqual(Set(reader.currentPageNotes.map(\.id)),Set(notes.map(\.id)))
        XCTAssertEqual(reader.currentPageNotes.first(where:{ $0.id==first.id })?.inkParts.count,2)
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains(where:{ $0.id==link }) == true)
        let newCanvas=try XCTUnwrap(reader.pageInkCanvases.first(where:{ $0.id==canvas.id }))
        XCTAssertEqual(reader.pageHandwritingDraft(for:newCanvas)?.drawing.strokes.count,1)
    }

    func testPrepareInkGraphUIFixtureFromTheLiveEPUB() async throws {
        let (reader,host,window,previous)=try await mountedReader()
        defer { unmount(reader,window,previous) }
        reader.appearance=ReaderAppearance();reader.updateAppearance()
        try await Task.sleep(for:.milliseconds(500))
        try await waitUntil { host.ink.ready }
        let original=drawing(),second=drawing().transformed(using:.init(translationX:0,y:350))
        write(PKDrawing(strokes:original.strokes+second.strokes),on:host.ink)
        try await waitUntil { reader.currentPageNotes.count==2 && reader.inkNoteDrafts.isEmpty }
        XCTAssertTrue(reader.currentPageNotes.allSatisfy { !$0.excerpt.isEmpty },"Real EPUB text anchors accompany the saved Pencil marks")
        XCTAssertTrue(reader.currentPageNotes.allSatisfy { $0.title == nil && $0.text == nil },"Marking source text does not create a caption")
        XCTAssertTrue(host.ink.suspend())
        let book=try XCTUnwrap(reader.currentID)
        XCTAssertTrue(reader.commitReadingGraph(bookID:book) { graph in
            graph.replaceEntities(graph.entities + [BookEntity(name:"林川",kind:.person)])
        })
        reader.save()
        // Each UI flow mutates its own copy of the same two original marks.
        for library in ["92FA25CA-312D-4A43-B709-2159B0D21AD6","562CF7A6-FC01-4157-B847-09C7CBF42CDB"] {
            let fixture=FileManager.default.temporaryDirectory.appendingPathComponent("UITest-"+library)
            if FileManager.default.fileExists(atPath:fixture.path) { try FileManager.default.removeItem(at:fixture) }
            try FileManager.default.copyItem(at:reader.directory,to:fixture)
        }
    }
}

extension PencilPageTests {
    func testPencilStrokeUndoRedoRestoresTheOriginalNodeAndConnections() throws {
        let (reader,book,notes)=try makeInkGraphFixture()
        defer { reader.close();try? FileManager.default.removeItem(at:reader.directory) }
        let first=notes[0],second=notes[1]
        let edge=try XCTUnwrap(reader.connectReadingNodes(from:.init(.ink,first.id.uuidString),to:.init(.ink,second.id.uuidString),label:"相互印证",bookID:book))
        let canvas=try XCTUnwrap(reader.pageHandwritingDraft(for:first))
        let smaller=PKDrawing(strokes:Array(canvas.drawing.strokes.dropLast()))
        let size=CGSize(width:canvas.note.anchor.viewportWidth,height:canvas.note.anchor.viewportHeight)
        XCTAssertTrue(reader.savePageNote(canvas.note,files:try PagePencilCanvasController(drawing:smaller,size:size,color:.black).files(page:canvas.page),bookID:book))
        XCTAssertEqual(reader.currentPageNotes.count,1)
        XCTAssertTrue(reader.savePageNote(canvas.note,files:try PagePencilCanvasController(drawing:canvas.drawing,size:size,color:.black).files(page:canvas.page),bookID:book))
        XCTAssertEqual(Set(reader.currentPageNotes.map(\.id)),Set(notes.map(\.id)))
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains(where:{ $0.id==edge }) == true)
        XCTAssertFalse(reader.removedNotes.contains(where:{ $0.pageNote.map { Set(notes.map(\.id)).contains($0.id) } ?? false }))
    }
}
