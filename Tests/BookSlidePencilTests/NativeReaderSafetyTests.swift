import XCTest
import SwiftUI
import UIKit
import WebKit
import PDFKit
import PencilKit
@testable import BookSlidePhone

@MainActor final class NativeReaderSafetyTests: XCTestCase {
    func testNarrowingTheMapKeepsTheSameLiveInputVisibleAndFocused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.currentID = try XCTUnwrap(reader.books.first?.id)
        let note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"",progress:0,note:"节点内容")
        XCTAssertTrue(reader.saveAnnotation(note,bookID:try XCTUnwrap(reader.currentID)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene), container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        container.addChild(host); container.view.addSubview(host.view)
        host.view.frame = CGRect(x:0,y:0,width:834,height:600); host.didMove(toParent:container)
        defer { unmount(reader,window,previous) }
        let map = try await auditReadyMap(host.view)
        try await Task.sleep(for:.milliseconds(350))
        let text = "旋转和软键盘变化时继续输入"
        _ = try await map.callAsyncJavaScript("""
        window.bookMindMap.command({id:'resize-edit',name:'edit',target:token});
        window.auditLiveInput=document.getElementById('input-box');
        auditLiveInput.textContent=text;auditLiveInput.dispatchEvent(new Event('input',{bubbles:true}));return true;
        """,arguments:["token":reader.mindMapToken(.init(.note,note.id)),"text":text],in:nil,contentWorld:.page)
        for size in [CGSize(width:480,height:380),CGSize(width:360,height:460),CGSize(width:834,height:600)] {
            host.view.frame.size = size; host.view.layoutIfNeeded()
            do { try await auditWait {
                try await map.callAsyncJavaScript("""
                const input=document.getElementById('input-box'), r=input?.getBoundingClientRect();
                return input===window.auditLiveInput && document.activeElement===input && input.textContent===text &&
                  r.left>=-1 && r.right<=innerWidth+1 && r.top>=-1 && r.bottom<=innerHeight+1;
                """,arguments:["text":text],in:nil,contentWorld:.page) as? Bool == true
            } } catch {
                let details=try? await map.callAsyncJavaScript("return JSON.stringify({state:bookMindMap.inspect(),same:document.getElementById('input-box')===window.auditLiveInput,active:document.activeElement?.outerHTML,rect:document.getElementById('input-box')?.getBoundingClientRect().toJSON(),width:innerWidth,height:innerHeight})",arguments:[:],in:nil,contentWorld:.page)
                print("RESIZE_FOCUS_FAILURE \(size) \(String(describing:details))")
                throw error
            }
        }
    }

    func testFailedMapFlushDuringReadingProcessRestartKeepsTheEditorForRetry() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let bookID = try XCTUnwrap(reader.currentID)
        let note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"",progress:0,note:"保留正文")
        XCTAssertTrue(reader.saveAnnotation(note,bookID:bookID))
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        window.rootViewController = host
        let map = try await auditReadyMap(host.view)
        let text = "保存失败时留在编辑器中的文字"
        _ = try await map.callAsyncJavaScript("""
        window.bookMindMap.command({id:'failed-crash-edit',name:'edit',target:token});
        const input=document.getElementById('input-box');input.textContent=text;input.dispatchEvent(new Event('input',{bubbles:true}));return true;
        """,arguments:["token":reader.mindMapToken(.init(.note,note.id)),"text":text],in:nil,contentWorld:.page)
        try blockIndex(reader.directory)
        reader.webViewWebContentProcessDidTerminate(reader.webView)
        try await wait { !reader.busy }
        XCTAssertEqual(reader.currentID,bookID)
        XCTAssertNotNil(reader.error)
        XCTAssertTrue(reader.readingControlsVisible,"A failed recovery must still offer the close/retry controls")
        XCTAssertTrue(try XCTUnwrap(reader.loadMindMapRecovery(bookID)).document.flattened().contains { $0.topic.topic == text })
        try FileManager.default.removeItem(at:reader.directory.appendingPathComponent("library.json"))
        let flush = try XCTUnwrap(reader.mindMapInputFlush)
        let saved = await flush.perform()
        XCTAssertTrue(saved)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.title,text)
        // Reopen in the shipping reading hierarchy with its live EPUB viewport.
        window.rootViewController = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController?.view.layoutIfNeeded()
        reader.close(); reader.open(bookID)
        try await wait { !reader.loading && reader.position != nil }
        XCTAssertEqual(reader.currentID,bookID)
    }

    func testReadingProcessRestartCommitsTheStillOpenMapEditor() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let bookID = try XCTUnwrap(reader.currentID)
        let note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"",progress:0,note:"保留原有内容")
        XCTAssertTrue(reader.saveAnnotation(note,bookID:bookID))
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        window.rootViewController = host
        let map = try await auditReadyMap(host.view)
        let text = "阅读进程重启前正在输入的文字"
        _ = try await map.callAsyncJavaScript("""
        window.bookMindMap.command({id:'crash-edit',name:'edit',target:token});
        const input=document.getElementById('input-box');input.textContent=text;input.dispatchEvent(new Event('input',{bubbles:true}));return true;
        """,arguments:["token":reader.mindMapToken(.init(.note,note.id)),"text":text],in:nil,contentWorld:.page)
        reader.webViewWebContentProcessDidTerminate(reader.webView)
        try await wait { reader.currentID == nil }
        let disk = try LibraryIndexStore(directory:reader.directory).load([LibraryBook].self)?.value.first { $0.id == bookID }
        XCTAssertEqual(disk?.annotations?.first { $0.id == note.id }?.title,text)
        XCTAssertEqual(disk?.annotations?.first { $0.id == note.id }?.note,note.note)
        XCTAssertFalse(reader.busy)
    }

    func testInvalidAndFixedLayoutBooksReportErrorsWithoutBlockingTheNextBook() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let sample = try XCTUnwrap(reader.currentBook)
        let data = try Data(contentsOf:reader.directory.appendingPathComponent(sample.filename))
        let archives = try await reader.webView.callAsyncJavaScript("""
        const invalid=new JSZip();invalid.file('not-a-book.txt','missing EPUB manifest');
        const fixed=await JSZip.loadAsync(data,{base64:true});
        const opf=await fixed.file('EPUB/package.opf').async('string');
        fixed.file('EPUB/package.opf',opf.replace('</metadata>','<meta property="rendition:layout">pre-paginated</meta></metadata>'));
        return [await invalid.generateAsync({type:'base64'}),await fixed.generateAsync({type:'base64'})];
        """,arguments:["data":data.base64EncodedString()],in:nil,contentWorld:.page) as? [String]
        for (index,archive) in try XCTUnwrap(archives).enumerated() {
            reader.close()
            let file = reader.directory.appendingPathComponent("invalid-\(index).epub")
            try XCTUnwrap(Data(base64Encoded:archive)).write(to:file)
            reader.importBooks([file])
            try await wait { !reader.importingBooks && !reader.loading && reader.error != nil }
            XCTAssertTrue(reader.error?.contains(index == 0 ? "有效的 EPUB" : "固定版式") == true)
            XCTAssertFalse(reader.busy)
            reader.close(); reader.open(sample.id)
            try await wait { !reader.loading && reader.position != nil }
            XCTAssertNil(reader.error)
            XCTAssertEqual(reader.currentID,sample.id)
        }
    }

    func testMixedImportRestoresDuplicateWithoutLosingNotesOrBookmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        defer { reader.close(); try? FileManager.default.removeItem(at:root) }
        let book = try XCTUnwrap(reader.books.first)
        let note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"",progress:0,note:"重复导入后继续保留")
        reader.books[0].annotations = [note]
        reader.books[0].bookmarks = [.init(id:"saved-cfi",title:"书签",progress:0.3)]
        reader.books[0].hidden = true; reader.save()
        let invalid = root.appendingPathComponent("invalid.epub")
        try Data("not a zip archive".utf8).write(to:invalid)
        reader.importBooks([root.appendingPathComponent(book.filename),invalid])
        try await wait { !reader.importingBooks }
        XCTAssertEqual(reader.books.count,1)
        XCTAssertEqual(reader.visibleBooks.first?.id,book.id)
        XCTAssertEqual(reader.books[0].annotations?.first?.note,note.note)
        XCTAssertEqual(reader.books[0].bookmarks.first?.id,"saved-cfi")
        XCTAssertTrue(reader.importMessage?.contains("已在书库 1 本，未完成 1 本") == true)
        XCTAssertNil(reader.currentID,"A batch import must leave the library available")
        let disk = try LibraryIndexStore(directory:root).load([LibraryBook].self)?.value
        XCTAssertEqual(disk?.count,1); XCTAssertEqual(disk?.first?.hidden,false)
        XCTAssertEqual(disk?.first?.annotations?.first?.note,note.note)
    }

    func testCatalogWriteFailureKeepsTheExistingBookAndNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let book = try XCTUnwrap(reader.books.first)
        reader.books[0].progressKey = "catalog-fixture"
        try blockIndex(root)
        let receiver = UUID(), remote = UUID()
        let saved = reader.applyMacCatalog([.init(id:remote,title:"远程标题",author:"远程作者",lastRead:Date(),progressKey:"catalog-fixture")],receiverID:receiver)
        XCTAssertFalse(saved)
        XCTAssertEqual(reader.books.count,1)
        XCTAssertEqual(reader.books[0].id,book.id)
        XCTAssertEqual(reader.books[0].title,book.title)
        XCTAssertNil(reader.books[0].remoteBookID)
        XCTAssertNotNil(reader.error)
    }

    func testAnOldPageTurnCannotShowAnErrorOverAReopenedBook() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let id = try XCTUnwrap(reader.currentID)
        _ = try await reader.webView.evaluateJavaScript("""
        window.auditOldTurnStarted=false;
        reader.turn=async ()=>{window.auditOldTurnStarted=true;await new Promise(r=>setTimeout(r,700));return null;};true;
        """)
        let pending = Task { await reader.turnLocally(.next) }
        try await wait { try await reader.webView.evaluateJavaScript("window.auditOldTurnStarted") as? Bool == true }
        reader.close(); reader.open(id)
        try await wait { !reader.loading && reader.position != nil }
        await pending.value
        XCTAssertEqual(reader.currentID,id)
        XCTAssertNil(reader.readingNotice,"Completion of an old turn belongs to the old reading session")
        XCTAssertFalse(reader.busy)
    }

    func testBackgroundFlushSavesTheLatestLiveNodeText() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let bookID = try XCTUnwrap(reader.currentID)
        let note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"",progress:0,note:"保留原有正文")
        XCTAssertTrue(reader.saveAnnotation(note,bookID:bookID))
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        window.rootViewController = host
        let map = try await auditReadyMap(host.view)
        let text = "进入后台时尚未离开编辑框的文字"
        _ = try await map.callAsyncJavaScript("""
        window.bookMindMap.command({id:'background-edit',name:'edit',target:token});
        const input=document.getElementById('input-box');input.textContent=text;input.dispatchEvent(new Event('input',{bubbles:true}));return true;
        """,arguments:["token":reader.mindMapToken(.init(.note,note.id)),"text":text],in:nil,contentWorld:.page)
        reader.flushProgressInBackground()
        try await wait { reader.currentAnnotations.first { $0.id == note.id }?.title == text }
        let disk = try LibraryIndexStore(directory:reader.directory).load([LibraryBook].self)?.value.first { $0.id == bookID }
        XCTAssertEqual(disk?.annotations?.first { $0.id == note.id }?.title,text)
        XCTAssertEqual(disk?.annotations?.first { $0.id == note.id }?.note,note.note)
    }

    func testTypographyBlocksNavigationBeforeTheDebouncedReflowBegins() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        reader.appearance.mode = .paged
        reader.updateAppearance()
        XCTAssertTrue(reader.busy,"The controls must cover the debounce interval as well as WebKit's reflow")
        XCTAssertFalse(reader.go("chapter1.xhtml"))
        try await wait { !reader.busy && reader.position?.mode == .paged }
        let failure = await reader.turn(.next)
        XCTAssertNil(failure)
        XCTAssertNil(reader.error)
    }

    func testFailedDownloadRemovalKeepsTheOfflineBookAndItsNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        defer { try? FileManager.default.removeItem(at:root) }
        var book = try XCTUnwrap(reader.books.first)
        book.remoteBookID = UUID(); book.remoteReceiverID = UUID()
        book.annotations = [ReaderAnnotation(cfi:"",quote:"保留的笔记",chapter:"",progress:0,note:"我的想法")]
        reader.books = [book]; reader.save()
        let data = try Data(contentsOf:root.appendingPathComponent(book.filename))
        try blockIndex(root)
        reader.removeDownload(book)
        XCTAssertEqual(reader.books.first?.filename,book.filename)
        XCTAssertTrue(reader.isDownloaded(try XCTUnwrap(reader.books.first)))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(book.filename)),data)
        XCTAssertEqual(reader.books.first?.annotations?.first?.note,"我的想法")
        XCTAssertNotNil(reader.error)
    }

    func testFailedLibraryVisibilityChangesDoNotPretendTheyWereSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let book = try XCTUnwrap(reader.books.first)
        try blockIndex(root)
        reader.remove(book)
        XCTAssertEqual(reader.visibleBooks.count,1)
        XCTAssertNotNil(reader.error)
        reader.books[0].hidden = true; reader.error = nil
        reader.restoreHiddenBooks()
        XCTAssertTrue(reader.visibleBooks.isEmpty)
        XCTAssertNotNil(reader.error)
    }

    func testImportSaveFailureDoesNotReportSuccessOrOpenAnUnstoredBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        defer { reader.close(); try? FileManager.default.removeItem(at:root) }
        let book = try XCTUnwrap(reader.books.first)
        reader.books[0].hidden = true
        try blockIndex(root)
        reader.importBooks([root.appendingPathComponent(book.filename)])
        try await wait { !reader.importingBooks }
        XCTAssertNil(reader.currentID)
        XCTAssertTrue(reader.visibleBooks.isEmpty)
        XCTAssertTrue(reader.importMessage?.contains("未完成 1 本") == true)
        XCTAssertTrue(reader.importMessage?.contains("已在书库 0 本") == true)
    }

    private func blockIndex(_ root: URL) throws {
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at:index)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        try Data("atomic write blocker".utf8).write(to:index.appendingPathComponent("blocker"))
    }

    func testInvalidatingRemoteCommandsDuringOpenStillFinishesLoading() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let id = try XCTUnwrap(reader.currentID)
        reader.close()
        _ = try await reader.webView.evaluateJavaScript("""
        window.auditOpenStarted=false;
        const original=reader.open.bind(reader);
        reader.open=async (...args)=>{window.auditOpenStarted=true; await new Promise(r=>setTimeout(r,350));return original(...args);};true;
        """)
        reader.open(id)
        try await wait { try await reader.webView.evaluateJavaScript("window.auditOpenStarted") as? Bool == true }
        reader.invalidateSession()
        try await wait { !reader.loading && reader.position != nil }
        XCTAssertEqual(reader.currentID,id)
        XCTAssertNotNil(reader.snapshot)
        XCTAssertNil(reader.error)
    }

    func testPausingRemoteControlDoesNotReleaseAnInFlightPageTurn() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let oldSession = try XCTUnwrap(reader.snapshot?.sessionID)
        _ = try await reader.webView.evaluateJavaScript("""
        window.auditTurnStarted=false;
        const original=reader.turn.bind(reader);
        reader.turn=async (...args)=>{window.auditTurnStarted=true; await new Promise(r=>setTimeout(r,350));return original(...args);};true;
        """)
        let pending = Task { await reader.turn(.next) }
        try await wait { try await reader.webView.evaluateJavaScript("window.auditTurnStarted") as? Bool == true }
        let receiver = IPadReaderReceiver(reader:reader)
        receiver.enable(); receiver.suspend()
        XCTAssertTrue(reader.busy,"Backgrounding must not let a second navigation overlap the unfinished WebKit operation")
        XCTAssertNotEqual(reader.snapshot?.sessionID,oldSession,"Commands from before the pause must expire")
        let failure = await pending.value
        XCTAssertNil(failure)
        XCTAssertFalse(reader.busy)
        XCTAssertNotNil(reader.position)
    }

    func testWebProcessRestartClearsNavigationLocksAndEditorsAndCanReopen() async throws {
        let (reader,window,previous) = try await mount()
        defer { unmount(reader,window,previous) }
        let id = try XCTUnwrap(reader.currentID)
        let before = try XCTUnwrap(reader.position)
        let note = ReaderAnnotation(cfi:before.locator,quote:"恢复测试",chapter:before.chapter,progress:before.progress,note:"应保留的内容")
        XCTAssertTrue(reader.saveAnnotation(note,bookID:id))
        reader.showNoteGraph = true; reader.graphNoteID = note.id
        reader.selectionEntity = .init(bookID:id,annotation:note)
        reader.showProgressSettings = true; reader.busy = true
        reader.webViewWebContentProcessDidTerminate(reader.webView)
        XCTAssertNil(reader.currentID)
        XCTAssertFalse(reader.busy)
        XCTAssertFalse(reader.loading)
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertFalse(reader.showProgressSettings)
        XCTAssertNil(reader.selectionEntity)
        XCTAssertNil(reader.graphNoteID)
        reader.open(id)
        try await wait { !reader.loading && reader.position != nil }
        XCTAssertEqual(reader.currentID,id)
        XCTAssertEqual(reader.currentAnnotations.first?.note,note.note)
        XCTAssertNil(reader.error)
    }

    private func mount() async throws -> (ReaderModel,UIWindow,UIWindow?) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance = ReaderAppearance(); reader.appearance.mode = .scroll
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let controller = UIViewController(), host = ReaderPencilHost(reader:reader)
        controller.view.addSubview(host); host.frame = CGRect(x:0,y:0,width:834,height:700)
        window.rootViewController = controller; window.makeKeyAndVisible()
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await wait { !reader.loading && reader.position != nil }
        return (reader,window,previous)
    }
    private func unmount(_ reader: ReaderModel,_ window: UIWindow,_ previous: UIWindow?) {
        reader.close(); reader.webView.stopLoading()
        reader.webView.configuration.userContentController.removeScriptMessageHandler(forName:"reader")
        window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        try? FileManager.default.removeItem(at:reader.directory)
    }

    func testSelectedTextDraftRemainsVisibleBeyondTheViewportProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        defer { reader.close(); try? FileManager.default.removeItem(at:root) }
        let id = try XCTUnwrap(reader.books.first?.id)
        reader.currentID = id
        let note = ReaderAnnotation(cfi:"selection",quote:"选取的文字可以跨过当前进度锚点",chapter:"示例",progress:0.75)
        reader.annotationDraft = .init(bookID:id,annotation:note)
        XCTAssertLessThan(reader.noteVisibilityProgress,note.progress)
        let topics = try reader.mindMapDocument().flattened()
        XCTAssertTrue(topics.contains { $0.topic.metadata?.nodeID == .init(.note,note.id) })
        XCTAssertTrue(reader.currentBook?.graph.nodes.isEmpty == true,"Showing a draft must not save an empty note")
    }

    func testLiveCanvasTextSurvivesFailedCloseSaveAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let bookID = try XCTUnwrap(reader.books.first?.id)
        reader.currentID = bookID
        let note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"示例",progress:0,note:"保留已有正文")
        XCTAssertTrue(reader.saveAnnotation(note,bookID:bookID))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:MindMapCanvas(reader:reader,document:reader.mindMapDocument(includeFuture:true),includeFuture:true,
            selected:{ _,_ in },action:{ _,_,_ in },edgeSelected:{ _ in },frameChanged:{ _,_ in },failed:{ _ in }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView, web.accessibilityIdentifier == "book-note-graph-viewport" { return web }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        try await wait { find(host.view) != nil }
        let web = try XCTUnwrap(find(host.view))
        try await wait { try await web.callAsyncJavaScript("return window.bookMindMap?.inspect().ready || false",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        let token = reader.mindMapToken(.init(.note,note.id))
        let text = "关闭时也要保留刚输入的文字"
        let edited = try await web.callAsyncJavaScript("""
        window.bookMindMap.command({id:'select-live',name:'select',target:token});
        window.bookMindMap.command({id:'edit-live',name:'edit'});
        const input=document.getElementById('input-box');
        if(!input)return false;
        input.textContent=text;input.dispatchEvent(new Event('input',{bubbles:true}));return true;
        """,arguments:["token":token,"text":text],in:nil,contentWorld:.page)
        XCTAssertEqual(edited as? Bool,true)
        // A real write failure must keep the canvas open and retain its text.
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at:index)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        try Data("block atomic replacement".utf8).write(to:index.appendingPathComponent("blocker"))
        let flush = try XCTUnwrap(reader.mindMapInputFlush)
        let failed = await flush.perform()
        XCTAssertFalse(failed)
        XCTAssertNotNil(reader.error)
        let retained = try await web.callAsyncJavaScript("return JSON.stringify(window.bookMindMap.inspect().data)",arguments:[:],in:nil,contentWorld:.page) as? String
        XCTAssertTrue(retained?.contains(text) == true)
        try FileManager.default.removeItem(at:index)
        reader.error = nil
        let saved = await flush.perform()
        XCTAssertTrue(saved)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.title,text)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,note.note)
        let disk = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first { $0.id == bookID })
        XCTAssertEqual(disk.graph.annotations.first { $0.id == note.id }?.title,text)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<150 {
            if try await condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("阅读画布未就绪")
        throw ReaderError.message("Canvas timeout")
    }
}

/// Exercise the shipping model and WebKit engine through a complete, longer
/// EPUB, rather than validating only the first page of the short sample book.
@MainActor final class PageNavigationAuditTests: XCTestCase {
    func testCompleteBookForwardBackwardAtIPadWindowSizesInBothModes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let controller = UIViewController(), host = ReaderPencilHost(reader:reader)
        controller.view.addSubview(host)
        host.frame = CGRect(x:0,y:0,width:834,height:700)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            reader.close(); host.ink.stop(); reader.webView.stopLoading()
            reader.webView.configuration.userContentController.removeScriptMessageHandler(forName:"reader")
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            try? FileManager.default.removeItem(at:root)
        }
        reader.appearance = ReaderAppearance(); reader.appearance.fontSize = 28
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await ready(reader)
        let base = try Data(contentsOf:ReaderModel.resources.appendingPathComponent("QuietHours.epub"))
        let archive = try await reader.webView.callAsyncJavaScript("""
        const zip=await JSZip.loadAsync(data,{base64:true});
        for(let chapter=0;chapter<3;chapter++) {
          zip.file(`EPUB/chapter${chapter}.xhtml`,`<html xmlns="http://www.w3.org/1999/xhtml"><head><title>章节 ${chapter}</title></head><body><h1>章节 ${chapter}</h1>${Array.from({length:24},(_,i)=>`<p id="p${i}">第${chapter}章第${i}段。阅读应当连续完整，向前翻页不跳过文字，向后翻页仍能找到刚才的位置。跨越章节时，正文保持可见，操作不会卡住。</p>`).join('')}</body></html>`);
        }
        return await zip.generateAsync({type:'base64'});
        """,arguments:["data":base.base64EncodedString()],in:nil,contentWorld:.page)
        let data = try XCTUnwrap((archive as? String).flatMap { Data(base64Encoded:$0) })
        let file = root.appendingPathComponent("NavigationAudit.epub")
        try data.write(to:file)
        reader.close(); reader.importBooks([file])
        try await wait { !reader.importingBooks && !reader.loading && reader.position != nil }
        let bookID = try XCTUnwrap(reader.currentID)
        for size in [CGSize(width:1194,height:760),CGSize(width:834,height:1112),CGSize(width:600,height:700)] {
            host.frame.size = size; host.setNeedsLayout(); host.layoutIfNeeded()
            for mode in [ReadingMode.scroll,.paged] {
                reader.appearance.mode = mode; reader.updateAppearance()
                try await wait { !reader.busy && reader.position?.mode == mode }
                _ = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page)
                XCTAssertTrue(reader.go("chapter0.xhtml")); try await ready(reader)
                let context = "\(Int(size.width))x\(Int(size.height)) \(mode)"
                var visited = Set<String>(), steps = 0
                for direction in [PageDirection.next,.previous] {
                    while let before = reader.position, direction == .next ? before.canGoNext : before.canGoPrevious {
                        let failure = await reader.turn(direction)
                        XCTAssertNil(failure,"\(context), \(direction), \(before.locator)")
                        if failure != nil { throw ReaderError.message(failure!) }
                        let after = try XCTUnwrap(reader.position)
                        let ordering = try await reader.webView.callAsyncJavaScript("return new ePub.CFI().compare(a,b)",arguments:["a":before.locator,"b":after.locator],in:nil,contentWorld:.page) as? Int
                        if direction == .next { XCTAssertLessThanOrEqual(try XCTUnwrap(ordering),0,context) }
                        else { XCTAssertGreaterThanOrEqual(try XCTUnwrap(ordering),0,context) }
                        if mode == .paged {
                            let delta = direction == .next ? 1 : -1
                            let sectionChange = try await reader.webView.callAsyncJavaScript("return new ePub.CFI(b).spinePos-new ePub.CFI(a).spinePos",arguments:["a":before.locator,"b":after.locator],in:nil,contentWorld:.page) as? Int
                            if sectionChange == 0 {
                                XCTAssertEqual(after.page,before.page+delta,"A swipe must advance exactly one page, without repeats or skipped pages: \(context)")
                            } else {
                                XCTAssertEqual(sectionChange,delta,"Crossing a chapter must not skip a spine section: \(context)")
                                XCTAssertEqual(after.page,direction == .next ? 1 : after.pageCount,context)
                            }
                        }
                        visited.insert(after.anchor?.href ?? "")
                        XCTAssertTrue(after.locator != before.locator || after.viewportOffset != before.viewportOffset,"A successful turn must actually move: \(context)")
                        let visible = try await reader.webView.callAsyncJavaScript("""
                        const c=document.querySelector('.epub-container'), bounds=c.getBoundingClientRect();
                        return [...document.querySelectorAll('iframe')].some(f=>{const r=f.getBoundingClientRect();return r.right>bounds.left+1 && r.left<bounds.right-1 && r.bottom>bounds.top+1 && r.top<bounds.bottom-1 && f.contentDocument?.body?.textContent.trim().length>0 && getComputedStyle(f).visibility!=='hidden';});
                        """,arguments:[:],in:nil,contentWorld:.page) as? Bool
                        XCTAssertEqual(visible,true,"The visible page must contain loaded text: \(context)")
                        XCTAssertFalse(reader.busy,context); XCTAssertNil(reader.error,context)
                        steps += 1
                        guard steps < 180 else { throw ReaderError.message("翻页循环未能到达首尾：\(context)") }
                    }
                    let boundary = try XCTUnwrap(reader.position)
                    XCTAssertEqual(direction == .next ? boundary.canGoNext : boundary.canGoPrevious,false,context)
                    if direction == .next { XCTAssertEqual(boundary.progress,1,accuracy:0.001,context) }
                    await reader.turnLocally(direction)
                    XCTAssertEqual(reader.position?.locator,boundary.locator,"Turning beyond the boundary must remain stable")
                    XCTAssertNil(reader.readingNotice,"Normal page boundaries are not errors")
                }
                XCTAssertGreaterThanOrEqual(visited.count,3,"Every chapter must be reachable: \(context)")
                XCTAssertEqual(reader.currentID,bookID)
                print("PAGE_NAVIGATION_AUDIT \(context): \(steps) forward/backward turns, all chapters visited")
                let singleFailure = await reader.turn(.next)
                XCTAssertNil(singleFailure)
                let single = try XCTUnwrap(reader.position)
                let reverseFailure = await reader.turn(.previous)
                XCTAssertNil(reverseFailure)
                let burst = (0..<12).map { _ in Task { await reader.turnLocally(.next) } }
                for task in burst { await task.value }
                XCTAssertEqual(reader.position?.locator,single.locator,"Overlapping rapid gestures must not skip ahead: \(context)")
                XCTAssertFalse(reader.busy,context)
                XCTAssertNil(reader.readingNotice,context)
            }
        }
    }

    private func ready(_ reader: ReaderModel) async throws {
        try await wait { !reader.loading && !reader.busy && reader.position != nil }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<180 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("阅读操作未完成")
        throw ReaderError.message("Navigation timeout")
    }
}

@MainActor func auditFindMap(_ view: UIView) -> WKWebView? {
    if let web = view as? WKWebView, web.accessibilityIdentifier == "book-note-graph-viewport" { return web }
    return view.subviews.lazy.compactMap(auditFindMap).first
}

@MainActor func auditWait(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<180 {
        if try await condition() { return }
        try await Task.sleep(for:.milliseconds(100))
    }
    XCTFail("当前 iPad 界面未完成预期操作")
    throw ReaderError.message("iPad audit timeout")
}

@MainActor func auditReadyMap(_ view: UIView) async throws -> WKWebView {
    try await auditWait { auditFindMap(view) != nil }
    let web = try XCTUnwrap(auditFindMap(view))
    try await auditWait { try await web.callAsyncJavaScript("return window.bookMindMap?.inspect().ready || false",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
    return web
}

@MainActor func auditMapHasFocusedInput(_ web: WKWebView) async throws -> Bool {
    try await web.callAsyncJavaScript("return !!document.getElementById('input-box') && document.activeElement===document.getElementById('input-box')",arguments:[:],in:nil,contentWorld:.page) as? Bool == true
}

@MainActor final class LibraryDownloadAuditTests: XCTestCase {
    private func fixture() throws -> (ReaderModel,URL,LibraryBook,SavedConnection,URLSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let connection = SavedConnection(receiverID:UUID(),name:"合成 Mac",endpoint:"http://download-audit.local:8765",token:"download-fixture-token")
        let source = UUID()
        var book = LibraryBook(id:UUID(),title:"合成下载",author:"测试",filename:"")
        book.remoteBookID = source; book.remoteReceiverID = connection.receiverID
        reader.books.append(book); reader.save()
        let data = try Data(contentsOf:ReaderModel.resources.appendingPathComponent("QuietHours.epub"))
        var reply = Reply(ok:true,message:"合成图书")
        reply.libraryChunk = LibraryChunk(id:source,offset:0,total:data.count,data:data)
        DelayedLibraryProtocol.reply = reply
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DelayedLibraryProtocol.self]
        return (reader,root,book,connection,URLSession(configuration:config))
    }
    private func cleanup(_ reader: ReaderModel,_ root: URL) {
        reader.close(); reader.webView.stopLoading()
        reader.webView.configuration.userContentController.removeScriptMessageHandler(forName:"reader")
        try? FileManager.default.removeItem(at:root)
    }
    func testAuthenticatedDownloadIsCommittedAndOpensItsBook() async throws {
        let (reader,root,book,connection,session) = try fixture()
        defer { cleanup(reader,root) }
        await reader.openFromLibrary(book.id,connection:connection,session:session)
        XCTAssertEqual(reader.currentID,book.id)
        XCTAssertNil(reader.downloadingBook)
        XCTAssertEqual(reader.downloadProgress,1)
        XCTAssertTrue(reader.isDownloaded(try XCTUnwrap(reader.currentBook)))
        let disk = try LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first { $0.id == book.id }
        XCTAssertFalse(try XCTUnwrap(disk).filename.isEmpty)
    }
    func testPDFDownloadRendersAndRestoresItsPage() async throws {
        let (reader,root,legacy,connection,session) = try fixture()
        let original = reader.appearance
        reader.appearance.mode = .scroll
        defer {
            reader.appearance = original
            UserDefaults.standard.set(try? JSONEncoder().encode(original),forKey:"readerAppearance")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:BookCanvas(reader:reader))
        window.makeKeyAndVisible()
        defer { cleanup(reader,root); window.isHidden = true; previous?.makeKey() }

        let renderer = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:400,height:580))
        let data = renderer.pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("PDF page \(page)" as NSString).draw(at:CGPoint(x:50,y:100),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
            }
        }
        let remote = try XCTUnwrap(legacy.remoteBookID)
        let key = BookImportFile.fingerprint(data)
        XCTAssertTrue(reader.applyMacCatalog([.init(id:remote,title:"PDF 书",author:"测试",lastRead:Date(),progressKey:key,format:.pdf)],receiverID:connection.receiverID))
        var reply = Reply(ok:true,message:"PDF book")
        reply.libraryChunk = LibraryChunk(id:remote,offset:0,total:data.count,data:data)
        DelayedLibraryProtocol.reply = reply
        await reader.openFromLibrary(legacy.id,connection:connection,session:session)
        try await auditWait { !reader.loading && reader.nativeBookReader?.view.window != nil }
        let downloaded = try XCTUnwrap(reader.currentBook)
        XCTAssertEqual(downloaded.format, .pdf)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(downloaded.filename)), data)
        XCTAssertEqual(reader.snapshot?.supportsFractionalScroll, true)
        let scrollError = await reader.turn(.next,scrollLines:0.5)
        XCTAssertNil(scrollError)
        XCTAssertNotNil(reader.position?.viewportOffset)
        let last = PDFPageLocator.encode(2)
        XCTAssertTrue(reader.go(last))
        let view = try XCTUnwrap(reader.nativeBookReader?.view as? PDFView)
        try await auditWait { view.currentPage?.label == "3" }
        XCTAssertTrue(reader.toggleBookmark())

        let page = try XCTUnwrap(view.currentPage)
        let selection = try XCTUnwrap(page.selection(for:NSRange(location:0,length:page.numberOfCharacters)))
        view.setCurrentSelection(selection,animate:false)
        var selected = try XCTUnwrap(reader.nativeSelection)
        selected.color = .yellow
        reader.nativeBookReader?.clearSelection()
        reader.performSelectionAction("annotationChange",selection:selected,bookID:downloaded.id)
        XCTAssertEqual(reader.currentAnnotations.first?.quote, "PDF page 3")
        XCTAssertTrue(page.annotations.contains { $0.type == "Highlight" })

        reader.inlineInkToolsVisible = true
        reader.selectInkTool(.pen)
        try await auditWait { reader.inlineInk?.ready == true }
        let ink = try XCTUnwrap(reader.inlineInk)
        XCTAssertTrue(view.isInMarkupMode)
        XCTAssertEqual(ink.canvas.bounds.width,400,accuracy:1)
        let points = (0...20).map { index in
            PKStrokePoint(location:CGPoint(x:50 + index * 5,y:116),timeOffset:Double(index)/60,
                          size:CGSize(width:3,height:3),opacity:1,force:0.7,azimuth:0,altitude:1)
        }
        let stroke = PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date()))
        ink.canvas.drawing = PKDrawing(strokes:[stroke])
        ink.canvasViewDrawingDidChange(ink.canvas)
        XCTAssertTrue(ink.persist())
        XCTAssertEqual(reader.currentPageNotes.first?.anchor.locator,last)
        XCTAssertTrue(reader.currentPageNotes.first?.excerpt.contains("PDF page 3") == true)
        reader.selectInkTool(.reading)
        XCTAssertFalse(view.isInMarkupMode)

        reader.close()
        reader.open(downloaded.id)
        try await auditWait {
            guard !reader.loading, let view = reader.nativeBookReader?.view as? PDFView else { return false }
            return view.window != nil && view.currentPage?.label == "3"
        }
        XCTAssertEqual(reader.position?.locator,last)
        XCTAssertTrue(reader.isBookmarked)
        XCTAssertEqual(reader.currentAnnotations.first?.readingLocator,selected.readingLocator)
        XCTAssertEqual(reader.currentPageNotes.first?.anchor.locator,last)
        reader.selectInkTool(.pen)
        try await auditWait { reader.inlineInk?.ready == true }
        XCTAssertEqual(reader.inlineInk?.canvas.drawing.strokes.count,1)

        reader.selectInkTool(.reading)
        reader.setPDFTextLayout(true)
        func findReflowText(_ view: UIView) -> UITextView? {
            if view.accessibilityIdentifier == "pdf-reflow-text" { return view as? UITextView }
            return view.subviews.lazy.compactMap(findReflowText).first
        }
        try await auditWait { findReflowText(window) != nil }
        let text = try XCTUnwrap(findReflowText(window))
        XCTAssertEqual(text.text,"PDF page 3")
        XCTAssertNotNil(text.attributedText.attribute(.backgroundColor,at:0,effectiveRange:nil))
        text.selectedRange = NSRange(location:0,length:("PDF page 3" as NSString).length)
        text.delegate?.textViewDidChangeSelection?(text)
        XCTAssertEqual(reader.nativeSelection?.readingLocator,selected.readingLocator)
        reader.clearNativeSelection()

        reader.appearance.fontSize = 30
        try await auditWait {
            (text.attributedText.attribute(.font,at:0,effectiveRange:nil) as? UIFont)?.pointSize == 30
        }
        reader.setPDFTextLayout(false)
        XCTAssertEqual(reader.position?.locator,last)
        XCTAssertTrue(reader.isBookmarked)

    }
    func testCompletingDownloadDoesNotReplaceABookOpenedWhileItWasPending() async throws {
        let (reader,root,book,connection,session) = try fixture()
        defer { cleanup(reader,root) }
        let sample = try XCTUnwrap(reader.books.first)
        let task = Task { await reader.openFromLibrary(book.id,connection:connection,session:session) }
        try await auditWait { reader.downloadingBook == book.id }
        reader.open(sample.id)
        await task.value
        XCTAssertEqual(reader.currentID,sample.id,"A finished download must respect the user's newer reading choice")
        XCTAssertTrue(reader.isDownloaded(try XCTUnwrap(reader.books.first { $0.id == book.id })))
    }
    func testCancellingDownloadLeavesNoFalseDownloadOrError() async throws {
        let (reader,root,book,connection,session) = try fixture()
        defer { cleanup(reader,root) }
        let task = Task { await reader.openFromLibrary(book.id,connection:connection,session:session) }
        try await auditWait { reader.downloadingBook == book.id }
        task.cancel(); await task.value
        XCTAssertNil(reader.currentID); XCTAssertNil(reader.downloadingBook); XCTAssertNil(reader.error)
        XCTAssertEqual(reader.books.first { $0.id == book.id }?.filename,"")
    }
    func testMalformedDownloadChunkCannotCreateOrOpenABook() async throws {
        let (reader,root,book,connection,session) = try fixture()
        defer { cleanup(reader,root) }
        let chunk = try XCTUnwrap(DelayedLibraryProtocol.reply.libraryChunk)
        DelayedLibraryProtocol.reply.libraryChunk = .init(id:chunk.id,offset:1,total:chunk.total,data:chunk.data)
        await reader.openFromLibrary(book.id,connection:connection,session:session)
        XCTAssertNil(reader.currentID); XCTAssertNil(reader.downloadingBook)
        XCTAssertEqual(reader.books.first { $0.id == book.id }?.filename,"")
        XCTAssertNotNil(reader.error)
    }
    func testDownloadIndexFailureRetainsTheOriginalRecord() async throws {
        let (reader,root,book,connection,session) = try fixture()
        defer { cleanup(reader,root) }
        let index = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at:index)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        try Data("block atomic write".utf8).write(to:index.appendingPathComponent("blocker"))
        await reader.openFromLibrary(book.id,connection:connection,session:session)
        XCTAssertNil(reader.currentID); XCTAssertNil(reader.downloadingBook)
        XCTAssertEqual(reader.books.first { $0.id == book.id }?.filename,"")
        XCTAssertNotNil(reader.error)
    }
}

private final class DelayedLibraryProtocol: URLProtocol {
    static var reply = Reply(ok:true,message:"")
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "download-audit.local" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.reply
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = request.url else { return }
            let req = HTTPRequest(method:"GET",path:url.path,headers:["x-bookslide-nonce":request.value(forHTTPHeaderField:"x-bookslide-nonce") ?? ""])
            let response = RequestAuthentication.sign(HTTPResponse(200,reply),for:req,token:"download-fixture-token")
            guard let http = HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:response.extraHeaders) else { return }
            client?.urlProtocol(self,didReceive:http,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        delivery = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    override func stopLoading() { delivery?.cancel(); delivery = nil }
}
