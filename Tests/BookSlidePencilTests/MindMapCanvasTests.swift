import XCTest
import SwiftUI
import UIKit
import WebKit
import PencilKit
@testable import BookSlidePhone

@MainActor final class MindMapCanvasTests: XCTestCase {
    private var debugWeb: WKWebView?
    private var debugReader: ReaderModel?
    private weak var debugHost: UIView?
    private var stage = "开始"
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        if let web = debugWeb, let value = try? await web.callAsyncJavaScript("return JSON.stringify({view:[innerWidth,innerHeight,visualViewport.width],card:document.querySelector('.book-node-expanded')?.getBoundingClientRect(),state:window.bookMindMap?.inspect()})",arguments:[:],in:nil,contentWorld:.page) { print("MIND_TIMEOUT \(stage) JS=\(value)") }
        print("MIND_TIMEOUT_NATIVE \(stage) selection=\(String(describing:debugReader?.selectedReadingItem)) discussion=\(debugReader?.discussionNoteID ?? "nil") \(debugReader?.currentAnnotations.map { ($0.id,$0.title ?? "",$0.discussion != nil) } ?? []) error=\(debugReader?.error ?? "")")
        if let view = debugHost {
            func fields(_ view: UIView) -> [String] { (view.accessibilityIdentifier.map { [String(describing:type(of:view))+":"+$0] } ?? []) + view.subviews.flatMap(fields) }
            print("MIND_TIMEOUT_VIEWS \(fields(view))")
            let image = UIGraphicsImageRenderer(size:view.bounds.size).image { _ in view.drawHierarchy(in:view.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "MindMap-timeout"; attachment.lifetime = .keepAlways; add(attachment)
        }
        throw NSError(domain:"MindMapCanvasTests",code:1,userInfo:[NSLocalizedDescriptionKey:"导图操作超时："+stage])
    }
    private func overlapFixture() async throws -> (ReaderModel,UIHostingController<BookNotesWorkspace>,UIWindow,UIWindow?,WKWebView,[String]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader=ReaderModel(directory:root,loadExternalSources:false), bookID=UUID()
        var notes=(0..<4).map { i in
            var n=ReaderAnnotation(cfi:"",quote:"原文",chapter:"第一章",progress:0,note:"有旧标题的笔记也只显示正文。")
            n.title=i==0 ? "把读到的内容写成自己的理解。" : "相邻笔记 \(i)"
            n.chapterHref="one.xhtml";return n
        }
        notes[3].chapterHref="two.xhtml"
        reader.books=[LibraryBook(id:bookID,title:"阅读脉络",author:"",filename:"",annotations:notes)];reader.currentID=bookID
        reader.chapters=[.init(id:"one",href:"one.xhtml",title:"第一章",depth:0),.init(id:"two",href:"two.xhtml",title:"第二章",depth:0)]
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),container=UIViewController()
        window.rootViewController=container;window.makeKeyAndVisible()
        let host=UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        container.addChild(host);container.view.addSubview(host.view);host.view.frame=CGRect(x:0,y:0,width:834,height:600);host.didMove(toParent:container)
        let web=try await auditReadyMap(host.view)
        try await Task.sleep(for:.milliseconds(350))
        return (reader,host,window,previous,web,notes.map { reader.mindMapToken(.init(.note,$0.id)) })
    }
    private func closeOverlapFixture(_ reader:ReaderModel,_ window:UIWindow,_ previous:UIWindow?) {
        reader.close();window.isHidden=true;window.rootViewController=nil;previous?.makeKey()
        try? FileManager.default.removeItem(at:reader.directory)
    }
    func testOpenMapTracksReadingThemeWithoutLosingSelection() async throws {
        let (reader,_,window,previous,web,tokens) = try await overlapFixture()
        defer { closeOverlapFixture(reader,window,previous) }
        let node = try XCTUnwrap(tokens.first)
        _ = try await web.callAsyncJavaScript("""
            window.bookMindMap.command({id:crypto.randomUUID(),name:'select',target:node});
            """,arguments:["node":node],in:nil,contentWorld:.page)
        for theme in ["light","night","paper"] {
            reader.appearance.theme = theme
            let colors = ReadingGraphColors(theme:theme)
            stage = "切换阅读主题 " + theme
            try await wait {
                try await web.callAsyncJavaScript("""
                    const style=getComputedStyle(document.documentElement);
                    return style.getPropertyValue('--paper').trim()===canvas &&
                      style.getPropertyValue('--card').trim()===card &&
                      style.getPropertyValue('--accent').trim()===accent &&
                      style.colorScheme===scheme && window.bookMindMap.inspect().selected===node;
                    """,arguments:["canvas":colors.canvas.css,"card":colors.card.css,"accent":colors.accent.css,
                                   "scheme":colors.dark ? "dark" : "light","node":node],in:nil,contentWorld:.page) as? Bool == true
            }
        }
    }

    func testNodeContentExpandsInsideItsCardAndReflowsNeighbours() async throws {
        let (reader,host,window,previous,web,tokens)=try await overlapFixture()
        defer { closeOverlapFixture(reader,window,previous) }
        debugWeb=web;debugReader=reader;debugHost=host.view
        let collapsed = try await web.callAsyncJavaScript("""
        const card=document.querySelector('[data-nodeid="me'+token+'"]');
        return card.text.textContent==='有旧标题的笔记也只显示正文。' && !card.querySelector('.book-note-preview');
        """,arguments:["token":tokens[0]],in:nil,contentWorld:.page)
        XCTAssertEqual(collapsed as? Bool,true)
        _ = try await web.callAsyncJavaScript("""
        window.bookMindMap.command({id:crypto.randomUUID(),name:'select',target:token});
        const card=document.querySelector('[data-nodeid="me'+token+'"]'),r=card.getBoundingClientRect();
        for(const type of ['pointerdown','pointerup'])card.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:51,clientX:r.x+20,clientY:r.y+20,button:0}));return true;
        """,arguments:["token":tokens[0]],in:nil,contentWorld:.page)
        for size in [CGSize(width:834,height:600),CGSize(width:600,height:800),CGSize(width:1194,height:834)] {
            host.view.frame.size=size;host.view.layoutIfNeeded()
            try await Task.sleep(for:.milliseconds(350))
            stage="expanded card \(size)"
            try await wait { try await web.callAsyncJavaScript("""
            const cards=[...document.querySelectorAll('.me-tpc')],card=cards.find(c=>c.nodeObj.id===token),slot=card?.querySelector('.book-native-content');
            if(!slot || document.querySelectorAll('.book-node-expanded').length!==1)return false;
            const r=card.getBoundingClientRect(),s=slot.getBoundingClientRect();
            const overlaps=(a,b)=>a.left<b.right-1 && a.right>b.left+1 && a.top<b.bottom-1 && a.bottom>b.top+1;
            return Math.abs(innerWidth-width)<1 && Math.abs(innerHeight-height)<1 && window.bookMindMap.inspect().expandedNode===token && r.width>300 && s.height>=60 &&
              s.left>=r.left && s.right<=r.right+1 && s.top>=r.top && s.bottom<=r.bottom+1 &&
              r.left>=0 && r.right<=innerWidth+1 && r.top>=0 && r.bottom<=innerHeight+1 &&
              getComputedStyle(card.querySelector('.text')).display==='none' && !card.querySelector('.book-note-preview') &&
              cards.every(c=>c===card || !overlaps(r,c.getBoundingClientRect()));
            """,arguments:["token":tokens[0],"width":web.bounds.width,"height":web.bounds.height],in:nil,contentWorld:.page) as? Bool == true }
            let image=UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
            let attachment=XCTAttachment(image:image);attachment.name="节点原位展开-\(Int(size.width))x\(Int(size.height))";attachment.lifetime = .keepAlways;add(attachment)
        }
        _ = try await web.callAsyncJavaScript("""
        const card=document.querySelector('.book-node-expanded'),r=card.getBoundingClientRect();
        for(const type of ['pointerdown','pointerup'])card.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:52,clientX:r.x+20,clientY:r.y+20,button:0}));
        card.dispatchEvent(new MouseEvent('click',{bubbles:true,button:0}));return true;
        """,arguments:[:],in:nil,contentWorld:.page)
        stage="collapse expanded card"
        try await wait { try await web.callAsyncJavaScript("return !window.bookMindMap.inspect().editor && !document.querySelector('.book-node-expanded,.book-native-content')",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        XCTAssertEqual(reader.currentAnnotations.count,4)
        XCTAssertTrue(reader.currentAnnotations.allSatisfy { $0.note=="有旧标题的笔记也只显示正文。" })
    }
    func testTopicEditingUsesOneCardAndReflowsWithoutCoveringAdjacentNodes() async throws {
        let (reader,host,window,previous,web,tokens)=try await overlapFixture()
        defer { closeOverlapFixture(reader,window,previous) }
        let text=String(repeating:"把读到的内容写成自己的理解。\n",count:8).trimmingCharacters(in:.whitespacesAndNewlines)
        _ = try await web.callAsyncJavaScript("""
        window.bookMindMap.command({id:crypto.randomUUID(),name:'edit',target:token});
        window.overlapInput=document.getElementById('input-box');
        if(overlapInput.textContent!=='有旧标题的笔记也只显示正文。')throw Error('Expected the body in the editor');
        overlapInput.textContent=text;
        overlapInput.dispatchEvent(new Event('input',{bubbles:true}));return true;
        """,arguments:["token":tokens[0],"text":text],in:nil,contentWorld:.page)
        for size in [CGSize(width:834,height:600),CGSize(width:360,height:460),CGSize(width:480,height:380),CGSize(width:1194,height:834)] {
            host.view.frame.size=size;host.view.layoutIfNeeded()
            try await Task.sleep(for:.milliseconds(350))
            print("OVERLAP_SIZE \(size)")
            do { try await auditWait {
                try await web.callAsyncJavaScript("""
                const input=document.getElementById('input-box'),card=input?.closest('.me-tpc');
                window.overlapDebug={card:!!card,same:input===overlapInput,active:document.activeElement?.outerHTML?.slice(0,100),text:input?.textContent,expected:text};
                if(!card || input!==overlapInput || document.activeElement!==input || input.textContent!==text)return false;
                const r=input.getBoundingClientRect(),c=card.getBoundingClientRect();
                const overlaps=(a,b)=>a.left<b.right-1 && a.right>b.left+1 && a.top<b.bottom-1 && a.bottom>b.top+1;
                window.overlapDebug={...window.overlapDebug,input:r.toJSON(),card:c.toJSON(),vw:innerWidth,vh:innerHeight,hidden:getComputedStyle(card.text).display,outline:getComputedStyle(card).outlineWidth,border:getComputedStyle(input).borderTopWidth,position:getComputedStyle(input).position,actions:!document.getElementById('actions'),collisions:Array.from(document.querySelectorAll('.me-tpc')).filter(n=>n!==card && overlaps(c,n.getBoundingClientRect())).map(n=>[n.nodeObj.topic,n.getBoundingClientRect().toJSON()])};
                return Math.abs(innerWidth-width)<1 && Math.abs(innerHeight-height)<1 &&
                  c.left>=0 && c.right<=innerWidth && c.top>=0 && c.bottom<=innerHeight &&
                  r.left>=c.left && r.right<=c.right && r.top>=c.top && r.bottom<=c.bottom &&
                  r.left>=0 && r.right<=innerWidth && r.top>=0 && r.bottom<=innerHeight &&
                  getComputedStyle(card.text).display==='none' && getComputedStyle(card).outlineStyle==='none' &&
                  getComputedStyle(input).borderTopWidth==='0px' && getComputedStyle(input).position==='static' &&
                  !document.getElementById('actions') &&
                  Array.from(document.querySelectorAll('.me-tpc')).every(n=>n===card || !overlaps(c,n.getBoundingClientRect()));
                """,arguments:["text":text,"width":web.bounds.width,"height":web.bounds.height],in:nil,contentWorld:.page) as? Bool == true
            }
            } catch {
                let details=try? await web.callAsyncJavaScript("return JSON.stringify(window.overlapDebug)",arguments:[:],in:nil,contentWorld:.page)
                print("OVERLAP_LAYOUT_FAILURE \(String(describing:details))")
                throw error
            }
            let attachment=XCTAttachment(image:try await web.takeSnapshot(configuration:nil))
            attachment.name="单一卡片编辑-\(Int(size.width))x\(Int(size.height))";attachment.lifetime = .keepAlways;add(attachment)
        }
        _ = try await web.callAsyncJavaScript("document.getElementById('input-box').blur();return true",arguments:[:],in:nil,contentWorld:.page)
        try await auditWait { reader.currentAnnotations.contains { $0.note==text } }
        let committed=try await web.callAsyncJavaScript("return !document.querySelector('.book-topic-editing') && !document.getElementById('input-box')",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(committed as? Bool,true)
        _ = try await web.callAsyncJavaScript("""
        window.bookMindMap.command({id:crypto.randomUUID(),name:'edit',target:token});
        const input=document.getElementById('input-box');input.textContent='这次修改应取消';
        input.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true;
        """,arguments:["token":tokens[0]],in:nil,contentWorld:.page)
        XCTAssertTrue(reader.currentAnnotations.contains { $0.note==text },"Cancelling the edit preserves the saved content")
        XCTAssertEqual(reader.currentAnnotations.filter { $0.note=="有旧标题的笔记也只显示正文。" }.count,3)
    }
    func testSelectionKeepsCardFootprintAfterPanning() async throws {
        let (reader,host,window,previous,web,tokens)=try await overlapFixture()
        defer { closeOverlapFixture(reader,window,previous) }
        for size in [CGSize(width:360,height:460),CGSize(width:600,height:700),CGSize(width:1194,height:834)] {
            host.view.frame.size=size;host.view.layoutIfNeeded()
            let result=try await web.callAsyncJavaScript("""
            const pause=()=>new Promise(r=>setTimeout(r,100));
            const check=(v,m)=>{if(!v)throw Error(m);};
            const overlaps=(a,b)=>a.left<b.right-1 && a.right>b.left+1 && a.top<b.bottom-1 && a.bottom>b.top+1;
            window.bookMindMap.command({id:crypto.randomUUID(),name:'center'});await pause();
            window.bookMindMap.command({id:crypto.randomUUID(),name:'select',target:token});await pause();
            const selected=document.querySelector('[data-nodeid="me'+token+'"]');
            const panTo=async(x,y)=>{
              const r=selected.getBoundingClientRect(),container=document.querySelector('.map-container');
              for(const [type,px,py] of [['pointerdown',20,80],['pointermove',20+x-r.x,80+y-r.y],['pointerup',20+x-r.x,80+y-r.y]])
                container.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:65,clientX:px,clientY:py,button:0}));
              await pause();
              window.bookMindMap.command({id:crypto.randomUUID(),name:'select',target:token});await pause();
            };
            const initial=selected.getBoundingClientRect();
            for(const [x,y] of [[innerWidth/2-100,innerHeight/2-30],[innerWidth-120,180],[-40,180],[80,40],[80,innerHeight-100]]) {
              await panTo(x,y);
              const cards=Array.from(document.querySelectorAll('.me-tpc')).map(n=>n.getBoundingClientRect());
              const expanders=Array.from(document.querySelectorAll('.me-epd')).map(n=>n.getBoundingClientRect());
              check(expanders.every(r=>cards.every(n=>!overlaps(r,n))),'Branch fold control covers a card');
              const card=selected.getBoundingClientRect();
              check(Math.abs(card.width-initial.width)<1 && Math.abs(card.height-initial.height)<1,'Panning changed card size');
              check(!selected.querySelector('button'),'Collapsed cards reserve no space for commands');
            }
            return true;
            """,arguments:["token":tokens[0]],in:nil,contentWorld:.page)
            XCTAssertEqual(result as? Bool,true)
        }
    }

    func testConversationAndItsExistingLinksStayOnTheirOwnerAfterReloadAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:directory,loadExternalSources:false), bookID = UUID()
        defer { reader.close(); try? FileManager.default.removeItem(at:directory) }
        var entity = BookEntity(name:"Mei",kind:.person,aliases:["梅"])
        entity.note = "初次出场"
        var note = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0,note:"相关摘录")
        note.attributes = .init(name:"初遇",kind:.event,aliases:["相遇"])
        reader.books = [.init(id:bookID,title:"阅读",author:"",filename:"",annotations:[note])]
        reader.currentID = bookID
        XCTAssertNotNil(reader.saveKnowledgeEntity(entity))
        let source = ReadingNodeID(.entity,entity.id.uuidString)
        let thread = try XCTUnwrap(reader.beginReadingNodeDiscussion(source))
        let edge = try XCTUnwrap(reader.connectReadingNodes(from:thread,to:.init(.note,note.id),label:"引用",bookID:bookID))
        let initial = reader.mindMapDocument(includeFuture:true)
        let token = try XCTUnwrap(initial.topic(containing:thread)?.id)
        XCTAssertEqual(initial.topic(containing:source)?.id,token)
        XCTAssertEqual(initial.topic(containing:.init(.note,thread.owner))?.id,token)
        XCTAssertEqual(initial.arrows.first { $0.edgeID == edge }?.from,token)
        var deleted = initial
        deleted.nodeData.children.removeAll { $0.id == token }
        deleted.arrows.removeAll { $0.from == token || $0.to == token }
        XCTAssertTrue(reader.applyMindMapDocument(deleted,baseline:initial,bookID:bookID))
        XCTAssertFalse(reader.currentAnnotations.contains { $0.id == thread.owner })
        XCTAssertTrue(reader.applyMindMapDocument(initial,baseline:reader.mindMapDocument(includeFuture:true),bookID:bookID))
        let reopened = ReaderModel(directory:directory,loadExternalSources:false)
        reopened.currentID = bookID
        defer { reopened.close() }
        XCTAssertEqual(reopened.currentBook?.graph.entities.first { $0.id == entity.id }?.note,entity.note)
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == note.id }?.attributes,note.attributes)
        XCTAssertEqual(reopened.beginReadingNodeDiscussion(source),thread)
        XCTAssertEqual(reopened.mindMapDocument(includeFuture:true).topic(containing:thread)?.id,token)
        XCTAssertTrue(reopened.currentBook?.graph.searchEdges("").contains { $0.id == edge } == true)
    }

    func testLibraryCanvasEditsBranchesAndUndoWithoutLosingNotesOrAI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        var note = ReaderAnnotation(cfi:"",quote:"原文中的一段话",chapter:"阅读与理解",progress:0.2,note:String(repeating:"这是原来的内容，改主题和拖动分支时不能丢失。",count:80))
        note.title = "阅读与理解"; note.chapterHref = "chapter.xhtml"
        var chat = ReaderDiscussion(); chat.messages = [.init(role:.user,text:"如何把阅读变成自己的理解？"),.init(role:.assistant,text:"从一个具体的问题开始，并把证据连起来。")]; note.discussion = chat
        reader.books = [.init(id:bookID,title:"阅读的结构",author:"",filename:"",annotations:[note])]; reader.currentID = bookID
        reader.chapters = [.init(id:"chapter",href:"chapter.xhtml",title:"阅读与理解",depth:0)]
        reader.showNoteGraph = true; reader.selectReadingItem(.node(.init(.note,note.id)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene), container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        container.addChild(host); container.view.addSubview(host.view); host.view.frame = CGRect(x:0,y:0,width:834,height:1194); host.didMove(toParent:container)
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView, web.accessibilityIdentifier == "book-note-graph-viewport" { return web }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        try await wait { find(host.view) != nil }
        let web = try XCTUnwrap(find(host.view)); debugWeb = web; debugReader = reader; debugHost = host.view
        stage = "载入"
        try await wait { try await web.callAsyncJavaScript("return window.bookMindMap?.inspect().ready || false",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        let touchHeight = try await web.callAsyncJavaScript("return getComputedStyle(document.querySelector('.me-tpc')).minHeight",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertGreaterThanOrEqual(Double((touchHeight as? String ?? "").replacingOccurrences(of:"px",with:"")) ?? 0,44,"Nodes need an iPad-sized touch target")
        let chrome = try await web.callAsyncJavaScript("return !document.getElementById('node-tools') && ![...document.querySelectorAll('.tags')].some(e=>e.textContent==='笔记')",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(chrome as? Bool,true,"The map uses ordinary nodes and has no permanent add-button row")
        let nodeHeight = try await web.callAsyncJavaScript("return document.querySelector('[data-nodeid=\"me'+id+'\"]').getBoundingClientRect().height",arguments:["id":note.id],in:nil,contentWorld:.page) as? Double
        XCTAssertLessThan(try XCTUnwrap(nodeHeight),160,"A long body must stay within a compact node preview")
        XCTAssertGreaterThan(web.bounds.height,host.view.bounds.height*0.75,"The graph is the workspace, with no permanent bottom editor")
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'select-parent',name:'add',target:id});return true",arguments:["id":note.id],in:nil,contentWorld:.page)
        stage = "添加分支"; try await wait { reader.currentAnnotations.count == 2 }
        let child = try XCTUnwrap(reader.currentAnnotations.first { $0.id != note.id })
        let token = reader.mindMapToken(.init(.note,child.id))
        try await Task.sleep(for:.milliseconds(300))
        let inline = try await web.callAsyncJavaScript("return !!document.getElementById('input-box')",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(inline as? Bool,true,"Saving a new branch must keep its inline text editor mounted")
        _ = try await web.callAsyncJavaScript("const editor=document.getElementById('input-box'); if(editor){editor.focus();editor.textContent='理解来自连接';editor.dispatchEvent(new Event('input',{bubbles:true}));editor.dispatchEvent(new FocusEvent('blur'));}return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "改名"; try await wait { reader.currentAnnotations.first(where:{ $0.id == child.id })?.note == "理解来自连接" }
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains { $0.id.source == .init(.note,note.id) && $0.id.target == .init(.note,child.id) && $0.label == "子主题" } == true)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,note.note)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.discussion,chat)
        let noPanel = try await web.callAsyncJavaScript("return !window.bookMindMap.inspect().editor",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(noPanel as? Bool,true,"Adding a node edits its text in place without covering the canvas")
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'overview',name:'center'});return true",arguments:[:],in:nil,contentWorld:.page)
        try await Task.sleep(for:.milliseconds(350))
        for size in [CGSize(width:834,height:1194),CGSize(width:1194,height:834)] {
            host.view.frame.size = size; host.view.layoutIfNeeded(); try await Task.sleep(for:.milliseconds(300))
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "Mind-Elixir-iPad-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
        }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'undo-name',name:'undo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "撤销"; try await wait { reader.currentAnnotations.first(where:{ $0.id == child.id })?.note == "" }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'redo-name',name:'redo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "重做"; try await wait { reader.currentAnnotations.first(where:{ $0.id == child.id })?.note == "理解来自连接" }
        // Restore the physical simulator viewport before checking the popup.
        host.view.frame.size = CGSize(width:834,height:1194); host.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(300))
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'sibling'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "直接添加节点"; try await wait { reader.currentAnnotations.count == 3 }
        let standalone = try XCTUnwrap(reader.currentAnnotations.first { $0.id != note.id && $0.id != child.id })
        let standaloneToken = reader.mindMapToken(.init(.note,standalone.id))
        XCTAssertTrue(try reader.mindMapDocument().flattened().contains { $0.topic.id == standaloneToken && $0.parent == note.id },"Adding a sibling keeps the selected node’s parent")
        try await wait { try await web.callAsyncJavaScript("return !!document.getElementById('input-box')",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        _ = try await web.callAsyncJavaScript("const field=document.getElementById('input-box');field.textContent='阅读证据';field.dispatchEvent(new Event('input',{bubbles:true}));field.blur();return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "命名独立节点"; try await wait { reader.currentAnnotations.first(where:{ $0.id == standalone.id })?.note == "阅读证据" }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'overview-connections',name:'center'});return true",arguments:[:],in:nil,contentWorld:.page)
        try await Task.sleep(for:.milliseconds(350))
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'connect'});return true",arguments:[:],in:nil,contentWorld:.page)
        let step1 = try await web.callAsyncJavaScript("return document.getElementById('node-status').textContent",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertTrue((step1 as? String)?.contains("选择连线起点") == true,"Connection mode explicitly asks for the start node")
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'pick-start',name:'select',target:id});return true",arguments:["id":standaloneToken],in:nil,contentWorld:.page)
        let step2 = try await web.callAsyncJavaScript("return document.getElementById('node-status').textContent",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertTrue((step2 as? String)?.contains("阅读证据") == true)
        XCTAssertTrue((step2 as? String)?.contains("选择要连接的节点") == true)
        _ = try await web.callAsyncJavaScript("document.getElementById('cancel-link').click();return true",arguments:[:],in:nil,contentWorld:.page)
        let cancelled = try await web.callAsyncJavaScript("return document.getElementById('cancel-link').hidden && document.getElementById('node-status').textContent.includes('已取消') && !document.getElementById('actions')",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(cancelled as? Bool,true,"Cancel restores normal node actions without creating an edge")
        let directConnect = try await web.callAsyncJavaScript("""
        window.bookMindMap.command({id:crypto.randomUUID(),name:'connectSelection'});
        return document.getElementById('node-status').textContent.includes('已选「阅读证据」');
        """,arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(directConnect as? Bool,true,"The canvas command starts the connection from the selected node")
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'pick-end',name:'select',target:id});return true",arguments:["id":token],in:nil,contentWorld:.page)
        let step3 = try await web.callAsyncJavaScript("return !document.getElementById('connect').hidden && document.getElementById('save-connection').disabled && document.getElementById('connection-endpoints').textContent.includes('阅读证据') && document.querySelectorAll('.book-connection-source,.book-connection-target').length===2",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(step3 as? Bool,true,"Both endpoints stay highlighted and a relationship name is required")
        let endpointStyles = try await web.callAsyncJavaScript("return getComputedStyle(document.querySelector('.book-connection-source')).outlineStyle==='solid' && getComputedStyle(document.querySelector('.book-connection-target')).outlineStyle==='dashed'",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(endpointStyles as? Bool,true,"Start and end must have visible, distinct outlines")
        try await Task.sleep(for:.milliseconds(250))
        let linkImage = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let linkAttachment = XCTAttachment(image:linkImage); linkAttachment.name = "iPad-连接节点三步提示"; linkAttachment.lifetime = .keepAlways; add(linkAttachment)
        _ = try await web.callAsyncJavaScript("const relation=document.getElementById('relation');relation.value='支持';relation.dispatchEvent(new Event('input'));document.getElementById('save-connection').click();return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "确认节点连接"; try await wait { reader.currentBook?.graph.searchEdges("").contains { $0.id.source == .init(.note,standalone.id) && $0.id.target == .init(.note,child.id) && $0.label == "支持" } == true }
        let complete = try await web.callAsyncJavaScript("return document.getElementById('connect').hidden && document.getElementById('cancel-link').hidden && document.getElementById('node-status').textContent.includes('已连接')",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(complete as? Bool,true)
        var revisedNote = note
        revisedNote.note = "连线之后在展开卡片中写下的新内容。"
        XCTAssertTrue(reader.autosaveGraphAnnotation(revisedNote,bookID:bookID,relation:nil))
        stage = "展开编辑后的正文同步到画布"
        try await wait { try await web.callAsyncJavaScript("""
        return document.querySelector('[data-nodeid="me'+id+'"]')?.nodeObj.topic===body;
        """,arguments:["id":note.id,"body":revisedNote.note],in:nil,contentWorld:.page) as? Bool == true }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'undo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "撤销连线时保留新的正文"
        try await wait { reader.currentBook?.graph.searchEdges("").contains { $0.label == "支持" } == false }
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,revisedNote.note)
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'redo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "重做连线时保留新的正文"
        try await wait { reader.currentBook?.graph.searchEdges("").contains { $0.label == "支持" } == true }
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,revisedNote.note)
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'select-ai',name:'edit',target:id}); const field=document.getElementById('input-box');if(field)field.dispatchEvent(new FocusEvent('blur'));window.bookMindMap.command({id:crypto.randomUUID(),name:'ai'});return true",arguments:["id":token],in:nil,contentWorld:.page)
        stage = "添加 AI 对话"; try await wait { reader.currentBook?.graph.node(.init(.discussion,child.id)) != nil }
        // SwiftUI can defer the UIKit backing view of an unfocused TextEditor.
        // Verify the mounted native editor contract, not that private view type.
        stage = "打开 AI 编辑"; try await wait {
            guard reader.selectedReadingItem == .node(.init(.discussion,child.id)) else { return false }
            return try await web.callAsyncJavaScript("return window.bookMindMap.inspect().editor",arguments:[:],in:nil,contentWorld:.page) as? Bool == true
        }
        let withChat = reader.mindMapDocument()
        XCTAssertEqual(withChat.topic(containing:.init(.discussion,child.id))?.id,token)
        XCTAssertFalse(try withChat.flattened().contains { $0.topic.metadata?.kind == "discussion" })
        XCTAssertGreaterThan(web.bounds.height,host.view.bounds.height*0.75,"Opening AI must keep the canvas mounted at full size")
        try await Task.sleep(for:.milliseconds(250))
        let popupImage = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let popupAttachment = XCTAttachment(image:popupImage); popupAttachment.name = "iPad-节点旁的-AI-对话"; popupAttachment.lifetime = .keepAlways; add(popupAttachment)
        let rendered = try await web.callAsyncJavaScript("const visit=n=>n.id===id?n.topic:(n.children||[]).map(visit).find(Boolean);return visit(window.bookMindMap.inspect().data.nodeData)",arguments:["id":token],in:nil,contentWorld:.page)
        XCTAssertEqual(rendered as? String,"理解来自连接","Opening AI must not replay stale node text after redo")
        // A late acknowledgement of the discussion must not take back a new selection.
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'select-delete',name:'select',target:id});return true",arguments:["id":standaloneToken],in:nil,contentWorld:.page)
        stage = "选中另一个节点后，操作入口跟随选区"
        try await Task.sleep(for:.milliseconds(300))
        let active = try await web.callAsyncJavaScript("return window.bookMindMap.inspect().selected",arguments:[:],in:nil,contentWorld:.page) as? String
        XCTAssertEqual(active,standaloneToken)
        let countBeforeDeletion = reader.currentAnnotations.count
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'remove',target:'missing-node'});return true",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(reader.currentAnnotations.count,countBeforeDeletion,"A stale command target must never delete the currently selected node")
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'remove',target:id});return true",arguments:["id":standaloneToken],in:nil,contentWorld:.page)
        stage = "删除节点"; try await wait { !reader.currentAnnotations.contains { $0.id == standalone.id } }
        XCTAssertTrue(reader.removedNotes.contains { $0.annotation?.id == standalone.id })
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:'undo-delete',name:'undo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage = "撤销删除"; try await wait { reader.currentAnnotations.contains { $0.id == standalone.id } }
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == standalone.id }?.note,"阅读证据")
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID; reopened.chapters = reader.chapters
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == child.id }?.note,"理解来自连接")
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == standalone.id }?.note,"阅读证据")
        XCTAssertTrue(reopened.currentBook?.graph.searchEdges("").contains { $0.id.source == .init(.note,standalone.id) && $0.id.target == .init(.note,child.id) && $0.label == "支持" } == true)
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == note.id }?.discussion,chat)
        XCTAssertTrue(try reopened.mindMapDocument().flattened().contains { $0.topic.id == token && $0.parent == note.id })
    }
    func testTouchDragReparentsAndReordersThenRestoresFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        var first = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0,note:"移动后仍然保留的内容")
        first.title = "拖动这张笔记"; first.chapterHref = "one.xhtml"
        var second = ReaderAnnotation(cfi:"",quote:"",chapter:"第二章",progress:0,note:"用于承接分支的内容")
        second.title = "目标笔记"; second.chapterHref = "two.xhtml"
        reader.books = [.init(id:bookID,title:"阅读脉络",author:"",filename:"",annotations:[first,second])]
        reader.currentID = bookID
        reader.chapters = [.init(id:"one",href:"one.xhtml",title:"第一章",depth:0),.init(id:"two",href:"two.xhtml",title:"第二章",depth:0)]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene), container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let host = UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        container.addChild(host); container.view.addSubview(host.view)
        host.view.frame = CGRect(x:0,y:0,width:834,height:1194); host.didMove(toParent:container)
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        func find(_ view: UIView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap(find).first }
        try await wait { find(host.view) != nil }
        let web = try XCTUnwrap(find(host.view)); debugWeb = web; debugReader = reader; debugHost = host.view
        stage = "拖动画布载入"
        try await wait { try await web.callAsyncJavaScript("return window.bookMindMap?.inspect().ready || false",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        let drag = """
        window.bookMindMap.command({id:crypto.randomUUID(),name:'center'});
        const from=document.querySelector('[data-nodeid="me'+source+'"]'), to=document.querySelector('[data-nodeid="me'+target+'"]');
        const a=from.getBoundingClientRect(), b=to.getBoundingClientRect();
        const x=a.x+a.width/2,y=a.y+a.height/2,tx=b.x+b.width/2,ty=b.y+b.height*fraction;
        for(const [type,px,py] of [['pointerdown',x,y],['pointermove',tx,ty],['pointerup',tx,ty]])
          from.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:91,clientX:px,clientY:py,button:0}));
        return true;
        """
        let source=reader.mindMapToken(.init(.note,first.id)), target=reader.mindMapToken(.init(.note,second.id))
        let pinch = try await web.callAsyncJavaScript("""
        const pause=()=>new Promise(r=>setTimeout(r,80));
        const pinch=async(onNode,factor)=>{
          const node=onNode?document.querySelector('[data-nodeid="me'+source+'"]'):document.querySelector('.map-container');
          const r=node.getBoundingClientRect(),cx=onNode?r.x+r.width/2:160,cy=onNode?r.y+r.height/2:160;
          const distance=onNode?Math.min(r.width*.35,50):50;
          const send=(type,id,x)=>node.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:id,clientX:x,clientY:cy,button:0}));
          const before=window.bookMindMap.inspect().scale;
          send('pointerdown',81,cx-distance);send('pointerdown',82,cx+distance);
          send('pointermove',81,cx-distance*factor);send('pointermove',82,cx+distance*factor);
          send('pointerup',81,cx-distance*factor);send('pointerup',82,cx+distance*factor);
          await pause();return window.bookMindMap.inspect().scale/before;
        };
        const nodeOut=await pinch(true,1.5),nodeIn=await pinch(true,.7),blankOut=await pinch(false,1.4),blankIn=await pinch(false,.7);
        return [nodeOut,nodeIn,blankOut,blankIn];
        """,arguments:["source":source],in:nil,contentWorld:.page) as? [Double]
        let ratios = try XCTUnwrap(pinch)
        XCTAssertEqual(ratios.count,4)
        XCTAssertGreaterThan(ratios[0],1.3,"Pinching from a card must immediately enlarge the map")
        XCTAssertLessThan(ratios[1],0.85,"Pinching from a card must shrink the map")
        XCTAssertGreaterThan(ratios[2],1.25,"Pinching from blank canvas must enlarge the map")
        XCTAssertLessThan(ratios[3],0.85,"Pinching from blank canvas must shrink the map")
        XCTAssertEqual(reader.currentAnnotations.count,2,"Pinching must not move or create graph nodes")
        _ = try await web.callAsyncJavaScript(drag,arguments:["source":source,"target":target,"fraction":0.5],in:nil,contentWorld:.page)
        stage = "触摸拖动改挂"
        try await wait { reader.currentBook?.graph.canvasNodes.first { $0.id == source }?.parent == target }
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == first.id }?.note,first.note)
        let document = reader.mindMapDocument()
        let chapterOne = try XCTUnwrap(try document.flattened().first { $0.topic.metadata?.chapterID == 0 }?.topic.id)
        let chapterTwo = try XCTUnwrap(try document.flattened().first { $0.topic.metadata?.chapterID == 1 }?.topic.id)
        _ = try await web.callAsyncJavaScript(drag,arguments:["source":chapterTwo,"target":chapterOne,"fraction":0.05],in:nil,contentWorld:.page)
        stage = "触摸拖动章节排序"
        try await wait {
            let nodes=reader.currentBook?.graph.canvasNodes ?? []
            guard let a=nodes.first(where:{ $0.id == chapterTwo }),let b=nodes.first(where:{ $0.id == chapterOne }) else { return false }
            return a.order < b.order
        }
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        reopened.currentID = bookID; reopened.chapters = reader.chapters
        let restored = try reopened.mindMapDocument().flattened()
        XCTAssertEqual(restored.first { $0.topic.id == source }?.parent,target)
        XCTAssertEqual(reopened.mindMapDocument().nodeData.children.first?.id,chapterTwo)
        XCTAssertEqual(reopened.chapters.map(\.href),["one.xhtml","two.xhtml"])
        for size in [CGSize(width:834,height:1194),CGSize(width:1194,height:834)] {
            host.view.frame.size = size; host.view.layoutIfNeeded(); try await Task.sleep(for:.milliseconds(350))
            _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'center'});return true",arguments:[:],in:nil,contentWorld:.page)
            let image = UIGraphicsImageRenderer(size:size).image { _ in host.view.drawHierarchy(in:CGRect(origin:.zero,size:size),afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image); attachment.name = "节点拖放与卡片-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}

extension MindMapCanvasTests {
    func testInkPreviewsMergeSplitUndoAndRestartUseTheSameGraph() async throws {
        let (reader,book,notes)=try makeInkGraphFixture()
        let a=try XCTUnwrap(notes.first(where:{ $0.excerpt.contains("第一处") })),b=try XCTUnwrap(notes.first(where:{ $0.excerpt.contains("第二处") }))
        var first=a;first.text="第一处的文字笔记";XCTAssertTrue(reader.saveGraphInkMetadata(first))
        var second=b;second.text="第二处的文字笔记";XCTAssertTrue(reader.saveGraphInkMetadata(second))
        var text=ReaderAnnotation(cfi:"",quote:"",chapter:"阅读与理解",progress:0,note:"关联的文字节点")
        text.title="相关问题";text.chapterHref="one.xhtml"
        XCTAssertTrue(reader.commitReadingGraph(bookID:book) { $0.replaceAnnotations([text]) })
        let aID=ReadingNodeID(.ink,a.id.uuidString),bID=ReadingNodeID(.ink,b.id.uuidString)
        let link=try XCTUnwrap(reader.connectReadingNodes(from:aID,to:.init(.note,text.id),label:"支持",bookID:book))
        let detached=BookEntity(name:"已解除关联",kind:.concept)
        let mention=ReadingEdge(kind:.mentions,source:aID,target:.init(.entity,detached.id.uuidString),label:"提及")
        XCTAssertTrue(reader.commitReadingGraph(bookID:book) { graph in
            graph.replaceEntities([detached]);try graph.apply(.connect(mention));try graph.apply(.disconnect(mention.id))
        })
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous=scene.windows.first(where:{ $0.isKeyWindow }),window=UIWindow(windowScene:scene),container=UIViewController()
        window.rootViewController=container;window.makeKeyAndVisible()
        let host=UIHostingController(rootView:BookNotesWorkspace(reader:reader,readingCompanion:true,close:{}))
        container.addChild(host);container.view.addSubview(host.view);host.view.frame=CGRect(x:0,y:0,width:1194,height:834);host.didMove(toParent:container)
        defer { reader.close();window.isHidden=true;window.rootViewController=nil;previous?.makeKey();try? FileManager.default.removeItem(at:reader.directory) }
        let web=try await auditReadyMap(host.view)
        let tokenA=reader.mindMapToken(aID),tokenB=reader.mindMapToken(bID)
        debugWeb=web;debugReader=reader;debugHost=host.view
        print("INK_STAGE previews")
        do { try await auditWait {
            try await web.callAsyncJavaScript("return [...document.querySelectorAll('.book-ink-preview img')].length===2 && [...document.querySelectorAll('.book-ink-preview img')].every(i=>i.complete && i.naturalWidth>0)",arguments:[:],in:nil,contentWorld:.page) as? Bool == true
        } } catch {
            let detail=try? await web.callAsyncJavaScript("return JSON.stringify({state:window.bookMindMap.inspect(),images:[...document.images].map(i=>[i.currentSrc,i.complete,i.naturalWidth]),html:document.getElementById('map').innerHTML.slice(0,12000)})",arguments:[:],in:nil,contentWorld:.page)
            print("INK_PREVIEW_FAILURE \(String(describing:detail))");throw error
        }
        let imageOnly = try await web.callAsyncJavaScript("""
        const cards=[...document.querySelectorAll('.me-tpc[data-book-kind=ink]')];
        return cards.length===2 && cards.every(card=>{
          const image=card.querySelector('.book-ink-preview img');
          return getComputedStyle(card.text).display==='none' && image?.alt===card.nodeObj.metadata.inkParts[0].quote;
        });
        """,arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(imageOnly as? Bool,true)
        let image=XCTAttachment(image:try await web.takeSnapshot(configuration:nil));image.name="手写节点-原文和局部笔迹";image.lifetime = .keepAlways;add(image)
        _ = try await web.callAsyncJavaScript("""
        window.bookMindMap.command({id:crypto.randomUUID(),name:'select',target:a});
        const card=document.querySelector('[data-nodeid="me'+a+'"]'),r=card.getBoundingClientRect();
        for(const type of ['pointerdown','pointerup'])card.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:59,clientX:r.x+20,clientY:r.y+20,button:0}));return true;
        """,arguments:["a":tokenA],in:nil,contentWorld:.page)
        stage="ink selection";print("INK_STAGE selection")
        try await wait { reader.selectedReadingItem == .node(aID) }
        stage="ink content";print("INK_STAGE content")
        try await wait { try await web.callAsyncJavaScript("return window.bookMindMap.inspect().editor",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        let duplicateTitleHidden = try await web.callAsyncJavaScript("""
        const card=document.querySelector('.book-node-expanded');
        return card?.nodeObj.id===id && getComputedStyle(card.querySelector('.text')).display==='none' &&
            !card.hasAttribute('hidden') && card.getAttribute('aria-label')==='展开的手写节点';
        """,arguments:["id":tokenA],in:nil,contentWorld:.page)
        XCTAssertEqual(duplicateTitleHidden as? Bool,true)
        _ = try await web.callAsyncJavaScript("""
        const source=document.querySelector('[data-nodeid="me'+a+'"]').nodeObj;
        source.note='旧界面文字，不应覆盖';source.metadata.inkParts[0].text='旧界面文字，不应覆盖';
        window.bookMindMap.command({id:crypto.randomUUID(),name:'mergeInk',target:a});
        const card=document.querySelector('[data-nodeid="me'+b+'"]'),r=card.getBoundingClientRect();
        for(const type of ['pointerdown','pointerup'])card.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'mouse',pointerId:60,clientX:r.x+20,clientY:r.y+20,button:0}));return true;
        """,arguments:["a":tokenA,"b":tokenB],in:nil,contentWorld:.page)
        stage="one ink node";print("INK_STAGE one");try await wait { reader.currentPageNotes.count==1 }
        let merged=try XCTUnwrap(reader.currentPageNotes.first)
        XCTAssertEqual(merged.id,b.id);XCTAssertEqual(merged.inkParts.count,2)
        XCTAssertFalse((merged.entityIDs ?? []).contains(detached.id),"Grouping must not restore an explicitly disconnected association")
        XCTAssertTrue(merged.text?.contains("第一处的文字笔记")==true);XCTAssertTrue(merged.text?.contains("第二处的文字笔记")==true)
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains(where:{ $0.label=="支持" && $0.id.source==bID && $0.id.record==link.record }) == true)
        XCTAssertFalse(reader.removedNotes.contains(where:{ $0.pageNote?.id==a.id }),"Merging is not deletion of the source ink")
        _ = try await web.callAsyncJavaScript("""
        const card=document.querySelector('[data-nodeid="me'+b+'"]'),r=card.getBoundingClientRect();
        for(const type of ['pointerdown','pointerup'])card.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:61,clientX:r.x+20,clientY:r.y+20,button:0}));return true;
        """,arguments:["b":tokenB],in:nil,contentWorld:.page)
        stage="merged ink stays editable";try await wait { try await web.callAsyncJavaScript("return !document.getElementById('actions') && window.bookMindMap.inspect().editor",arguments:[:],in:nil,contentWorld:.page) as? Bool == true }
        host.view.frame.size=CGSize(width:360,height:460);host.view.layoutIfNeeded()
        stage="narrow ink card and action anchor after rotation"
        try await wait {
            try await web.callAsyncJavaScript("""
            const card=document.querySelector('.book-node-expanded')?.getBoundingClientRect();
            const entry=document.querySelector('.book-node-expanded>.book-node-collapse')?.getBoundingClientRect();
            return innerWidth<=360 && !!card && !!entry && card.left>=11 && card.right<=innerWidth-11 &&
                entry.left>=card.left && entry.right<=card.right;
            """,arguments:[:],in:nil,contentWorld:.page) as? Bool == true
        }
        host.view.frame.size=CGSize(width:1194,height:834);host.view.layoutIfNeeded()
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'undo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage="two ink nodes";print("INK_STAGE two");try await wait { reader.currentPageNotes.count==2 }
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains(where:{ $0.id==link }) == true)
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'redo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage="one ink node";print("INK_STAGE one");try await wait { reader.currentPageNotes.count==1 }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'splitInk',target:b});return true",arguments:["b":tokenB],in:nil,contentWorld:.page)
        stage="two ink nodes";print("INK_STAGE two");try await wait { reader.currentPageNotes.count==2 }
        XCTAssertEqual(Set(reader.currentPageNotes.map(\.id)),[a.id,b.id])
        XCTAssertEqual(Set(reader.currentPageNotes.compactMap(\.text)),["第一处的文字笔记","第二处的文字笔记"])
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'undo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage="one ink node";print("INK_STAGE one");try await wait { reader.currentPageNotes.count==1 }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'redo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage="two ink nodes";print("INK_STAGE two");try await wait { reader.currentPageNotes.count==2 }
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'remove',target:a});return true",arguments:["a":tokenA],in:nil,contentWorld:.page)
        stage="one ink node";print("INK_STAGE one");try await wait { reader.currentPageNotes.count==1 }
        XCTAssertEqual(reader.pageHandwritingDraft(for:try XCTUnwrap(reader.currentPageNotes.first))?.drawing.strokes.count,1)
        _ = try await web.callAsyncJavaScript("window.bookMindMap.command({id:crypto.randomUUID(),name:'undo'});return true",arguments:[:],in:nil,contentWorld:.page)
        stage="two ink nodes";print("INK_STAGE two");try await wait { reader.currentPageNotes.count==2 }
        let reopened=ReaderModel(directory:reader.directory,loadExternalSources:false);reopened.currentID=book
        XCTAssertEqual(Set(reopened.currentPageNotes.map(\.id)),[a.id,b.id])
        XCTAssertEqual(reopened.pageHandwritingDraft(for:try XCTUnwrap(reopened.currentPageNotes.first))?.drawing.strokes.count,2)
        XCTAssertNotNil(reopened.pageNoteImage(try XCTUnwrap(reopened.currentPageNotes.first)))
        let discussionID=try XCTUnwrap(reopened.beginReadingNodeDiscussion(aID))
        let discussion=try XCTUnwrap(reopened.currentAnnotations.first(where:{ $0.id==discussionID.owner }))
        XCTAssertEqual(discussion.quote,a.excerpt)
        XCTAssertEqual(discussion.note,"第一处的文字笔记")
        XCTAssertEqual(discussion.chapterHref,a.anchor.chapterHref)
        XCTAssertEqual(discussion.cfi,a.inkParts.first?.sources.first?.id)
        XCTAssertTrue(reopened.currentBook?.graph.edges.contains(where:{ $0.id.source==aID && $0.id.target==discussionID }) == true)
        reopened.close()
    }
}
