import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import BookSlidePhone

@MainActor final class ReaderToolsTests: XCTestCase {
    func testCloseCancelsOpeningAndClearsReadingPresentations() async throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let id = try XCTUnwrap(reader.currentID)
        reader.open(id)
        let openingSession = reader.sessionID
        let note = ReaderAnnotation(cfi:"",quote:"关闭阅读测试",chapter:"示例",progress:0.2)
        let draft = ReaderAnnotationDraft(bookID:id,annotation:note)
        reader.showNoteGraph = true; reader.annotationDraft = draft
        reader.graphNoteID = note.id; reader.discussionNoteID = note.id
        reader.selectionDiscussion = draft; reader.selectionEntity = draft
        reader.showProgressSettings = true
        reader.close()
        XCTAssertNil(reader.currentID)
        XCTAssertNotEqual(reader.sessionID,openingSession)
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertFalse(reader.showProgressSettings)
        XCTAssertNil(reader.selectionDiscussion)
        XCTAssertNil(reader.selectionEntity)
        XCTAssertNil(reader.annotationDraft)
        XCTAssertNil(reader.graphNoteID)
        XCTAssertNil(reader.discussionNoteID)
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertNil(reader.currentID,"An EPUB open completing after Close must not return to reading")
        XCTAssertFalse(reader.loading)
    }
    func testOpeningNotesReplacesTheSelectedTextNodePanel() throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let note = ReaderAnnotation(cfi:"",quote:"选文中的概念",chapter:"示例",progress:0.2,note:"已有笔记")
        let id = try XCTUnwrap(reader.currentID)
        XCTAssertTrue(reader.saveAnnotation(note,bookID:id))
        reader.selectionEntity = ReaderAnnotationDraft(bookID:id,annotation:note)
        reader.openNoteGraph(noteID:note.id)
        XCTAssertNil(reader.selectionEntity,"The previous selection editor must not cover the requested note")
        XCTAssertTrue(reader.showNoteGraph)
        XCTAssertEqual(reader.graphNoteID,note.id)
    }
    func testMissingKnowledgeBookDoesNotOpenTheCurrentBooksGraph() throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let id = reader.currentID
        reader.openKnowledgeWorkspace(bookID:UUID())
        XCTAssertEqual(reader.currentID,id)
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertNotNil(reader.error)
    }
    func testBlockedGraphSearchDoesNotSelectAnItemBehindTheCurrentPanel() async throws {
        let (reader,root) = try fixture()
        defer { reader.readingSelectionTask?.cancel(); try? FileManager.default.removeItem(at:root) }
        let note = ReaderAnnotation(cfi:"",quote:"搜索结果",chapter:"示例",progress:0.2,note:"结果中的笔记")
        let id = try XCTUnwrap(reader.currentID)
        XCTAssertTrue(reader.saveAnnotation(note,bookID:id))
        reader.busy = true
        reader.openReadingSearchHit(.init(bookID:id,bookTitle:"示例",item:.node(.init(.note,note.id)),title:"结果",text:"",kind:.note))
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertNil(reader.selectedReadingItem)
        XCTAssertNil(reader.readingSelectionTask)
        XCTAssertFalse(reader.showNoteGraph)
    }
    func testClosingAnotherOverlayKeepsSelectedTextInputShielded() async throws {
        let (reader,root) = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let note = ReaderAnnotation(cfi:"",quote:"仍在编辑的节点",chapter:"示例",progress:0.2)
        reader.selectionEntity = .init(bookID:try XCTUnwrap(reader.currentID),annotation:note)
        window.rootViewController = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        try await Task.sleep(for:.milliseconds(500))
        reader.showProgressSettings = true
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertTrue(reader.inlineInkObscured)
        reader.showProgressSettings = false
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertNotNil(reader.selectionEntity)
        XCTAssertTrue(reader.inlineInkObscured,"Dismissing settings must not enable Pencil beneath another open editor")
    }
    func testMalformedEnginePositionIsRejectedWithoutChangingReadingState() throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        for value: Any in [NSNull(),"not a position",[1,2,3],["progress":0.5]] {
            XCTAssertFalse(reader.acceptPosition(value))
            XCTAssertNil(reader.position)
        }
    }
    func testIPadTapsAndNonHorizontalDragsNeverTurnPages() {
        for scrolling in [false,true] {
            for x in [CGFloat(0),20,417,814,834] {
                XCTAssertNil(ReaderPageGesture.tap(at:CGPoint(x:x,y:200),width:834,scrolling:scrolling,isPad:true))
            }
        }
        for translation in [CGPoint(x:0,y:180),CGPoint(x:0,y:-180),CGPoint(x:40,y:0),CGPoint(x:90,y:90)] {
            XCTAssertNil(ReaderPageGesture.swipe(translation:translation,width:834,elapsed:0.3,scrolling:false,isPad:true))
        }
        XCTAssertEqual(ReaderPageGesture.swipe(translation:CGPoint(x:-140,y:10),width:834,elapsed:0.3,scrolling:false,isPad:true),.next)
        XCTAssertEqual(ReaderPageGesture.swipe(translation:CGPoint(x:140,y:10),width:834,elapsed:0.3,scrolling:false,isPad:true),.previous)
        XCTAssertNil(ReaderPageGesture.swipe(translation:CGPoint(x:-140,y:0),width:834,elapsed:0.3,scrolling:true,isPad:true))
        XCTAssertNil(ReaderPageGesture.swipe(translation:CGPoint(x:-140,y:0),width:834,elapsed:1.5,scrolling:false,isPad:true))
        XCTAssertEqual(ReaderPageGesture.tap(at:CGPoint(x:20,y:200),width:390,scrolling:false,isPad:false),.previous)
    }
    func testReadingControlsHideOnUserScrollButStayForProgrammaticReflow() throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        var value: [String:Any] = ["mode":"scroll","locator":"epubcfi(/6/2!/4/2/1:0)","chapter":"示例","page":1,"pageCount":10,"progress":0.2,"canGoNext":true,"canGoPrevious":false,"viewportOffset":40,"userDriven":false]
        XCTAssertTrue(reader.acceptPosition(value))
        reader.readingControlsVisible = true
        value["viewportOffset"] = 60
        XCTAssertTrue(reader.acceptPosition(value))
        XCTAssertTrue(reader.readingControlsVisible)
        value["viewportOffset"] = 80; value["userDriven"] = true
        XCTAssertTrue(reader.acceptPosition(value))
        XCTAssertFalse(reader.readingControlsVisible)
    }
    private func fixture() throws -> (ReaderModel,URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.currentID = try XCTUnwrap(reader.books.first?.id)
        reader.appearance = ReaderAppearance(); reader.appearance.theme = "light"
        return (reader,root)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("阅读工具没有完成当前操作")
        throw ReaderError.message("Reader tool timeout")
    }
    func testIPadInputFocusAndNotesSimultaneousDismissalKeepsReadingPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene), field = UITextField()
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader))
            .overlay(alignment:.topLeading) { PositionAuditInput(field:field).frame(width:200,height:44) })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { field.resignFirstResponder(); reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance = ReaderAppearance(); reader.appearance.fontSize = 32; reader.appearance.mode = .paged
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        XCTAssertTrue(reader.go("chapter1.xhtml")); try await Task.sleep(for:.milliseconds(600))
        _ = await reader.turn(.next); try await Task.sleep(for:.milliseconds(400))
        let before = try XCTUnwrap(reader.position)
        func inspect(_ label: String) async throws {
            let state = try await reader.webView.callAsyncJavaScript("""
            const position=await reader.settledPosition();
            return JSON.stringify({position,innerHeight,innerWidth,visualHeight:visualViewport?.height,body:document.body.getBoundingClientRect().toJSON(),container:document.querySelector('.epub-container')?.getBoundingClientRect().toJSON(),frames:[...document.querySelectorAll('iframe')].map(f=>({rect:f.getBoundingClientRect().toJSON(),height:f.contentDocument.body.style.height}))});
            """,arguments:[:],in:nil,contentWorld:.page)
            print("KEYBOARD_AUDIT \(label) native=\(reader.webView.bounds) inset=\(reader.webView.scrollView.contentInset) offset=\(reader.webView.scrollView.contentOffset) \(state ?? "nil")")
        }
        try await inspect("before")
        reader.openNoteGraph(); try await Task.sleep(for:.milliseconds(700)); try await inspect("notes")
        let height = reader.webView.bounds.height
        XCTAssertTrue(field.becomeFirstResponder())
        // Hosted tests can have a hardware keyboard attached. Verify native
        // input focus here; the UI walkthrough asserts a real software keyboard.
        try await waitUntil { field.isFirstResponder }
        XCTAssertEqual(reader.webView.bounds.height,height,accuracy:1,"The real keyboard must not resize the book viewport")
        try await Task.sleep(for:.milliseconds(500)); try await inspect("keyboard")
        field.resignFirstResponder(); reader.showNoteGraph = false
        try await Task.sleep(for:.milliseconds(900)); try await inspect("dismissed")
        if let p = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) { reader.acceptPosition(p) }
        XCTAssertEqual(reader.position?.locator,before.locator)
        XCTAssertEqual(reader.position?.viewport?.point?.y ?? -1,before.viewport?.point?.y ?? -2,accuracy:1)
    }
    func testNativeScrollAfterReflowBecomesTheReadingCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance = ReaderAppearance(); reader.appearance.mode = .scroll; reader.appearance.fontSize = 32
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        let resource = try XCTUnwrap(Bundle.main.url(forResource:"QuietHours",withExtension:"epub",subdirectory:"Reader"))
        let fixture = try await reader.webView.callAsyncJavaScript("""
            const zip=await JSZip.loadAsync(data,{base64:true});
            const source=await zip.file('EPUB/chapter1.xhtml').async('string');
            const text=Array.from({length:200},(_,i)=>`第${i}句：阅读需要一点耐心。滚动后应当继续刚才的段落。`).join('');
            zip.file('EPUB/chapter1.xhtml',source.slice(0,source.indexOf('<body>')+6)+`<p>${text}</p>`+source.slice(source.indexOf('</body>')));
            return await zip.generateAsync({type:'base64'});
            """,arguments:["data":try Data(contentsOf:resource).base64EncodedString()],in:nil,contentWorld:.page)
        let book = try XCTUnwrap(reader.currentBook)
        reader.close()
        try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fixture as? String))).write(to:root.appendingPathComponent(book.filename))
        reader.open(book.id); try await waitUntil { !reader.loading && reader.position != nil }
        func settle() async throws {
            try await Task.sleep(for:.milliseconds(700))
            if let value = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) { reader.acceptPosition(value) }
        }
        XCTAssertTrue(reader.go("chapter1.xhtml")); try await settle()
        reader.openNoteGraph(); try await settle()
        let before = try XCTUnwrap(reader.position?.viewport?.locator)
        // Native iPad gestures explicitly notify the trusted host: the EPUB's
        // script-disabled frame cannot deliver its own DOM touch events. Move
        // the actual container without a synthetic wheel event or turn API.
        _ = try await reader.webView.callAsyncJavaScript("""
            reader.beginReadingInput();
            const container=document.querySelector('.epub-container');
            container.scrollTop+=container.clientHeight*1.5;
            container.dispatchEvent(new Event('scroll',{bubbles:true}));
            return container.scrollTop;
            """,arguments:[:],in:nil,contentWorld:.page)
        try await settle()
        let moved = try XCTUnwrap(reader.position)
        XCTAssertTrue(moved.userDriven == true,"Host-document scrolling must be recorded as reading activity")
        XCTAssertNotEqual(moved.viewport?.locator,before,"A reflow anchor must not stay pinned after native scrolling")
        let visible = try await reader.webView.callAsyncJavaScript("""
            const frame=[...document.querySelectorAll('iframe')].find(f=>f.contentDocument.body.textContent.includes('第199句'));
            if (!frame) return false;
            const range=new ePub.CFI(locator).toRange(frame.contentDocument);
            if (range.startContainer.nodeType===3) range.setEnd(range.startContainer,Math.min(range.startContainer.length,range.startOffset+1));
            const rect=range.getBoundingClientRect(), box=frame.getBoundingClientRect(), viewport=document.querySelector('.epub-container').getBoundingClientRect();
            return box.top+rect.bottom>viewport.top && box.top+rect.top<viewport.bottom && box.left+rect.right>viewport.left && box.left+rect.left<viewport.right;
            """,arguments:["locator":try XCTUnwrap(moved.viewport?.locator)],in:nil,contentWorld:.page)
        XCTAssertEqual(visible as? Bool,true,"The saved character must intersect the visible viewport, including a partially visible first line")
        reader.showNoteGraph = false; try await settle()
        XCTAssertEqual(reader.position?.viewport?.locator,moved.viewport?.locator,"Closing notes must not replay a checkpoint from before the scroll")
        XCTAssertEqual(reader.currentBook?.readingViewport?.locator,moved.viewport?.locator)
        let settled = try XCTUnwrap(reader.position)
        let quiet = try await reader.webView.callAsyncJavaScript("""
            const container=document.querySelector('.epub-container'), before=container.scrollTop;
            let scrollEvents=0;
            const observe=()=>scrollEvents++;
            container.addEventListener('scroll',observe);
            await reader.restoreReadingPosition(locator,viewport);
            const position=await reader.restoreReadingPosition(locator,viewport);
            await new Promise(resolve=>setTimeout(resolve,150));
            container.removeEventListener('scroll',observe);
            return {scrollEvents,before,after:container.scrollTop,userDriven:position.userDriven};
            """,arguments:["locator":settled.locator,"viewport":try reader.dictionary(try XCTUnwrap(settled.viewport))],in:nil,contentWorld:.page)
        let result = try XCTUnwrap(quiet as? [String:Any])
        XCTAssertEqual(result["scrollEvents"] as? Int,0,"Restoring an already-correct layout must not scroll to a paragraph boundary and back")
        XCTAssertEqual(result["before"] as? Double,result["after"] as? Double)
        XCTAssertEqual(result["userDriven"] as? Bool,false,"Layout restoration must not masquerade as a user navigation")
    }
    func testIPadOpeningNotesKeepsTheActualVisiblePassageWithoutReadingInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance = ReaderAppearance(); reader.appearance.fontSize = 32
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        let resource = try XCTUnwrap(Bundle.main.url(forResource:"QuietHours",withExtension:"epub",subdirectory:"Reader"))
        let fixture = try await reader.webView.callAsyncJavaScript("""
            const zip=await JSZip.loadAsync(data,{base64:true});
            const source=await zip.file('EPUB/chapter1.xhtml').async('string');
            const text=Array.from({length:200},(_,i)=>`第${i}句：打开笔记时没有操作书页，原先正在阅读的文字必须留在眼前。`).join('');
            zip.file('EPUB/chapter1.xhtml',source.slice(0,source.indexOf('<body>')+6)+`<p>${text}</p>`+source.slice(source.indexOf('</body>')));
            const original=ePub;
            window.ePub=(...args)=>{const book=original(...args),render=book.renderTo.bind(book);book.renderTo=(...args)=>window.positionAuditRendition=render(...args);return book;};
            Object.assign(window.ePub,original);
            return await zip.generateAsync({type:'base64'});
            """,arguments:["data":try Data(contentsOf:resource).base64EncodedString()],in:nil,contentWorld:.page)
        let book = try XCTUnwrap(reader.currentBook); reader.close()
        try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fixture as? String))).write(to:root.appendingPathComponent(book.filename))
        reader.open(book.id); try await waitUntil { !reader.loading && reader.position != nil }
        func settle() async throws {
            try await Task.sleep(for:.milliseconds(1000))
            if let value = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) { reader.acceptPosition(value) }
        }
        func point(_ position: EnginePosition) async throws -> [String:Double] {
            let result = try await reader.webView.callAsyncJavaScript("""
                const c=positionAuditRendition.getContents().find(c=>c.sectionIndex===new ePub.CFI(locator).spinePos);
                if(!c)return {x:-10000,y:-10000};
                const f=c.document.defaultView.frameElement.getBoundingClientRect(),r=c.range(locator).getBoundingClientRect();
                return {x:f.left+r.left,y:f.top+r.top,width:innerWidth,height:innerHeight};
                """,arguments:["locator":position.viewport?.locator ?? position.locator],in:nil,contentWorld:.page)
            return try XCTUnwrap(result as? [String:Double])
        }
        for mode in [ReadingMode.scroll,.paged] {
            reader.appearance.mode = mode; try await settle()
            XCTAssertTrue(reader.go("chapter1.xhtml")); try await settle()
            let chapterStart = try XCTUnwrap(reader.position)
            _ = await reader.turn(.next); try await settle()
            if mode == .scroll { _ = await reader.turn(.previous,scrollLines:0.25); try await settle() }
            let before = try XCTUnwrap(reader.position), original = try await point(before)
            for (lateReflow,staleNativePosition) in [(false,false),(true,false),(false,true)] {
                if staleNativePosition { reader.position = chapterStart }
                if lateReflow {
                    _ = try await reader.webView.callAsyncJavaScript("""
                        window.addEventListener('resize',()=>setTimeout(async()=>{
                            await reader.settledPosition(); await positionAuditRendition.display('chapter1.xhtml');
                            window.positionAuditLateReflow=true;
                        },0),{once:true}); return true;
                        """,arguments:[:],in:nil,contentWorld:.page)
                }
                reader.openNoteGraph(); try await settle()
                let opened = try await point(before)
                if lateReflow {
                    let fired = try await reader.webView.callAsyncJavaScript("return window.positionAuditLateReflow === true",arguments:[:],in:nil,contentWorld:.page)
                    XCTAssertEqual(fired as? Bool,true,"The delayed renderer relocation must execute")
                }
                print("NO_INPUT_OPEN \(mode) late=\(lateReflow) staleCache=\(staleNativePosition) original=\(original) opened=\(opened)")
                if mode == .scroll { XCTAssertEqual(opened["y"] ?? -1,original["y"] ?? -2,accuracy:1,"Opening notes must preserve the actual visible line, not just the saved locator") }
                else {
                    XCTAssertGreaterThanOrEqual(opened["x"] ?? -10000,0)
                    XCTAssertLessThan(opened["x"] ?? 10000,opened["width"] ?? 0,"The original character must stay on the visible page")
                }
                reader.showNoteGraph = false; try await settle()
                let closed = try await point(before)
                XCTAssertEqual(closed["x"] ?? -1,original["x"] ?? -2,accuracy:1)
                XCTAssertEqual(closed["y"] ?? -1,original["y"] ?? -2,accuracy:1,"Closing without reading input must restore the exact original text position")
            }
        }
    }
    func testIPadAddingSelectedNodeReturnsToTheSameReadingPassage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance = ReaderAppearance(); reader.appearance.fontSize = 32
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        let resource = try XCTUnwrap(Bundle.main.url(forResource:"QuietHours",withExtension:"epub",subdirectory:"Reader"))
        let data = try Data(contentsOf:resource).base64EncodedString()
        let fixture = try await reader.webView.callAsyncJavaScript("""
            const zip=await JSZip.loadAsync(data,{base64:true});
            const source=await zip.file('EPUB/chapter1.xhtml').async('string');
            const text=Array.from({length:120},(_,i)=>`第${i}句：阅读需要一点耐心，把想法留在原文中的位置。记录节点以后，应当继续阅读刚才的段落。`).join('');
            zip.file('EPUB/chapter1.xhtml',source.slice(0,source.indexOf('<body>')+6)+`<p>${text}</p>`+source.slice(source.indexOf('</body>')));
            const originalEPub=ePub;
            window.ePub=(...args)=>{
              const book=originalEPub(...args), render=book.renderTo.bind(book);
              book.renderTo=(...args)=>{ window.nodeAuditRendition=render(...args); return window.nodeAuditRendition; };
              return book;
            };
            Object.assign(window.ePub,originalEPub);
            return await zip.generateAsync({type:'base64'});
            """,arguments:["data":data],in:nil,contentWorld:.page)
        let book = try XCTUnwrap(reader.currentBook)
        reader.close()
        try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fixture as? String))).write(to:root.appendingPathComponent(book.filename))
        reader.open(book.id)
        try await waitUntil { !reader.loading && reader.position != nil }
        func settle() async throws {
            try await Task.sleep(for:.milliseconds(700))
            if let value = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) { reader.acceptPosition(value) }
        }
        func visiblePoint(_ position: EnginePosition) async throws -> [String:Double] {
            let value = try await reader.webView.callAsyncJavaScript("""
                const contents=nodeAuditRendition.getContents().find(c=>c.sectionIndex===new ePub.CFI(locator).spinePos);
                const frame=contents.document.defaultView.frameElement.getBoundingClientRect(), range=contents.range(locator).getBoundingClientRect();
                return {x:frame.left+range.left,y:frame.top+range.top};
                """,arguments:["locator":position.viewport?.locator ?? position.locator],in:nil,contentWorld:.page)
            return try XCTUnwrap(value as? [String:Double])
        }
        func fields(_ view: UIView) -> [UITextField] { (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        for (mode,lateRelocation) in [(ReadingMode.scroll,false),(.scroll,true),(.paged,false),(.paged,true)] {
            reader.appearance.mode = mode; try await settle()
            XCTAssertTrue(reader.go("chapter1.xhtml")); try await settle()
            _ = await reader.turn(.next); try await settle()
            let before = try XCTUnwrap(reader.position)
            XCTAssertGreaterThan(before.page,1,"The fixture must start beyond the chapter's first page")
            let value = try await reader.webView.callAsyncJavaScript("""
                for (const frame of document.querySelectorAll('iframe')) {
                  const doc=frame.contentDocument, bounds=frame.getBoundingClientRect();
                  for (const y of [innerHeight/3,innerHeight/2]) {
                    const range=doc.caretRangeFromPoint(innerWidth/2-bounds.left,y-bounds.top);
                    if (!range || range.startContainer.nodeType!==3 || range.startOffset+2>range.startContainer.length) continue;
                    range.setEnd(range.startContainer,range.startOffset+2);
                    const selection=doc.defaultView.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                    const context=reader.annotationContext(); if (context) return context;
                  }
                }
                return null;
                """,arguments:[:],in:nil,contentWorld:.page)
            let context = try XCTUnwrap(value as? [String:Any])
            let web = try XCTUnwrap(reader.webView as? ReaderTextWebView)
            web.performAnnotation("annotationEntity",context:context)
            try await waitUntil { reader.showNoteGraph && reader.graphNoteID != nil }
            let selectedID = try XCTUnwrap(reader.graphNoteID)
            let annotation = try XCTUnwrap(reader.graphAnnotations.first { $0.id == selectedID })
            let draft = ReaderAnnotationDraft(bookID:try XCTUnwrap(reader.currentID),annotation:annotation)
            try await settle()
            XCTAssertEqual(reader.position?.viewport?.locator,before.viewport?.locator,"Opening the note/node editor must preserve the visible passage")
            if let field = fields(host.view).first(where:{ ["名称（可选）","为这段原文命名","名称"].contains($0.placeholder ?? "") }) {
                XCTAssertTrue(field.becomeFirstResponder()); field.insertText("阅读")
            } else {
                func graph(_ view: UIView) -> WKWebView? {
                    if let web = view as? WKWebView, web.accessibilityIdentifier == "book-note-graph-viewport" { return web }
                    return view.subviews.lazy.compactMap { graph($0) }.first
                }
                let canvas = try XCTUnwrap(graph(host.view)), token = reader.mindMapToken(.init(.note,selectedID))
                var ready = false
                for _ in 0..<150 {
                    ready = (try? await canvas.callAsyncJavaScript("const state=window.bookMindMap?.inspect(); const find=n=>n.id===token || (n.children || []).some(find); return !!state?.ready && find(state.data.nodeData)",arguments:["token":token],in:nil,contentWorld:.page)) as? Bool == true
                    if ready { break }; try await Task.sleep(for:.milliseconds(100))
                }
                XCTAssertTrue(ready,"The active selection must be visible on the canvas")
                let focused = try await canvas.callAsyncJavaScript("""
                window.bookMindMap.command({id:request,name:'edit',target:token});
                const input=document.getElementById('input-box');if(!input)return false;
                input.focus();input.textContent='阅读';input.dispatchEvent(new Event('input',{bubbles:true}));return true;
                """,arguments:["token":token,"request":UUID().uuidString],in:nil,contentWorld:.page)
                XCTAssertEqual(focused as? Bool,true)
            }
            try await Task.sleep(for:.milliseconds(400))
            XCTAssertEqual(reader.position?.viewport?.locator,before.viewport?.locator,"Focusing the node name must preserve the visible passage")
            if !lateRelocation {
                let image = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
                let attachment = XCTAttachment(image:image); attachment.name = "iPad-node-entry-\(mode)"; attachment.lifetime = .keepAlways; add(attachment)
            }
            let name = "自定义阅读概念"
            let entity = try XCTUnwrap(reader.recordSelectedEntity(name:name,kind:.concept,source:draft.annotation,bookID:draft.bookID))
            XCTAssertEqual(reader.bookNotesIndex.entities.first(where:{ $0.id == entity })?.name,name)
            XCTAssertEqual(reader.currentAnnotations.first(where:{ $0.id == draft.id })?.quote,draft.annotation.quote)
            reader.showNoteGraph = true; reader.selectionEntity = nil; reader.selectionDiscussion = nil
            reader.selectReadingItem(.node(.init(.entity,entity.uuidString)))
            try await settle()
            var expected = before
            if mode == .scroll && !lateRelocation {
                _ = await reader.turn(.next); try await settle()
                expected = try XCTUnwrap(reader.position)
                XCTAssertNotEqual(expected.viewport?.locator,before.viewport?.locator,"Reading beside the node editor must advance the return point")
            }
            if lateRelocation {
                // EPUB.js can enqueue a stale chapter-start display during
                // closing. Deliver it after the ordinary viewport restore,
                // while the companion's closing animation is still running.
                let original = try XCTUnwrap(before.viewport?.point)
                _ = try await reader.webView.callAsyncJavaScript("""
                    window.nodeAuditLateRelocated=false; window.nodeAuditMoved=false;
                    window.addEventListener('resize',()=>setTimeout(async()=>{
                      await reader.settledPosition();
                      await nodeAuditRendition.display('chapter1.xhtml');
                      const contents=nodeAuditRendition.getContents().find(c=>c.sectionIndex===new ePub.CFI(locator).spinePos);
                      const frame=contents.document.defaultView.frameElement.getBoundingClientRect(), range=contents.range(locator).getBoundingClientRect();
                      window.nodeAuditMoved=Math.abs(frame.left+range.left-x)>1 || Math.abs(frame.top+range.top-y)>1;
                      window.nodeAuditLateRelocated=true;
                    },0),{once:true});
                    return true;
                    """,arguments:["locator":before.viewport?.locator ?? before.locator,"x":original.x,"y":original.y],in:nil,contentWorld:.page)
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)
            reader.showNoteGraph = false
            try await settle()
            let after = try XCTUnwrap(reader.position)
            if lateRelocation {
                let relocated = try await reader.webView.callAsyncJavaScript("return nodeAuditLateRelocated && nodeAuditMoved",arguments:[:],in:nil,contentWorld:.page)
                XCTAssertEqual(relocated as? Bool,true,"The delayed renderer relocation must actually move the visible text")
            }
            XCTAssertEqual(after.locator,expected.locator,"Adding a node must return to the current passage")
            XCTAssertEqual(after.viewport?.locator,expected.viewport?.locator)
            XCTAssertEqual(reader.currentBook?.locator,expected.locator,"The node editor must not persist the chapter's first page")
            if mode == .paged || lateRelocation {
                XCTAssertEqual(after.viewport?.point?.y ?? -1,expected.viewport?.point?.y ?? -2,accuracy:1)
                let actual = try await visiblePoint(expected)
                XCTAssertEqual(actual["x"] ?? -1,expected.viewport?.point?.x ?? -2,accuracy:1)
                XCTAssertEqual(actual["y"] ?? -1,expected.viewport?.point?.y ?? -2,accuracy:1,"Returning must restore visible text, not only cached position metadata")
            }
        }
    }
    func testIPadPagedMarginRoundTripKeepsVisibleGlyph() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance = ReaderAppearance(); reader.appearance.fontSize = 32; reader.appearance.mode = .paged
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        XCTAssertTrue(reader.go("chapter1.xhtml"))
        try await Task.sleep(for:.milliseconds(700)); _ = await reader.turn(.next)
        try await Task.sleep(for:.milliseconds(500))
        let before = try XCTUnwrap(reader.position)
        func glyph() async throws -> String {
            try await reader.webView.callAsyncJavaScript("""
            return JSON.stringify([...document.querySelectorAll('iframe')].filter(f=>f.contentDocument.title===chapter).map(f=>{
              const d=f.contentDocument,r=new ePub.CFI(cfi).toRange(d),caret=r.getBoundingClientRect().toJSON();
              r.setEnd(r.startContainer,Math.min(r.startContainer.length,r.startOffset+1));
              const glyph=r.getBoundingClientRect().toJSON(),p=d.defaultView.getComputedStyle(r.startContainer.parentElement),body=d.defaultView.getComputedStyle(d.body);
              return {caret,glyph,frame:f.getBoundingClientRect().toJSON(),indent:p.textIndent,padding:body.padding,columnWidth:body.columnWidth,gap:body.columnGap};
            }));
            """,arguments:["cfi":before.locator,"chapter":before.chapter],in:nil,contentWorld:.page) as? String ?? ""
        }
        let originalGlyph = try await glyph()
        reader.appearance.margin = 96
        try await Task.sleep(for:.milliseconds(900))
        reader.appearance.margin = 32
        try await Task.sleep(for:.milliseconds(900))
        if let p = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) { reader.acceptPosition(p) }
        print("PAGED_MARGIN_BEFORE \(originalGlyph)")
        print("PAGED_MARGIN_AFTER \(try await glyph())")
        XCTAssertEqual(reader.position?.locator,before.locator)
        XCTAssertEqual(reader.position?.viewport?.point?.x ?? -1,before.viewport?.point?.x ?? -2,accuracy:1)
    }
    func testIPadReadingPositionSurvivesSettingsInputFocusRotationBookmarksAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let field = UITextField()
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader))
            .overlay(alignment:.topLeading) { PositionAuditInput(field:field).frame(width:200,height:44) })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            reader.close(); window.isHidden = true; previous?.makeKey()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:.portrait))
            try? FileManager.default.removeItem(at:root)
        }
        let id = try XCTUnwrap(reader.books.first?.id)
        reader.appearance = ReaderAppearance(); reader.appearance.fontSize = 32
        reader.open(id)
        try await waitUntil { !reader.loading && reader.position != nil }
        func settle() async throws {
            try await Task.sleep(for:.milliseconds(700))
            try await waitUntil { !reader.busy && !reader.loading }
            if let p = try await reader.webView.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) { reader.acceptPosition(p) }
            try await Task.sleep(for:.milliseconds(200))
        }
        func assertPosition(_ before: EnginePosition,_ operation: String,file: StaticString = #filePath,line: UInt = #line) throws {
            let after = try XCTUnwrap(reader.position,file:file,line:line)
            XCTAssertEqual(after.locator,before.locator,operation,file:file,line:line)
            if let a = after.viewport?.point, let b = before.viewport?.point {
                XCTAssertEqual(a.x,b.x,accuracy:1,operation,file:file,line:line)
                XCTAssertEqual(a.y,b.y,accuracy:1,operation,file:file,line:line)
            } else { XCTFail("Missing durable viewport: " + operation,file:file,line:line) }
            XCTAssertEqual(reader.currentBook?.locator,before.locator,operation,file:file,line:line)
        }
        for mode in [ReadingMode.scroll,.paged] {
            reader.appearance.mode = mode
            try await settle()
            XCTAssertTrue(reader.go("chapter1.xhtml")); try await settle()
            _ = await reader.turn(.next)
            if mode == .scroll { _ = await reader.turn(.previous,scrollLines:0.25) }
            try await settle()
            let before = try XCTUnwrap(reader.position), baseline = reader.appearance
            var variants = [ReaderAppearance]()
            var v = baseline; v.theme = "night"; variants.append(v)
            v = baseline; v.fontSize = 44; variants.append(v)
            v = baseline; v.font = "pingfang"; variants.append(v)
            v = baseline; v.font = "publisher"; variants.append(v)
            v = baseline; v.lineHeight = 2; variants.append(v)
            v = baseline; v.margin = 96; variants.append(v)
            v = baseline; v.mode = mode == .scroll ? .paged : .scroll; variants.append(v)
            for variant in variants {
                reader.appearance = variant; try await settle()
                reader.appearance = baseline; try await settle()
                print("POSITION_AUDIT mode=\(mode) variant=\(variant)")
                try assertPosition(before,"Typography/theme/mode round trip: \(variant)")
            }
            // Cover native input focus with either hardware or software input.
            reader.openNoteGraph(); try await settle()
            let heightBeforeKeyboard = reader.webView.bounds.height
            XCTAssertTrue(field.becomeFirstResponder())
            try await waitUntil { field.isFirstResponder }
            XCTAssertEqual(reader.webView.bounds.height,heightBeforeKeyboard,accuracy:1)
            try await Task.sleep(for:.milliseconds(500))
            field.resignFirstResponder()
            reader.showNoteGraph = false; try await settle()
            try assertPosition(before,"Notes and native keyboard dismissal")
            if !reader.isBookmarked { XCTAssertTrue(reader.toggleBookmark()) }
            let bookmark = try XCTUnwrap(reader.currentBook?.bookmarks.first { $0.id == before.locator })
            XCTAssertTrue(reader.go("chapter2.xhtml")); try await settle()
            XCTAssertTrue(reader.go(bookmark.id,viewport:bookmark.viewport)); try await settle()
            try assertPosition(before,"Bookmark returns with its viewport")
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:.landscapeLeft))
            try await Task.sleep(for:.milliseconds(1000))
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:.portrait))
            try await Task.sleep(for:.milliseconds(1000)); try await settle()
            try assertPosition(before,"Physical iPad orientation round trip")
            let image = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "Position-audit-\(mode)-keyboard-settings-rotation"; attachment.lifetime = .keepAlways; add(attachment)
            reader.close(); reader.open(id)
            try await waitUntil { !reader.loading && reader.position != nil }; try await settle()
            try assertPosition(before,"Close and reopen from the on-disk viewport")
            let saved = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first { $0.id == id })
            XCTAssertEqual(saved.readingViewport?.point?.y,reader.position?.viewport?.point?.y)
        }
    }
    func testResetTypographyPreservesThemeAndReadingMode() throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        reader.appearance.theme = "night"; reader.appearance.mode = .paged
        reader.appearance.fontSize = 32; reader.appearance.margin = 80; reader.appearance.font = "serif"; reader.appearance.lineHeight = 2
        reader.resetReaderTypography()
        XCTAssertEqual(reader.appearance.theme,"night"); XCTAssertEqual(reader.appearance.mode,.paged)
        XCTAssertEqual(reader.appearance.fontSize,ReaderAppearance().fontSize)
        XCTAssertEqual(reader.appearance.margin,ReaderAppearance().margin)
        XCTAssertEqual(reader.appearance.lineHeight,ReaderAppearance().lineHeight)
    }
    func testBookmarkRemovalUndoAndFailedSavePreserveVisibleAndStoredState() throws {
        let (reader,root) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let first = ReaderBookmark(id:"epubcfi(/6/2!/4/2/1:0)",title:"第一章",progress:0.2)
        let second = ReaderBookmark(id:"epubcfi(/6/4!/4/2/1:0)",title:"第二章",progress:0.5)
        XCTAssertTrue(reader.setReaderBookmark(first,present:true))
        XCTAssertTrue(reader.setReaderBookmark(second,present:true))
        XCTAssertTrue(reader.setReaderBookmark(first,present:false))
        XCTAssertEqual(reader.currentBook?.bookmarks.map(\.id),[second.id])
        XCTAssertTrue(reader.setReaderBookmark(first,present:true))
        XCTAssertTrue(reader.setReaderBookmark(first,present:true))
        let saved = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self))
        XCTAssertEqual(saved.value.first?.bookmarks.count,2)
        try FileManager.default.removeItem(at:root)
        try Data("blocked".utf8).write(to:root)
        XCTAssertFalse(reader.setReaderBookmark(first,present:false))
        XCTAssertEqual(reader.currentBook?.bookmarks.count,2)
        XCTAssertNotNil(reader.error)
    }
    func testTypingSearchAutomaticallyRunsAndClearCancelsStaleResults() async throws {
        let (reader,root) = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIViewController(); host.view.addSubview(reader.webView)
        reader.webView.frame = CGRect(x:0,y:0,width:600,height:800)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let id = try XCTUnwrap(reader.currentID); reader.currentID = nil; reader.open(id)
        try await waitUntil { !reader.loading && reader.position != nil }
        let search = ReaderSearchController(reader:reader)
        search.query = "阅读"
        XCTAssertTrue(search.waiting)
        try await waitUntil { !reader.results.isEmpty }
        XCTAssertFalse(search.waiting)
        search.query = "这几个字在本书中找不到"; search.submit()
        search.query = "时间"
        try await waitUntil { !search.waiting && !reader.searching && !reader.results.isEmpty }
        XCTAssertTrue(reader.results.allSatisfy { $0.title.contains("时间") })
        search.query = ""
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(reader.searchState,.idle); XCTAssertTrue(reader.results.isEmpty)
        reader.busy = true
        XCTAssertFalse(reader.go("chapter.xhtml")); XCTAssertFalse(reader.seek(0.5))
        reader.busy = false
        XCTAssertFalse(reader.seek(.nan)); XCTAssertFalse(reader.seek(1.2))
    }
    func testReadingPanelsRenderWithCurrentChapterBookmarksAndDraft() async throws {
        let (reader,root) = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.chapters = (1...12).map { ChapterItem(id:"c\($0)",href:"chapter\($0).xhtml",title:"第\($0)章 · 阅读与思考",depth:$0 % 3 == 0 ? 1 : 0) }
        reader.position = EnginePosition(chapterHref:"chapter7.xhtml",viewportOffset:nil,anchor:nil,userDriven:nil,mode:.scroll,locator:"current",chapter:"第7章 · 阅读与思考",page:7,pageCount:12,progress:0.65,canGoNext:true,canGoPrevious:true)
        _ = reader.setReaderBookmark(.init(id:"first",title:"第一章 · 从一段阅读开始",progress:0.1),present:true)
        _ = reader.setReaderBookmark(.init(id:"second",title:"第七章 · 给思考一点时间",progress:0.65),present:true)
        func capture<V: View>(_ view: V,_ name: String,_ size: CGSize) async throws {
            let host = UIHostingController(rootView:view.frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(500)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        let panelSize = CGSize(width:380,height:620)
        try await capture(ReaderAppearancePanel(reader:reader,close:{}),"主题与排版-浅色",panelSize)
        reader.appearance.theme = "night"
        try await capture(ReaderAppearancePanel(reader:reader,close:{}).environment(\.colorScheme,.dark),"主题与排版-深色",panelSize)
        reader.appearance.theme = "light"
        try await capture(ReaderNavigationPanel(reader:reader,navigate:{_ in},close:{}),"阅读目录",CGSize(width:380,height:560))
        try await capture(ReaderNavigationPanel(reader:reader,navigate:{_ in},close:{},tab:.bookmarks),"书签与管理",CGSize(width:380,height:560))
        try await capture(ReaderSearchPanel(reader:reader,navigate:{_ in},close:{}),"书中搜索-空状态",CGSize(width:380,height:560))
        let note = ReaderAnnotation(cfi:"",quote:"阅读有一种很轻的力量。",chapter:"第一章",progress:0.1,note:"把这段话留在这里，等下一次读到时再想一想。")
        try await capture(ReaderNoteEditor(reader:reader,draft:.init(bookID:try XCTUnwrap(reader.currentID),annotation:note)),"随手记-编辑与草稿",CGSize(width:540,height:720))
    }
}

private struct PositionAuditInput: UIViewRepresentable {
    let field: UITextField
    func makeUIView(context: Context) -> UITextField { field }
    func updateUIView(_ view: UITextField,context: Context) {}
}
