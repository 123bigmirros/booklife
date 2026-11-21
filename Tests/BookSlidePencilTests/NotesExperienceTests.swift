import XCTest
import UIKit
import SwiftUI
import WebKit
@testable import BookSlidePhone

@MainActor final class NotesExperienceTests: XCTestCase {
    func testSelectedPeopleRenderWithoutDuplicateThoughtCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"源泉",author:"安·兰德",filename:"",progress:0.5)]
        reader.currentID = bookID; reader.showNoteGraph = true
        reader.chapters = [.init(id:"one",href:"one.xhtml",title:"第一章",depth:0)]
        var selected: UUID?
        for (offset,name) in ["霍华德·洛克","吉丁太太"].enumerated() {
            var source = ReaderAnnotation(cfi:"epubcfi(/6/\(offset*2+2)!/4/2)",quote:name,chapter:"第一章",progress:0.2)
            source.chapterHref = "one.xhtml"
            selected = try XCTUnwrap(reader.recordSelectedEntity(name:name,kind:.person,source:source,bookID:bookID))
        }
        reader.selectReadingItem(.node(.init(.entity,try XCTUnwrap(selected).uuidString)))
        let (window,previous) = try window()
        let size = CGSize(width:480,height:800)
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}).frame(width:size.width,height:size.height))
        let container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        container.addChild(host); container.view.addSubview(host.view)
        host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        for dark in [false,true] {
            reader.appearance.theme = dark ? "night" : "light"
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            try await Task.sleep(for:.milliseconds(500)); host.view.layoutIfNeeded()
            XCTAssertEqual(reader.bookNotesIndex.entities.count,2)
            XCTAssertTrue(reader.bookNotesIndex.notes.filter(\.showsOnCanvas).isEmpty)
            XCTAssertEqual(reader.currentAnnotations.count,2,"Entity source passages must remain available")
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image)
            attachment.name = "人物节点无重复想法-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func fixture() throws -> (URL,ReaderModel,UUID,UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let sample = try XCTUnwrap(reader.books.first)
        let firstID = UUID(), secondID = UUID()
        var first = ReaderAnnotation(cfi:"",quote:"理解需要一点耐心。",chapter:"第一章",progress:0.7,note:"重读时补上自己的理解。")
        first.title = "让耐心留下痕迹"
        let patience = BookEntity(name:"耐心",kind:.concept,aliases:["静心"])
        let understanding = BookEntity(name:"理解",kind:.concept)
        first.entityIDs = [patience.id,understanding.id]
        var second = ReaderAnnotation(cfi:"",quote:"更多信息未必带来更好的判断。",chapter:"第一章",progress:0.3,note:"什么时候应该停止收集信息？")
        second.title = "给判断留一点余地"; second.intent = .question
        reader.books = [LibraryBook(id:firstID,title:"慢慢读懂一本书",author:"BookSlide 测试",filename:sample.filename,progress:0.8,annotations:[first],knowledgeEntities:[patience,understanding],knowledgeRelations:[BookRelation(sourceID:patience.id,targetID:understanding.id,label:"促进",evidenceIDs:[first.id])]),
                        LibraryBook(id:secondID,title:"不确定性手记",author:"BookSlide 测试",filename:sample.filename,annotations:[second])]
        reader.chapters = [ChapterItem(id:"chapter",href:"chapter.xhtml",title:"第一章",depth:0)]
        reader.save()
        return (root,reader,firstID,secondID)
    }
    func testEveryContentTypeUsesTheSameNamedConnectionAndKeepsLegacyEvidence() throws {
        let (root,reader,bookID,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        reader.currentID = bookID
        let people = try XCTUnwrap(reader.currentBook?.graph.entities)
        let a = try XCTUnwrap(people.first), b = try XCTUnwrap(people.last)
        let note = try XCTUnwrap(reader.currentAnnotations.first)
        var withDiscussion = note
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"如何理解耐心？"),.init(role:.assistant,text:"先保留问题。")]
        withDiscussion.discussion = discussion
        XCTAssertTrue(reader.saveGraphAnnotation(withDiscussion,bookID:bookID,relation:nil))
        let before = try XCTUnwrap(reader.currentBook?.graph)
        let pairs: [(ReadingNodeID,ReadingNodeID,String)] = [
            (.init(.entity,a.id.uuidString),.init(.entity,b.id.uuidString),"  师父  "),
            (.init(.note,note.id),.init(.entity,a.id.uuidString),"依据"),
            (.init(.discussion,note.id),.init(.entity,b.id.uuidString),"解读人物")]
        for (source,target,label) in pairs {
            let id = try XCTUnwrap(reader.connectReadingNodes(from:source,to:target,label:label,bookID:bookID))
            let edge = try XCTUnwrap(reader.currentBook?.graph.edges.first(where:{ $0.id == id }))
            XCTAssertEqual(edge.id.kind,.association)
            XCTAssertEqual(edge.id.source,source); XCTAssertEqual(edge.id.target,target)
            XCTAssertEqual(edge.label,label.trimmingCharacters(in:.whitespacesAndNewlines))
            let count = reader.currentBook?.graph.edges.count
            XCTAssertEqual(reader.connectReadingNodes(from:source,to:target,label:label,bookID:bookID),id)
            XCTAssertEqual(reader.currentBook?.graph.edges.count,count,"Confirming an existing connection is idempotent")
        }
        let snapshot = try XCTUnwrap(reader.currentBook?.graph)
        XCTAssertNil(reader.connectReadingNodes(from:pairs[0].0,to:pairs[0].0,label:"关联",bookID:bookID))
        XCTAssertNil(reader.connectReadingNodes(from:pairs[0].0,to:pairs[0].1,label:"  ",bookID:bookID))
        XCTAssertNil(reader.connectReadingNodes(from:pairs[0].0,to:.init(.entity,UUID().uuidString),label:"关联",bookID:bookID))
        XCTAssertEqual(reader.currentBook?.graph,snapshot,"Invalid drafts cannot partially write edges")
        let restored = ReaderModel(directory:root,loadExternalSources:false); restored.currentID = bookID
        XCTAssertEqual(restored.currentBook?.graph,snapshot)
        XCTAssertEqual(restored.currentBook?.graph.relations,before.relations,"Existing relationship evidence stays in the same graph")
        XCTAssertEqual(restored.currentAnnotations.first?.discussion,withDiscussion.discussion)
    }
    private func window() throws -> (UIWindow,UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        return (UIWindow(windowScene:scene),scene.windows.first { $0.isKeyWindow })
    }
    private func waitForBook(_ reader: ReaderModel) async throws {
        for _ in 0..<150 {
            if !reader.loading, reader.position != nil { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail(reader.error ?? "EPUB 未完成打开")
    }
    func testAutosaveTargetsOriginalBookAllowsClearingAndNeverRevivesDeletedNotes() throws {
        let (root,reader,firstID,secondID) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        var note = try XCTUnwrap(reader.books.first?.annotations?.first)
        let original = note
        let secondText = reader.books[1].annotations?.first?.note
        reader.currentID = secondID
        note.note = "切换图书前最后输入的想法"
        XCTAssertTrue(reader.autosaveGraphAnnotation(note,bookID:firstID,relation:nil))
        XCTAssertEqual(reader.currentID,secondID)
        XCTAssertEqual(reader.currentAnnotations.first?.note,secondText)
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        XCTAssertEqual(reopened.books.first?.annotations?.first?.note,note.note)
        XCTAssertEqual(reader.noteForEditing(original,bookID:firstID).note,note.note,"Reopening from an older graph reference must use the latest autosaved content")
        note.note = ""; note.title = nil; note.quote = ""
        XCTAssertTrue(reader.autosaveGraphAnnotation(note,bookID:firstID,relation:nil),"Clearing an existing note must save the empty edit")
        XCTAssertEqual(reader.books.first?.annotations?.first?.note,"")
        let blank = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0,note:"")
        XCTAssertTrue(reader.autosaveGraphAnnotation(blank,bookID:firstID,relation:nil))
        XCTAssertEqual(reader.books.first?.annotations?.count,1,"An untouched new editor must not add a blank note")
        reader.currentID = firstID
        XCTAssertTrue(reader.removeAnnotation(note.id,bookID:firstID))
        note.note = "旧编辑器迟到的自动保存"
        XCTAssertFalse(reader.autosaveGraphAnnotation(note,bookID:firstID,relation:nil))
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
    }
    func testBothNoteEditorsFlushLatestCharactersWhenClosingAfterSwitchingBooks() async throws {
        let (root,reader,firstID,secondID) = try fixture()
        let (window,previous) = try window()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        func textViews(_ view: UIView) -> [UITextView] { (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        for modal in [false,true] {
            reader.currentID = firstID
            let note = try XCTUnwrap(reader.currentAnnotations.first)
            if modal {
                window.rootViewController = UIHostingController(rootView:ReaderNoteEditor(reader:reader,draft:.init(bookID:firstID,annotation:note)))
            } else {
                window.rootViewController = UIHostingController(rootView:BookGraphNoteInspector(reader:reader,original:note,palette:.init(dark:false),includeFuture:false,select:{ _ in }))
            }
            window.makeKeyAndVisible()
            try await Task.sleep(for:.milliseconds(350))
            let editor = try XCTUnwrap(textViews(window).first)
            let marker = modal ? "弹出编辑器最后输入" : "结构图编辑器最后输入"
            editor.insertText(marker)
            try await Task.sleep(for:.milliseconds(20))
            reader.currentID = secondID
            window.rootViewController = UIViewController()
            try await Task.sleep(for:.milliseconds(150))
            let saved = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self)?.value)
            XCTAssertTrue(saved.first?.annotations?.first?.note.contains(marker) == true,"Dismissal must flush before the debounce, even after a book switch")
            XCTAssertEqual(saved[1].annotations?.first?.note,"什么时候应该停止收集信息？")
            XCTAssertTrue(try reader.noteDraftStore.textDrafts(bookID:firstID).isEmpty)
        }
    }
    func testInspectorAutosaveFailureRetainsDraftAndLaterEditRecoversIt() async throws {
        let (root,reader,firstID,_) = try fixture()
        reader.currentID = firstID
        let note = try XCTUnwrap(reader.currentAnnotations.first)
        let (window,previous) = try window()
        window.rootViewController = UIHostingController(rootView:BookGraphNoteInspector(reader:reader,original:note,palette:.init(dark:false),includeFuture:false,select:{ _ in }))
        window.makeKeyAndVisible()
        defer { window.rootViewController = UIViewController(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        func textViews(_ view: UIView) -> [UITextView] { (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        try await Task.sleep(for:.milliseconds(350))
        let editor = try XCTUnwrap(textViews(window).first)
        let index = root.appendingPathComponent("library.json"), held = root.appendingPathComponent("held-index.json")
        try FileManager.default.moveItem(at:index,to:held)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        editor.insertText("保存失败也要保留")
        try await Task.sleep(for:.milliseconds(1000))
        XCTAssertEqual(reader.currentAnnotations.first?.note,note.note,"A failed write must not claim the note was saved")
        XCTAssertTrue(try reader.noteDraftStore.textDrafts(bookID:firstID).first?.annotation.note.contains("保存失败也要保留") == true)
        try FileManager.default.removeItem(at:index); try FileManager.default.moveItem(at:held,to:index)
        editor.insertText("恢复后继续")
        try await Task.sleep(for:.milliseconds(1000))
        XCTAssertTrue(reader.currentAnnotations.first?.note.contains("保存失败也要保留") == true)
        XCTAssertTrue(reader.currentAnnotations.first?.note.contains("恢复后继续") == true)
        XCTAssertTrue(try reader.noteDraftStore.textDrafts(bookID:firstID).isEmpty)
    }
    func testClosingNotesPreservesReadingPassageAndSavedProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance = ReaderAppearance()
        reader.appearance.fontSize = 32
        let (window,previous) = try window()
        let container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        for size in [CGSize(width:1194,height:834),CGSize(width:834,height:1194),CGSize(width:600,height:800)] {
            let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)).frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await waitForBook(reader)
            try await Task.sleep(for:.milliseconds(700))
            for mode in [ReadingMode.scroll,.paged] {
                reader.appearance.mode = mode
                try await Task.sleep(for:.milliseconds(700))
                // Move into the second chapter, away from a page/paragraph boundary.
                _ = reader.go("chapter1.xhtml")
                try await Task.sleep(for:.milliseconds(500))
                _ = await reader.turn(.next)
                if mode == .scroll { _ = await reader.turn(.previous,scrollLines:0.25) }
                try await Task.sleep(for:.milliseconds(500))
                let before = try XCTUnwrap(reader.position)
                print("NOTES_POSITION_BEGIN \(size) \(mode) \(before.locator)")
                for cycle in 0..<3 {
                    reader.openNoteGraph()
                    try await Task.sleep(for:.milliseconds(650))
                    // Initial graph creation can delay WebKit's resize callback.
                    // Wait for its settled position rather than testing the last
                    // user-driven position still retained during reflow.
                    for _ in 0..<20 {
                        if reader.position?.userDriven == false { break }
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    XCTAssertFalse(reader.position?.userDriven ?? true,"Layout changes must not publish new reading activity")
                    if mode == .scroll {
                        XCTAssertEqual(reader.position?.locator,before.locator,"Opening notes preserves the passage")
                    }
                    if cycle == 0 {
                        let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
                        let attachment = XCTAttachment(image:image)
                        attachment.name = "Notes-position-\(mode)-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
                    }
                    reader.showNoteGraph = false
                    try await Task.sleep(for:.milliseconds(650))
                    XCTAssertEqual(reader.position?.locator,before.locator,"Closing notes must restore the same text after cycle \(cycle)")
                    XCTAssertEqual(reader.position?.progress ?? -1,before.progress,accuracy:0.00001)
                    if let offset = before.viewportOffset {
                        XCTAssertEqual(reader.position?.viewportOffset ?? -1,offset,accuracy:1,"Preserve the partial-line scroll offset")
                    }
                    XCTAssertEqual(reader.currentBook?.locator,before.locator,"Transient resize positions must not overwrite the saved cursor")
                    var savedLocator: String?
                    for _ in 0..<20 {
                        savedLocator = try LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first?.locator
                        if savedLocator == before.locator { break }
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    XCTAssertEqual(savedLocator,before.locator,"The on-disk reading cursor must survive closing notes")
                }
            }
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }

    func testChapterBrowsingUsesTheWholeCompanionWithoutABottomInspector() async throws {
        let (root,reader,bookID,_) = try fixture()
        reader.currentID = bookID; reader.graphNoteID = nil; reader.annotationDraft = nil
        let (window,previous) = try window()
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        for size in [CGSize(width:480,height:760),CGSize(width:834,height:500),CGSize(width:360,height:720)] {
            let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}).frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            let viewport = try await auditReadyMap(host.view)
            XCTAssertGreaterThanOrEqual(viewport.bounds.height,size.height-70,"Chapter browsing must not reserve a lower instruction panel")
            XCTAssertFalse(host.view.subviews.contains { $0.accessibilityIdentifier == "graph-inline-editor" })
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "chapter-graph-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }

    func testReadingCompanionRendersCompactNotesWithLargerGraphAtIPadSizes() async throws {
        let (root,reader,firstID,_) = try fixture()
        let (window,previous) = try window()
        let container = UIViewController(); container.view.addSubview(reader.webView)
        reader.webView.frame = CGRect(x:0,y:0,width:834,height:1100)
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(firstID); try await waitForBook(reader)
        reader.showNoteGraph = true; reader.graphNoteID = reader.currentAnnotations.first?.id
        for size in [CGSize(width:1194,height:834),CGSize(width:834,height:1194),CGSize(width:600,height:800)] {
            let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)).frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(700)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "iPad-阅读旁结构图与自动保存笔记-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertNotNil(host.view.window)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }
    func testPersonEditorFlushesToOriginalBookAndRecoversFailedAutosave() async throws {
        let (root,reader,firstID,secondID) = try fixture()
        reader.currentID = firstID
        let person = try XCTUnwrap(reader.currentBook?.knowledgeEntities?.first)
        let (window,previous) = try window()
        defer { window.rootViewController = UIViewController(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        func fields(_ view: UIView) -> [UITextField] { (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        func show() async throws -> UITextField {
            window.rootViewController = UIHostingController(rootView:BookGraphEntityInspector(reader:reader,original:person,palette:.init(dark:false),includeFuture:false,select:{ _ in }))
            window.makeKeyAndVisible(); try await Task.sleep(for:.milliseconds(350))
            return try XCTUnwrap(fields(window).first { $0.text == person.name })
        }
        let name = try await show()
        name.text = "修改后的人物"; name.sendActions(for:.editingChanged)
        try await Task.sleep(for:.milliseconds(40))
        reader.currentID = secondID; window.rootViewController = UIViewController()
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertEqual(reader.books.first?.knowledgeEntities?.first?.name,"修改后的人物")
        XCTAssertTrue(reader.books[1].graph.entities.isEmpty)
        reader.currentID = firstID
        let host = UIHostingController(rootView:BookGraphEntityInspector(reader:reader,original:try XCTUnwrap(reader.currentBook?.knowledgeEntities?.first),palette:.init(dark:false),includeFuture:false,select:{ _ in }))
        window.rootViewController = host; try await Task.sleep(for:.milliseconds(350))
        let editor = try XCTUnwrap(fields(window).first { $0.text == "修改后的人物" })
        let index = root.appendingPathComponent("library.json"), held = root.appendingPathComponent("held-index.json")
        try FileManager.default.moveItem(at:index,to:held); try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        editor.text = "人物修改保留草稿"; editor.sendActions(for:.editingChanged)
        try await Task.sleep(for:.milliseconds(1000))
        let nodeID = ReadingNodeID(.entity,person.id.uuidString)
        XCTAssertEqual(try reader.readingNodeDraftStore.load(bookID:firstID,id:nodeID)?.node.title,"人物修改保留草稿")
        XCTAssertEqual(reader.currentBook?.knowledgeEntities?.first?.name,"修改后的人物")
        try FileManager.default.removeItem(at:index); try FileManager.default.moveItem(at:held,to:index)
        editor.text = "草稿已恢复"; editor.sendActions(for:.editingChanged)
        try await Task.sleep(for:.milliseconds(1000))
        XCTAssertEqual(reader.currentBook?.knowledgeEntities?.first?.name,"草稿已恢复")
        XCTAssertNil(try reader.readingNodeDraftStore.load(bookID:firstID,id:nodeID))
    }
    func testExternalBookOutlineReachesIPadAndShowsSubheadingBranches() async throws {
        let source = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("BookSlideOutlineFixture.epub")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Copy an external EPUB to the simulator cache for this integration check") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false), id = UUID()
        try FileManager.default.copyItem(at:source,to:root.appendingPathComponent("external.epub"))
        reader.books = [LibraryBook(id:id,title:"外部 EPUB 检查",author:"",filename:"external.epub")]
        let (window,previous) = try window()
        let container = UIViewController(); container.view.addSubview(reader.webView)
        reader.webView.frame = CGRect(x:0,y:0,width:834,height:1100)
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(id); try await waitForBook(reader)
        let outline = try await reader.webView.callAsyncJavaScript("return await reader.outline()",arguments:[:],in:nil,contentWorld:.page) as? [[String:Any]] ?? []
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(reader.chapters.count,outline.count)
        let structure = reader.bookNotesIndex.structure
        print("IPAD_NATIVE_OUTLINE javascript=\(outline.count) native=\(reader.chapters.count) descendants=\(structure.nodes.filter { $0.parent != nil }.count)")
        let chapter = try XCTUnwrap(structure.nodes.first { $0.entry.title.hasPrefix("第一章") && !$0.children.isEmpty })
        XCTAssertGreaterThan(chapter.children.count,0)
        // Enter from a body subheading: opening the workspace must still show
        // its chapter and sibling branches, rather than an isolated leaf.
        reader.go(structure.nodes[chapter.children[0]].entry.href)
        for _ in 0..<100 { if !reader.busy { break }; try await Task.sleep(for:.milliseconds(100)) }
        reader.showNoteGraph = true
        let size = CGSize(width:1194,height:834)
        let host = UIHostingController(rootView:ReaderNotesScene(reader:reader).frame(width:size.width,height:size.height))
        container.addChild(host); container.view.addSubview(host.view)
        host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
        try await Task.sleep(for:.milliseconds(450)); host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "黑天鹅第一章与真实子标题分支"; attachment.lifetime = .keepAlways; add(attachment)
        host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
    }

    func testLateBodyHeadingsKeepTheSelectedChapterAndRefocusItsExpandedBranch() async throws {
        let (root,reader,firstID,_) = try fixture()
        reader.currentID = firstID; reader.showNoteGraph = true
        let (window,previous) = try window()
        let host = UIHostingController(rootView:ReaderNotesScene(reader:reader))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let graph = try await auditReadyMap(host.view)
        let current = try XCTUnwrap(reader.chapters.first)
        let before = (0..<70).map { ChapterItem(id:"before-\($0)",href:"before-\($0).xhtml",title:"前面的章节 \($0)",depth:0) }
        let children = (0..<14).map { ChapterItem(id:"heading-\($0)",href:"chapter.xhtml#sub-\($0)",title:"本章子标题 \($0)",depth:1) }
        reader.chapters = before + [current] + children
        let token = try XCTUnwrap(reader.mindMapDocument().flattened().first { $0.topic.metadata?.kind == "chapter" && $0.topic.topic == current.title }?.topic.id)
        try await auditWait {
            try await graph.callAsyncJavaScript("const e=document.querySelector('[data-nodeid=\"me'+token+'\"]');if(!e)return false;const r=e.getBoundingClientRect();return r.right>0 && r.left<innerWidth && r.bottom>0 && r.top<innerHeight",arguments:["token":token],in:nil,contentWorld:.page) as? Bool == true
        }
        XCTAssertTrue(auditFindMap(host.view) === graph)
        let count = try await graph.callAsyncJavaScript("return document.querySelectorAll('.me-tpc').length",arguments:[:],in:nil,contentWorld:.page) as? Int
        XCTAssertGreaterThan(try XCTUnwrap(count),80,"The late headings must reach the existing map")
    }


    func testGraphViewportKeepsBothAxesAndDoesNotJumpWhenANoteIsSaved() async throws {
        let (root,reader,firstID,_) = try fixture()
        let (window,previous) = try window()
        let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.currentID = firstID; reader.showNoteGraph = true
        reader.graphNoteID = reader.currentAnnotations.first?.id
        reader.chapters += (1...18).map { ChapterItem(id:"sub-\($0)",href:"chapter.xhtml#sub-\($0)",title:"小标题 \($0) · 阅读中的线索",depth:$0 % 3 == 0 ? 2 : 1) }
        for size in [CGSize(width:390,height:844),CGSize(width:600,height:800),CGSize(width:1194,height:834)] {
            let host = UIHostingController(rootView:ReaderNotesScene(reader:reader).frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            let graph = try await auditReadyMap(host.view)
            try await Task.sleep(for:.milliseconds(400))
            let before = try await graph.callAsyncJavaScript("document.querySelector('.map-container').dispatchEvent(new WheelEvent('wheel',{deltaX:150,deltaY:720,bubbles:true,cancelable:true}));return document.querySelector('.map-canvas').style.transform",arguments:[:],in:nil,contentWorld:.page) as? String
            var note = try XCTUnwrap(reader.currentAnnotations.first); note.note += "继续整理。"
            XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:firstID,relation:nil))
            try await Task.sleep(for:.milliseconds(400)); host.view.layoutIfNeeded()
            XCTAssertTrue(auditFindMap(host.view) === graph)
            let after = try await graph.callAsyncJavaScript("return document.querySelector('.map-canvas').style.transform",arguments:[:],in:nil,contentWorld:.page) as? String
            XCTAssertEqual(after,before,"Autosave must keep both axes of the map's camera")
            let count = try await graph.callAsyncJavaScript("return document.querySelectorAll('.me-tpc').length",arguments:[:],in:nil,contentWorld:.page) as? Int
            XCTAssertGreaterThan(try XCTUnwrap(count),18)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }

    func testQuickNoteUsesExistingKnowledgeAndRendersAtPhoneAndIPadSizes() async throws {
        let (root,reader,firstID,_) = try fixture()
        reader.currentID = firstID
        let (window,previous) = try window()
        let container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        var note = ReaderAnnotation(cfi:"",quote:"静心才能理解。",chapter:"第一章",progress:0.8,note:"把这次的理解接回之前的记录。")
        let entity = try XCTUnwrap(reader.bookNotesIndex.suggestedEntities(for:note,through:reader.noteVisibilityProgress).first { $0.name == "耐心" })
        XCTAssertEqual(reader.bookNotesIndex.relatedNotes(for:note,through:reader.noteVisibilityProgress).count,1)
        note.entityIDs = [entity.id]
        try reader.keepTextDraft(note,bookID:firstID)
        let recovered = reader.noteForEditing(note,bookID:firstID)
        XCTAssertEqual(recovered.entityIDs,[entity.id])
        for size in [CGSize(width:390,height:844),CGSize(width:600,height:800),CGSize(width:834,height:1194)] {
            let host = UIHostingController(rootView:ReaderNoteEditor(reader:reader,draft:ReaderAnnotationDraft(bookID:firstID,annotation:note)).frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(450)); host.view.endEditing(true)
            try await Task.sleep(for:.milliseconds(250)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "记笔记时联动知识系统-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        XCTAssertTrue(reader.saveGraphAnnotation(recovered,bookID:firstID,relation:recovered.graphRelationDraft))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = firstID
        XCTAssertEqual(reopened.currentAnnotations.count,2)
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == note.id }?.entityIDs,[entity.id])
        XCTAssertTrue(reopened.textNoteDrafts.isEmpty)
    }
    func testCrossBookEditingAndReturningToSourceKeepNotesAndReadingCanvas() async throws {
        let (root,reader,firstID,secondID) = try fixture()
        let (window,previous) = try window()
        let host = UIViewController(); host.view.addSubview(reader.webView)
        reader.webView.frame = CGRect(x:0,y:0,width:834,height:1100)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(firstID); try await waitForBook(reader)
        let canvas = reader.webView
        let records = LibraryNotes.records(in:reader.books)
        XCTAssertEqual(LibraryNotes.filtered(records,query:"耐心").count,1)
        XCTAssertEqual(LibraryNotes.filtered(records,filter:.questions).count,1)
        let target = try XCTUnwrap(records.first { $0.book.id == secondID })
        reader.openKnowledgeWorkspace(bookID:target.book.id,noteID:target.note.id)
        try await waitForBook(reader)
        XCTAssertEqual(reader.currentID,secondID)
        XCTAssertTrue(reader.showNoteGraph)
        XCTAssertEqual(reader.graphNoteID,target.note.id)
        XCTAssertTrue(reader.webView === canvas)
        var edited = try XCTUnwrap(reader.currentAnnotations.first)
        edited.note = "在 iPad 上整理后的理解。"; edited.questionResolved = true
        XCTAssertTrue(reader.saveGraphAnnotation(edited,bookID:secondID,relation:nil))
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        XCTAssertEqual(reopened.books.first { $0.id == secondID }?.annotations?.first?.note,edited.note)
        XCTAssertEqual(reopened.books.first { $0.id == firstID }?.annotations?.first?.note,"重读时补上自己的理解。")
        var source = try XCTUnwrap(reader.books.first { $0.id == firstID })
        source.annotations?[0].cfi = try XCTUnwrap(reader.position?.locator)
        let sourceRecord = try XCTUnwrap(LibraryNotes.records(in:[source]).first)
        await reader.openLibraryNote(sourceRecord,atSource:true)
        try await Task.sleep(for:.milliseconds(150))
        for _ in 0..<100 {
            if !reader.busy { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertEqual(reader.currentID,firstID)
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertNil(reader.error)
        XCTAssertNotNil(reader.position)
    }
    func testHandwritingExportIsPortableZipWithValidChecksumsAndRelativeImages() async throws {
        let (root,reader,firstID,_) = try fixture()
        let (window,previous) = try window()
        let host = UIViewController(); host.view.addSubview(reader.webView)
        reader.webView.frame = CGRect(x:0,y:0,width:834,height:1100)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(firstID); try await waitForBook(reader)
        let image = UIGraphicsImageRenderer(size:CGSize(width:200,height:150)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:200,height:150))
            ("书页批注" as NSString).draw(at:CGPoint(x:15,y:30),withAttributes:[.font:UIFont.systemFont(ofSize:22)])
        }
        let png = try XCTUnwrap(image.pngData())
        let asset = try reader.pageNoteStore.save(ReaderPageNoteFiles(drawing:Data([1]),page:png,ink:png,preview:png))
        let anchor = ReaderPageAnchor(locator:"",chapter:"第一章",progress:0.3,referenceX:0,referenceY:0,viewportWidth:200,viewportHeight:150,layoutKey:"test")
        reader.books[0].pageNotes = [ReaderPageNote(assetID:asset,anchor:anchor)]
        let data = try NoteExportArchive.make(LibraryNotes.records(in:[reader.books[0]]),title:"耐心与理解",libraryDirectory:root)
        let value = try await reader.webView.callAsyncJavaScript("""
            const zip = await JSZip.loadAsync(data, {base64:true,checkCRC32:true});
            return {names:Object.keys(zip.files), text:await zip.file('耐心与理解.md').async('string'), image:await zip.file(imagePath).async('base64')};
            """,arguments:["data":data.base64EncodedString(),"imagePath":"assets/\(asset.uuidString).png"],in:nil,contentWorld:.page)
        let result = try XCTUnwrap(value as? [String:Any])
        XCTAssertEqual(result["image"] as? String,png.base64EncodedString())
        XCTAssertTrue((result["text"] as? String)?.contains("重读时补上自己的理解。") == true)
        XCTAssertTrue((result["text"] as? String)?.contains("assets/\(asset.uuidString).png") == true)
        XCTAssertEqual((result["names"] as? [String])?.count,2)
        try FileManager.default.removeItem(at:reader.pageNoteStore.directory)
        XCTAssertThrowsError(try NoteExportArchive.make(LibraryNotes.records(in:[reader.books[0]]),title:"缺失图片",libraryDirectory:root))
    }
    func testIPadPortraitLandscapeAndSplitViewRenderProductionNotes() async throws {
        let (root,reader,firstID,_) = try fixture()
        let (window,previous) = try window()
        let container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        for size in [CGSize(width:834,height:1194),CGSize(width:1194,height:834),CGSize(width:600,height:800)] {
            reader.showNoteGraph = true; reader.graphNoteID = nil
            reader.currentID = firstID
            let library = UIHostingController(rootView:ReaderNotesScene(reader:reader).frame(width:size.width,height:size.height))
            container.addChild(library); container.view.addSubview(library.view)
            library.view.frame = CGRect(origin:.zero,size:size); library.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(400))
            library.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size:size).image { _ in library.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "iPad-章节与笔记脉络-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            library.willMove(toParent:nil); library.view.removeFromSuperview(); library.removeFromParent()
            reader.currentID = firstID; reader.showNoteGraph = true
            reader.graphNoteID = reader.books[0].annotations?.first?.id
            let editor = UIHostingController(rootView:ReaderNotesScene(reader:reader).frame(width:size.width,height:size.height))
            container.addChild(editor); container.view.addSubview(editor.view)
            editor.view.frame = CGRect(origin:.zero,size:size); editor.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(400))
            editor.view.layoutIfNeeded()
            let page = UIGraphicsImageRenderer(size:size).image { _ in editor.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let editAttachment = XCTAttachment(image:page); editAttachment.name = "iPad-脉络内编辑-\(Int(size.width))x\(Int(size.height))"; editAttachment.lifetime = .keepAlways; add(editAttachment)
            XCTAssertNotNil(editor.view.window)
            editor.willMove(toParent:nil); editor.view.removeFromSuperview(); editor.removeFromParent()
        }
    }
    func testLibraryAndReadingChromeAtIPadWindowSizes() async throws {
        let (root,reader,firstID,_) = try fixture()
        let (window,previous) = try window()
        let container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        let filename = try XCTUnwrap(reader.books.first?.filename)
        for (title,author) in [("山海之间","林间"),("时间的形状","汪洁"),("读书与生活","胡适"),("看见世界","周行"),("给自己一间书房","陈书"),("漫长的旅途","叶舟")] {
            reader.books.append(LibraryBook(id:UUID(),title:title,author:author,filename:filename))
        }
        reader.books[0].locator = "epubcfi(/6/2!/4/2/1:0)"
        let sizes = [CGSize(width:1194,height:834),CGSize(width:834,height:1194),CGSize(width:600,height:800)]
        func capture<V: View>(_ view: V,name: String,size: CGSize) async throws {
            let host = UIHostingController(rootView:view.frame(width:size.width,height:size.height))
            container.addChild(host); container.view.addSubview(host.view)
            host.view.frame = CGRect(origin:.zero,size:size); host.didMove(toParent:container)
            try await Task.sleep(for:.milliseconds(650)); host.view.layoutIfNeeded()
            XCTAssertNotNil(host.view.window)
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
            host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        for size in sizes {
            try await capture(IPadLibraryView(reader:reader,importBooks:{},showRemote:{},showMacLibrary:{},open:{_ in},cancelDownload:{}),name:"iPad-阅读书库",size:size)
        }
        try await capture(IPadLibraryView(reader:reader,importBooks:{},showRemote:{},showMacLibrary:{},open:{_ in},cancelDownload:{}).environment(\.colorScheme,.dark),name:"iPad-书库深色",size:sizes[0])
        try await capture(IPadLibraryView(reader:reader,importBooks:{},showRemote:{},showMacLibrary:{},open:{_ in},cancelDownload:{}).environment(\.dynamicTypeSize,.accessibility1),name:"iPad-书库大字",size:sizes[2])
        reader.appearance = ReaderAppearance(); reader.appearance.theme = "light"
        reader.open(firstID)
        let host = UIViewController(); host.view.addSubview(reader.webView)
        reader.webView.frame = CGRect(x:0,y:0,width:834,height:1100)
        container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent:container)
        try await waitForBook(reader)
        host.willMove(toParent:nil); host.view.removeFromSuperview(); host.removeFromParent()
        let receiver = IPadReaderReceiver(reader:reader)
        for size in sizes {
            reader.readingControlsVisible = true
            try await capture(PhoneReadingView(reader:reader,ipadReceiver:receiver),name:"iPad-阅读工具",size:size)
        }
    }
    func testReadHorizonSurvivesReturningToEarlierChapterAndReopeningOnIPad() throws {
        let (root,reader,firstID,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        reader.currentID = firstID
        reader.acceptPosition(["mode":"scroll","locator":"earlier","chapter":"第一章","page":1,"pageCount":20,"progress":0.1,"canGoNext":true,"canGoPrevious":true])
        XCTAssertEqual(reader.noteVisibilityProgress,0.8)
        XCTAssertEqual(reader.bookNotesIndex.visibleNotes(through:reader.noteVisibilityProgress).count,1)
        reader.save()
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = firstID
        XCTAssertEqual(reopened.noteVisibilityProgress,0.8)
        XCTAssertEqual(reopened.currentBook?.progress,0.1)
    }
    func testUndownloadedGraphSelectionKeepsCurrentBookAndReportsMissingConnection() async throws {
        let (root,reader,firstID,secondID) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        reader.currentID = firstID; reader.showNoteGraph = true
        reader.books[1].filename = ""
        reader.openKnowledgeWorkspace(bookID:secondID)
        await reader.knowledgeOpenTask?.value
        XCTAssertEqual(reader.currentID,firstID)
        XCTAssertTrue(reader.showNoteGraph)
        XCTAssertEqual(reader.error,"请先连接这本书所在的 Mac")
        XCTAssertFalse(reader.loading)
        XCTAssertNil(reader.knowledgeOpenTask)
    }
    func testCloseBookWhileLoadingReturnsToLibraryAndKeepsReadingRecords() throws {
        let (root,reader,firstID,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        reader.currentID = firstID; reader.loading = true; reader.handwritingActive = true
        let original = reader.books.first { $0.id == firstID }
        reader.close()
        XCTAssertNil(reader.currentID)
        XCTAssertFalse(reader.loading)
        XCTAssertFalse(reader.busy)
        XCTAssertFalse(reader.handwritingActive)
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        let book = try XCTUnwrap(reopened.books.first { $0.id == firstID })
        XCTAssertEqual(book.annotations,original?.annotations)
        XCTAssertEqual(book.knowledgeRelations,original?.knowledgeRelations)
        XCTAssertEqual(book.progress,original?.progress)
    }
    func testQuickNoteOpensInGraphAfterPresentationFinishesOnlyForItsBook() throws {
        let (root,reader,firstID,secondID) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        reader.currentID = firstID
        reader.pendingGraphNote = (firstID,"note")
        XCTAssertFalse(reader.showNoteGraph)
        reader.finishQuickNotePresentation()
        XCTAssertTrue(reader.showNoteGraph)
        XCTAssertEqual(reader.graphNoteID,"note")
        XCTAssertNil(reader.pendingGraphNote)
        reader.showNoteGraph = false; reader.graphNoteID = nil
        reader.pendingGraphNote = (firstID,"stale"); reader.currentID = secondID
        reader.finishQuickNotePresentation()
        XCTAssertFalse(reader.showNoteGraph)
        XCTAssertNil(reader.graphNoteID)
        XCTAssertNil(reader.pendingGraphNote)
    }
    func testCatalogRefreshAddsMissingBooksAndAdoptsMatchingDownloadWithoutLosingNotes() throws {
        let (root,reader,firstID,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let receiver = UUID(), remote = UUID(), missing = UUID()
        reader.books[0].progressKey = "same-edition"
        let filename = reader.books[0].filename, notes = reader.books[0].annotations
        let catalog = [SharedLibraryBook(id:remote,title:"慢慢读懂一本书",author:"作者",lastRead:Date(),progressKey:"same-edition"),
                       SharedLibraryBook(id:missing,title:"黑天鹅",author:"塔勒布",lastRead:Date())]
        reader.applyMacCatalog(catalog,receiverID:receiver)
        reader.applyMacCatalog(catalog,receiverID:receiver)
        XCTAssertEqual(reader.books.count,3)
        let adopted = try XCTUnwrap(reader.books.first { $0.id == firstID })
        XCTAssertEqual(adopted.remoteBookID,remote)
        XCTAssertEqual(adopted.filename,filename)
        XCTAssertEqual(adopted.annotations,notes)
        XCTAssertEqual(reader.books.filter { $0.title == "黑天鹅" }.count,1)
        XCTAssertFalse(reader.isDownloaded(try XCTUnwrap(reader.books.first { $0.title == "黑天鹅" })))
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        XCTAssertEqual(reopened.books.count,3)
    }
}

final class BookGraphRoutingTests: XCTestCase {
    func testClearNeighborsUseOneContinuousCurveWithTheCaptionOnItsWire() {
        let note = CGRect(x:100,y:100,width:208,height:80)
        let person = CGRect(x:444,y:100,width:144,height:60)
        let curve = BookGraphRouting.connection(from:note,to:person,obstacles:[note,person])
        XCTAssertEqual(curve.points.first,CGPoint(x:note.maxX,y:note.midY))
        XCTAssertEqual(curve.points.last,CGPoint(x:person.minX,y:person.midY))
        var segments = 0
        curve.path.applyWithBlock { if $0.pointee.type == .addCurveToPoint { segments += 1 } }
        XCTAssertEqual(segments,1,"Unobstructed neighbors must not acquire grid detours or separate wires at the caption")
        let caption = BookGraphRouting.label(on:curve,obstacles:[note,person])
        XCTAssertFalse(caption.intersects(note)); XCTAssertFalse(caption.intersects(person))
        XCTAssertTrue(curve.points.contains { caption.contains($0) },"The label describes the existing wire without changing its course")
    }
    func testSmoothConnectionsKeepTheirEndpointsAndAvoidInterveningCards() {
        let note = CGRect(x:100,y:100,width:208,height:80)
        let person = CGRect(x:444,y:500,width:144,height:60)
        let intervening = CGRect(x:250,y:230,width:200,height:140)
        let curve = BookGraphRouting.connection(from:note,to:person,obstacles:[note,person,intervening])
        XCTAssertFalse(curve.points.isEmpty)
        XCTAssertTrue(curve.points.allSatisfy { !intervening.contains($0) })
        XCTAssertTrue(samples(curve.path).allSatisfy { !intervening.contains($0) },"Check the actual rendered curves, including rounded fallback corners")
        let reverse = BookGraphRouting.connection(from:person,to:note,obstacles:[note,person,intervening])
        XCTAssertFalse(reverse.points.isEmpty)
        XCTAssertTrue(samples(reverse.path).allSatisfy { !intervening.contains($0) })
    }
    private func samples(_ path: CGPath) -> [CGPoint] {
        var cursor = CGPoint.zero, values: [CGPoint] = []
        path.applyWithBlock { pointer in
            let e = pointer.pointee, start = cursor
            switch e.type {
            case .moveToPoint: cursor = e.points[0]; values.append(cursor)
            case .addLineToPoint:
                let end = e.points[0]
                values += (1...32).map { i in let t = CGFloat(i)/32; return CGPoint(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t) }
                cursor = end
            case .addQuadCurveToPoint:
                let a = e.points[0], end = e.points[1]
                values += (1...32).map { i in
                    let t = CGFloat(i)/32, u = 1-t
                    return CGPoint(x:u*u*start.x+2*u*t*a.x+t*t*end.x,y:u*u*start.y+2*u*t*a.y+t*t*end.y)
                }; cursor = end
            case .addCurveToPoint:
                let a = e.points[0], b = e.points[1], end = e.points[2]
                values += (1...64).map { i in
                    let t = CGFloat(i)/64, u = 1-t
                    return CGPoint(x:u*u*u*start.x+3*u*u*t*a.x+3*u*t*t*b.x+t*t*t*end.x,y:u*u*u*start.y+3*u*u*t*a.y+3*u*t*t*b.y+t*t*t*end.y)
                }; cursor = end
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return values
    }
    func testLabelsUseTheGapBetweenUnequalCardsInsteadOfDetouringOutside() {
        let note = CGRect(x:100,y:50,width:280,height:190)
        let person = CGRect(x:168,y:374,width:144,height:68)
        let label = BookGraphRouting.label(between:note,and:person,obstacles:[note,person])
        XCTAssertGreaterThan(label.minY,note.maxY)
        XCTAssertLessThan(label.maxY,person.minY)
        XCTAssertGreaterThanOrEqual(label.minX,note.minX)
        XCTAssertLessThanOrEqual(label.maxX,note.maxX)
        assertClear(BookGraphRouting.route(from:note,to:label,obstacles:[note,person,label]),cards:[note,person,label])
    }
    func testOverviewFitsBothAxesInLandscapePortraitAndNarrowWindows() {
        let canvas = CGSize(width:1100,height:850)
        for viewport in [CGSize(width:834,height:570),CGSize(width:834,height:360),CGSize(width:600,height:240)] {
            let scale = BookGraphViewportPosition.overviewScale(canvas:canvas,viewport:viewport)
            XCTAssertGreaterThan(scale,0)
            XCTAssertLessThanOrEqual(canvas.width*scale,viewport.width-32)
            XCTAssertLessThanOrEqual(canvas.height*scale,viewport.height-32)
        }
    }
    private func assertClear(_ points: [CGPoint],cards: [CGRect],file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertGreaterThan(points.count,1,file:file,line:line)
        for (a,b) in zip(points,points.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y,"Every segment must stay in a routing lane",file:file,line:line)
            for card in cards {
                XCTAssertFalse(BookGraphRouting.crosses(a,b,rect:card),"A wire must not pass through a card or label: \(card)",file:file,line:line)
            }
        }
    }
    func testLongLinksAvoidInterveningDiscussionsPeopleAndReservedLabels() {
        let note = CGRect(x:588,y:50,width:280,height:190)
        let discussion = CGRect(x:588,y:288,width:280,height:170)
        let first = CGRect(x:658,y:500,width:140,height:56)
        let second = CGRect(x:658,y:632,width:140,height:56)
        var obstacles = [note,discussion,first,second]
        var links: [(CGRect,CGRect,CGRect)] = []
        for (source,target) in [(note,first),(discussion,first),(second,first)] {
            let label = BookGraphRouting.label(between:source,and:target,obstacles:obstacles)
            XCTAssertGreaterThanOrEqual(label.minX,0); XCTAssertGreaterThanOrEqual(label.minY,0)
            XCTAssertFalse(obstacles.contains { $0.intersects(label) },"Labels need their own space")
            obstacles.append(label); links.append((source,target,label))
        }
        var paths: [[CGPoint]] = []
        for (source,target,label) in links {
            for (a,b) in [(source,label),(label,target)] {
                let route = BookGraphRouting.route(from:a,to:b,obstacles:obstacles,existing:paths)
                assertClear(route,cards:obstacles)
                paths.append(route)
            }
        }
        let reverse = BookGraphRouting.route(from:second,to:note,obstacles:obstacles)
        assertClear(reverse,cards:obstacles)
    }
    func testIndependentConnectionsUseSeparateLanesInsteadOfOverprinting() {
        let source = CGRect(x:100,y:100,width:280,height:190)
        let blocker = CGRect(x:100,y:340,width:280,height:170)
        let target = CGRect(x:170,y:560,width:140,height:56)
        let obstacles = [source,blocker,target]
        let first = BookGraphRouting.route(from:source,to:target,obstacles:obstacles)
        let second = BookGraphRouting.route(from:source,to:target,obstacles:obstacles,existing:[first])
        assertClear(first,cards:obstacles); assertClear(second,cards:obstacles)
        XCTAssertNotEqual(first,second,"Separate edges should not disappear into the same wire")
    }
}
