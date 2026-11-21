import XCTest
import SwiftUI
import UIKit
@testable import BookSlidePhone

@MainActor final class DiscussionIPadTests: XCTestCase {
    func testClosingNotesRestoresTextHitTestingAndNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.appearance.fontSize = 32
        reader.open(try XCTUnwrap(reader.books.first?.id))
        for _ in 0..<150 {
            if !reader.loading, reader.position != nil { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        _ = try XCTUnwrap(reader.position)
        for mode in [ReadingMode.scroll,.paged] {
            reader.appearance.mode = mode
            try await Task.sleep(for:.milliseconds(800))
            XCTAssertTrue(reader.go("chapter1.xhtml"))
            try await Task.sleep(for:.milliseconds(600))
            for _ in 0..<3 {
                reader.openNoteGraph()
                try await Task.sleep(for:.milliseconds(1000))
                reader.showNoteGraph = false
                try await Task.sleep(for:.milliseconds(1800))
                let page = try XCTUnwrap(reader.webView.superview as? ReaderPencilHost)
                XCTAssertTrue(page.isUserInteractionEnabled,"Closing notes must release the native touch shield")
                XCTAssertFalse(reader.busy,"Closing notes must release navigation")
                XCTAssertFalse(reader.inlineInkObscured,"The departing notes must finish unmounting")
                let point = reader.webView.convert(CGPoint(x:120,y:200),to:window)
                let target = try XCTUnwrap(window.hitTest(point,with:nil))
                XCTAssertTrue(target.isDescendant(of:reader.webView),"Text touches must reach WebKit after closing notes; hit=\(type(of:target))")
                let before = try XCTUnwrap(reader.position)
                let failure = await reader.turn(.next)
                XCTAssertNil(failure)
                XCTAssertTrue(reader.position?.locator != before.locator || reader.position?.viewportOffset != before.viewportOffset,"Continuing to read must move the actual viewport")
                let reverseFailure = await reader.turn(.previous)
                XCTAssertNil(reverseFailure)
            }
        }
    }
    func testCompanionCanReverseWhileClosingWithoutLeavingPaperOrFocusBehind() async throws {
        let (root,reader,_) = try fixture()
        reader.discussionNoteID = nil
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.view.endEditing(true); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        // The status bar can finish hiding after the hosting window appears.
        // Compare panel reversal only after its safe-area geometry is stable.
        var previousSize = CGSize.zero, stableSamples = 0
        for _ in 0..<40 {
            host.view.layoutIfNeeded()
            let size = reader.webView.bounds.size
            stableSamples = size == previousSize && scene.statusBarManager?.isStatusBarHidden == true ? stableSamples+1 : 0
            if stableSamples >= 4 { break }
            previousSize = size
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(stableSamples,4,"The initial status-bar and paper geometry must settle before comparing layouts")
        let split = reader.webView.bounds.size
        reader.showNoteGraph = false
        try await Task.sleep(for:.milliseconds(80))
        reader.showNoteGraph = true
        try await Task.sleep(for:.milliseconds(1200))
        XCTAssertEqual(reader.webView.bounds.width,split.width,accuracy:1,"A reversed dismissal must end in the same split layout")
        XCTAssertEqual(reader.webView.bounds.height,split.height,accuracy:1)
        XCTAssertTrue(try XCTUnwrap(reader.webView.superview).isUserInteractionEnabled)
        reader.showNoteGraph = false
        try await Task.sleep(for:.milliseconds(1200))
        if window.bounds.width >= 900 { XCTAssertGreaterThan(reader.webView.bounds.width,split.width+100) }
        else { XCTAssertGreaterThan(reader.webView.bounds.height,split.height+100) }
        XCTAssertTrue(try XCTUnwrap(reader.webView.superview).isUserInteractionEnabled)
        XCTAssertFalse(textViews(host.view).contains(where: { $0.isFirstResponder }),"A dismissed note must not summon the keyboard from a stale completion")
        let point = reader.webView.convert(CGPoint(x:120,y:200),to:window)
        XCTAssertTrue(try XCTUnwrap(window.hitTest(point,with:nil)).isDescendant(of:reader.webView))
    }
    func testCompanionPaperMovesContinuouslyAndReleasesItsInputShield() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        let page = ReaderPencilHost(reader:reader), surface = UIView(frame:container.view.bounds)
        let original = CGSize(width:container.view.bounds.width,height:500)
        page.frame = CGRect(origin:.zero,size:original)
        container.view.addSubview(page); container.view.addSubview(surface)
        defer { page.cancelCompanionTransition(); reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        page.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(80))
        var completed = false, checkpointStarted = false, checkpointReady = false
        page.prepareCompanionTransition(in:surface,beforeReveal:{
            checkpointStarted = true
            while !checkpointReady, !Task.isCancelled { try? await Task.sleep(for:.milliseconds(10)) }
        }) { completed = true }
        let paper = try XCTUnwrap(surface.subviews.first)
        let text = try XCTUnwrap(paper.subviews.first)
        XCTAssertFalse(page.isUserInteractionEnabled)
        let destination = original.width*0.6
        page.frame.size.width = destination; page.setNeedsLayout(); page.layoutIfNeeded()
        XCTAssertEqual(reader.webView.bounds.width,destination,accuracy:1,"The live EPUB receives its final width immediately, just once")
        try await Task.sleep(for:.milliseconds(70))
        if !UIAccessibility.isReduceMotionEnabled {
            let moving = try XCTUnwrap(paper.layer.presentation())
            XCTAssertGreaterThan(moving.frame.width,destination+1)
            XCTAssertLessThan(moving.frame.width,original.width-1,"The visible paper edge must travel through intermediate positions")
            XCTAssertEqual(text.layer.presentation()?.transform.m11 ?? 1,1,accuracy:0.001,"Text translates without stretching glyphs")
            XCTAssertEqual(paper.alpha,1,"Do not crossfade the paper before the spatial movement finishes")
            XCTAssertFalse(completed)
        }
        for _ in 0..<50 {
            if checkpointStarted { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertTrue(checkpointStarted)
        XCTAssertTrue(paper.superview === surface,"Keep opaque paper in place until the passage has been restored")
        XCTAssertEqual(paper.alpha,1)
        XCTAssertEqual(text.alpha,1,"Do not fade the old passage while still waiting for the destination")
        XCTAssertFalse(completed)
        checkpointReady = true
        for _ in 0..<30 {
            if completed { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(surface.subviews.isEmpty)
        XCTAssertTrue(page.isUserInteractionEnabled)
        XCTAssertEqual(reader.webView.alpha,1,"The final text must be fully visible after handoff")
        page.prepareCompanionTransition(in:surface) { XCTFail("Cancelled movement must not hand focus to a stale note") }
        page.cancelCompanionTransition()
        XCTAssertTrue(surface.subviews.isEmpty)
        XCTAssertTrue(page.isUserInteractionEnabled)
    }

    func testProductionNewNoteBecomesReadyAfterPanelAnimation() async throws {
        let (root,reader,_) = try fixture()
        reader.discussionNoteID = nil; reader.annotationDraft?.annotation.note = ""
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.view.endEditing(true); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let map = try await auditReadyMap(host.view)
        try await auditWait { try await auditMapHasFocusedInput(map) }
        let focused = try await auditMapHasFocusedInput(map)
        XCTAssertTrue(focused,"The production companion must focus its inline node editor after presentation")
    }

    func testCompanionReversalContinuesFromTheVisiblePaper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        let page = ReaderPencilHost(reader:reader), surface = UIView(frame:container.view.bounds)
        let original = CGSize(width:container.view.bounds.width,height:500)
        page.frame = CGRect(origin:.zero,size:original)
        container.view.addSubview(page); container.view.addSubview(surface); page.layoutIfNeeded()
        defer { page.cancelCompanionTransition(); reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        try await Task.sleep(for:.milliseconds(80))
        page.prepareCompanionTransition(in:surface) { XCTFail("A reversed animation must not complete its original request") }
        let paper = try XCTUnwrap(surface.subviews.first)
        page.frame.size.width = original.width*0.6; page.setNeedsLayout(); page.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(100))
        let visible = try XCTUnwrap(paper.layer.presentation()).frame
        var completed = false
        page.prepareCompanionTransition(in:surface) { completed = true }
        XCTAssertTrue(surface.subviews.first === paper,"Keep the visible paper instead of replacing it with the already reflowed page")
        XCTAssertEqual(paper.frame.width,visible.width,accuracy:8,"Reversal begins where the paper is currently drawn")
        page.frame.size = original; page.setNeedsLayout(); page.layoutIfNeeded()
        for _ in 0..<30 {
            if completed { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(completed); XCTAssertTrue(surface.subviews.isEmpty)
        XCTAssertTrue(page.isUserInteractionEnabled); XCTAssertEqual(reader.webView.alpha,1)
    }
    func testPortraitCompanionKeepsTextVisibleDuringHeightOnlyChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance.mode = .scroll
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        let page = ReaderPencilHost(reader:reader), surface = UIView(frame:container.view.bounds)
        page.frame = CGRect(x:0,y:0,width:600,height:700)
        container.view.addSubview(page); container.view.addSubview(surface); page.layoutIfNeeded()
        defer { page.cancelCompanionTransition(); reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        try await Task.sleep(for:.milliseconds(80))
        var completed = false
        page.prepareCompanionTransition(in:surface) { completed = true }
        let paper = try XCTUnwrap(surface.subviews.first), text = try XCTUnwrap(surface.subviews.first?.subviews.first)
        page.frame.size.height = 340; page.setNeedsLayout(); page.layoutIfNeeded()
        for _ in 0..<25 {
            if paper.superview != nil { XCTAssertEqual(text.alpha,1,"Identical lines must not fade while the bottom edge moves") }
            XCTAssertEqual(reader.webView.alpha,1,"A portrait open/close must not flash the live text")
            if completed { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        XCTAssertTrue(completed); XCTAssertTrue(page.isUserInteractionEnabled)
    }
    func testCompanionOpeningAndClosingAtIPadSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let initialSize = CGSize(width:1194,height:834)
        let initialHost = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)).frame(width:initialSize.width,height:initialSize.height))
        container.addChild(initialHost); container.view.addSubview(initialHost.view)
        initialHost.view.frame = CGRect(origin:.zero,size:initialSize); initialHost.didMove(toParent:container)
        reader.appearance = ReaderAppearance(); reader.appearance.theme = "light"; reader.appearance.fontSize = 24
        reader.open(try XCTUnwrap(reader.books.first?.id))
        for _ in 0..<150 {
            if !reader.loading, reader.position != nil { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        _ = try XCTUnwrap(reader.position,"Mount WebKit before waiting for its display frames")
        print("COMPANION_FILM_READY")
        try await Task.sleep(for:.seconds(2))
        // Use explicit proposals: UIWindowScene rotation requests can be ignored
        // by a hosted test window, silently testing portrait twice.
        for size in [CGSize(width:1194,height:834),CGSize(width:834,height:1194),CGSize(width:600,height:800)] {
            let host = size == initialSize ? initialHost : UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)).frame(width:size.width,height:size.height))
            if host !== initialHost {
                container.addChild(host); container.view.addSubview(host.view)
                host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            }
            try await Task.sleep(for:.milliseconds(700))
            XCTAssertTrue(reader.go("chapter1.xhtml")); try await Task.sleep(for:.milliseconds(700))
            let before = try XCTUnwrap(reader.position)
            for cycle in 0..<2 {
                reader.openNoteGraph(); try await Task.sleep(for:.milliseconds(1100))
                if cycle == 0 {
                    let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
                    let attachment = XCTAttachment(image:image); attachment.name = "Companion-open-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
                }
                reader.showNoteGraph = false; try await Task.sleep(for:.milliseconds(1100))
                XCTAssertEqual(reader.position?.viewport?.locator,before.viewport?.locator)
                XCTAssertTrue(try XCTUnwrap(reader.webView.superview).isUserInteractionEnabled)
                XCTAssertEqual(reader.webView.alpha,1)
            }
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }

    func testNewNoteFocusWaitsForCompanionPresentation() async throws {
        let (root,reader,_) = try fixture()
        reader.discussionNoteID = nil; reader.annotationDraft?.annotation.note = ""
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,noteInputReady:false,close:{}))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.view.endEditing(true); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let map = try await auditReadyMap(host.view)
        let earlyFocus = try await auditMapHasFocusedInput(map)
        XCTAssertFalse(earlyFocus,"A panel in transition must not summon the keyboard")
        host.rootView = BookNotesWorkspace(reader:reader,readingCompanion:true,noteInputReady:true,close:{})
        try await auditWait { try await auditMapHasFocusedInput(map) }
        let readyFocus = try await auditMapHasFocusedInput(map)
        XCTAssertTrue(readyFocus)
    }


    func testKeyboardFoldKeepsTheSameGraphViewportAndCamera() async throws {
        let (root,reader,_) = try fixture()
        reader.discussionNoteID = nil; reader.annotationDraft = nil; reader.graphNoteID = nil
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        let large = CGSize(width:1194,height:834), small = CGSize(width:1194,height:470)
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}).frame(width:large.width,height:large.height))
        container.addChild(host); container.view.addSubview(host.view); host.view.frame = CGRect(origin:.zero,size:large); host.didMove(toParent:container)
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let map = try await auditReadyMap(host.view)
        _ = try await map.callAsyncJavaScript("window.bookMindMap.command({id:'zoom-audit',name:'zoomIn'});return true",arguments:[:],in:nil,contentWorld:.page)
        let camera = try await map.callAsyncJavaScript("return document.querySelector('.map-canvas').style.transform",arguments:[:],in:nil,contentWorld:.page) as? String
        for size in [small,large] {
            host.rootView = BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}).frame(width:size.width,height:size.height)
            try await Task.sleep(for:.milliseconds(500)); host.view.layoutIfNeeded()
            XCTAssertTrue(auditFindMap(host.view) === map,"The graph must stay mounted while the keyboard changes the available height")
            let restored = try await map.callAsyncJavaScript("return document.querySelector('.map-canvas').style.transform",arguments:[:],in:nil,contentWorld:.page) as? String
            XCTAssertEqual(restored,camera)
        }
    }

    private func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    private func fixture() throws -> (URL,ReaderModel,ReaderAnnotation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let book = try XCTUnwrap(reader.books.first)
        reader.currentID = book.id
        var note = ReaderAnnotation(cfi:"",quote:"更多信息未必带来更好的判断。",chapter:"测试章节",progress:0.2,note:"自己的想法与讨论分别保存。")
        var discussion = ReaderDiscussion()
        for i in 0..<10 {
            discussion.messages += [.init(role:.user,text:"第 \(i+1) 轮：如何理解信息与判断？"),
                                    .init(role:.assistant,text:String(repeating:"信息需要经过思考才能帮助判断。[原文] ",count:8),model:"界面测试")]
        }
        discussion.composer = "继续讨论：我的追问"
        note.discussion = discussion
        reader.annotationDraft = ReaderAnnotationDraft(bookID:book.id,annotation:note)
        reader.graphNoteID = note.id; reader.discussionNoteID = note.id; reader.showNoteGraph = true
        return (root,reader,note)
    }
    func testLongDiscussionKeepsComposerVisibleInLandscapePortraitAndKeyboardSizedViewport() async throws {
        let (root,reader,note) = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        // The reduced-height variants reproduce the layout proposal above the
        // software keyboard, including portrait and a narrow multitasking pane.
        let sizes = [CGSize(width:1194,height:834),CGSize(width:834,height:1194),
                     CGSize(width:1194,height:470),CGSize(width:600,height:460)]
        for size in sizes {
            let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{})
                .frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(400)); host.view.layoutIfNeeded()
            do {
                try await auditWait { textViews(host.view).contains { $0.text == "继续讨论：我的追问" } }
            } catch {
                func describe(_ view: UIView) -> [String] {
                    let details = view is UITextView || view.accessibilityIdentifier != nil
                        ? ["\(type(of:view)): \(view.accessibilityIdentifier ?? "") \(view.accessibilityLabel ?? "") \(view.frame)"] : []
                    return details + view.subviews.flatMap(describe)
                }
                print("DISCUSSION_LAYOUT_STATE id=\(reader.discussionNoteID ?? "nil") selected=\(String(describing:reader.selectedReadingItem)) draft=\(reader.annotationDraft?.id ?? "nil") views=\(describe(host.view))")
                let shot = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
                let attachment = XCTAttachment(image:shot); attachment.name = "长对话面板失败现场"; attachment.lifetime = .keepAlways; add(attachment)
                throw error
            }
            let composer = try XCTUnwrap(textViews(host.view).first { $0.text == "继续讨论：我的追问" })
            let before = composer.convert(composer.bounds,to:host.view)
            XCTAssertGreaterThan(before.height,35)
            XCTAssertGreaterThanOrEqual(before.minY,0)
            XCTAssertLessThanOrEqual(before.maxY,size.height-44,"Input stays inside the discussion panel above its bottom inset")
            func scrollViews(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            for scroll in scrollViews(host.view) where !(scroll is UITextView) && scroll.contentSize.height > scroll.bounds.height+100 {
                scroll.setContentOffset(CGPoint(x:scroll.contentOffset.x,y:scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom),animated:false)
            }
            host.view.layoutIfNeeded()
            XCTAssertEqual(composer.convert(composer.bounds,to:host.view).minY,before.minY,accuracy:1,"Scrolling long history must not move the input")
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "iPad讨论-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        XCTAssertEqual(reader.noteForEditing(note,bookID:try XCTUnwrap(reader.currentID)).discussion?.composer,"继续讨论：我的追问")
    }
    func testDiscussionDraftCommitsAndReopensWithItsSourceOnIPad() throws {
        let (root,reader,note) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let bookID = try XCTUnwrap(reader.currentID)
        try reader.keepTextDraft(note,bookID:bookID)
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        let restored = try XCTUnwrap(reopened.currentAnnotations.first)
        XCTAssertEqual(restored.discussion,note.discussion)
        XCTAssertEqual(restored.quote,note.quote)
        XCTAssertEqual(restored.note,note.note)
        XCTAssertEqual(reopened.bookNotesIndex.search("第 10 轮").count,1)
        XCTAssertTrue(NoteMarkdownExport.render(LibraryNotes.records(in:reopened.books),title:"讨论导出").contains("第 10 轮"))
    }
    func testProductionReaderOpensDiscussionBesideSourceAndAcceptsKeyboardInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        for _ in 0..<120 {
            if !reader.loading, reader.position != nil { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertFalse(reader.loading)
        // The model finishes loading before SwiftUI commits the EPUB's opacity
        // and layout. Wait for the real hit surface, as a user must be able to
        // select the source after that presentation settles.
        for _ in 0..<20 {
            host.view.layoutIfNeeded()
            let point = reader.webView.convert(CGPoint(x:120,y:200),to:window)
            if window.hitTest(point,with:nil)?.isDescendant(of:reader.webView) == true { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        let point = reader.webView.convert(CGPoint(x:120,y:200),to:window)
        let touched = try XCTUnwrap(window.hitTest(point,with:nil))
        XCTAssertTrue(touched.isDescendant(of:reader.webView),"The transparent paper surface must let source selection reach WebKit: hit=\(type(of:touched)), point=\(point), web=\(reader.webView.frame), window=\(window.bounds)")
        let value = try await reader.webView.callAsyncJavaScript("""
            const doc = document.querySelector('iframe').contentDocument;
            const range = doc.createRange(); range.selectNodeContents(doc.querySelector('p'));
            const selection = doc.defaultView.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return reader.annotationContext();
            """,arguments:[:],in:nil,contentWorld:.page)
        let context = try XCTUnwrap(value as? [String:Any])
        reader.receiveAnnotation("annotationDiscuss",value:context)
        var discussion = ReaderDiscussion(); discussion.composer = "测试键盘输入"
        reader.selectionDiscussion?.annotation.discussion = discussion
        try await Task.sleep(for:.milliseconds(500)); host.view.layoutIfNeeded()
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertNil(reader.annotationDraft)
        XCTAssertTrue(reader.webView.isDescendant(of:host.view),"The original EPUB remains mounted beside the discussion")
        XCTAssertGreaterThan(reader.webView.bounds.height,200)
        XCTAssertEqual(reader.selectionDiscussion?.annotation.cfi,context["cfi"] as? String)
        let composer = try XCTUnwrap(textViews(host.view).first { $0.text == "测试键盘输入" })
        XCTAssertTrue(composer.becomeFirstResponder())
        try await Task.sleep(for:.milliseconds(500)); host.view.layoutIfNeeded()
        XCTAssertTrue(composer.isFirstResponder)
        let frame = composer.convert(composer.bounds,to:host.view)
        XCTAssertGreaterThan(frame.height,35)
        XCTAssertGreaterThanOrEqual(frame.minY,0)
        XCTAssertLessThanOrEqual(frame.maxY,host.view.bounds.height)
        let image = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "iPad原文旁讨论与键盘"; attachment.lifetime = .keepAlways; add(attachment)
        composer.resignFirstResponder()
    }
    func testSelectedNodeUsesTheReadingCompanionInsteadOfPresentingAModal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        for _ in 0..<120 {
            if !reader.loading, reader.position != nil { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let before = reader.currentBook?.graph
        let source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"静心是阅读的开始，给自己的思考留下一点时间。",chapter:"第一章",progress:0.2)
        reader.selectionEntity = .init(bookID:try XCTUnwrap(reader.currentID),annotation:source)
        try await Task.sleep(for:.milliseconds(750)); host.view.layoutIfNeeded()
        func fields(_ view: UIView) -> [UITextField] { (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        let name = try XCTUnwrap(fields(host.view).first { $0.placeholder == "为这段原文命名" })
        XCTAssertEqual(name.text,source.quote,"A selection longer than 12 characters must not silently leave the name empty and Add disabled")
        XCTAssertTrue(name.isDescendant(of:host.view),"The source node editor belongs to the same reading hierarchy")
        XCTAssertNil(host.presentedViewController,"iPad must not present a separate node sheet")
        XCTAssertTrue(reader.webView.isDescendant(of:host.view))
        XCTAssertEqual(reader.currentBook?.graph,before,"Opening the shared editor does not create an empty node")
        reader.selectionEntity = nil
        try await Task.sleep(for:.milliseconds(650))
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(reader.webView.isDescendant(of:host.view))
    }
    func testIndependentSelectionPanelDoesNotCreateAnEmptyNoteAndFlushesLatestQuestionOnClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let bookID = try XCTUnwrap(reader.books.first?.id); reader.currentID = bookID
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        defer { window.rootViewController = UIViewController(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        for typing in [false,true] {
            let selection = ReaderAnnotation(cfi:"",quote:"仅围绕这段原文讨论。",chapter:"测试章节",progress:0.2)
            let draft = ReaderAnnotationDraft(bookID:bookID,annotation:selection)
            window.rootViewController = UIHostingController(rootView:ReaderSelectionDiscussion(reader:reader,draft:draft,close:{}))
            window.makeKeyAndVisible(); try await Task.sleep(for:.milliseconds(400))
            if typing {
                let composer = try XCTUnwrap(textViews(window).first)
                composer.insertText("关闭前最后输入的追问")
                try await Task.sleep(for:.milliseconds(30))
            }
            window.rootViewController = UIViewController(); try await Task.sleep(for:.milliseconds(200))
            let saved = reader.currentAnnotations.first { $0.id == selection.id }
            if typing {
                XCTAssertEqual(saved?.note,"")
                XCTAssertEqual(saved?.quote,selection.quote)
                XCTAssertEqual(saved?.discussion?.composer,"关闭前最后输入的追问")
            } else { XCTAssertNil(saved,"A selection alone must not create a note when its panel is closed") }
        }
    }
    func testIndependentDiscussionKeepsComposerVisibleAtIPadPanelAndKeyboardSizes() async throws {
        let (root,reader,note) = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let bookID = try XCTUnwrap(reader.currentID)
        for size in [CGSize(width:480,height:780),CGSize(width:834,height:560),CGSize(width:480,height:400)] {
            let host = UIHostingController(rootView:ReaderSelectionDiscussion(reader:reader,draft:.init(bookID:bookID,annotation:note),close:{}).frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view); host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(400)); host.view.layoutIfNeeded()
            let composer = try XCTUnwrap(textViews(host.view).first { $0.text == "继续讨论：我的追问" })
            let rect = composer.convert(composer.bounds,to:host.view)
            XCTAssertGreaterThan(rect.height,35); XCTAssertGreaterThan(rect.minY,50); XCTAssertLessThanOrEqual(rect.maxY,size.height)
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "独立选文讨论-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }
}
