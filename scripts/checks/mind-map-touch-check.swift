// Run with: xcrun swift scripts/checks/mind-map-touch-check.swift
// Exercises production node cards and touch handlers in WebKit, without a DOM mock.
import AppKit
import WebKit

final class GraphScheme: NSObject, WKURLSchemeHandler {
    let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader/MindMap")
    func webView(_ web: WKWebView,start task: WKURLSchemeTask) {
        guard let url=task.request.url, !url.path.contains("..") else { return }
        do {
            let file=root.appendingPathComponent(String(url.path.dropFirst()))
            let type=["html":"text/html","js":"application/javascript","css":"text/css"][file.pathExtension] ?? "text/plain"
            let data=try Data(contentsOf:file)
            task.didReceive(URLResponse(url:url,mimeType:type,expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ web: WKWebView,stop task: WKURLSchemeTask) {}
}
@MainActor final class GraphTouchProbe: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    var window: NSWindow!
    let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/graph-polish-20261116")
    override init() {
        let config=WKWebViewConfiguration()
        config.setURLSchemeHandler(GraphScheme(),forURLScheme:"bookcanvas")
        web=WKWebView(frame:NSRect(x:0,y:0,width:1194,height:834),configuration:config)
        super.init(); config.userContentController.add(self,name:"mindmap")
    }
    func start() {
        window=NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=web; window.orderFront(nil)
        web.load(URLRequest(url:URL(string:"bookcanvas://local/index.html")!))
        DispatchQueue.main.asyncAfter(deadline:.now()+40) { print("FAIL: WebKit graph timeout"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],let type=body["type"] as? String else { return }
        if type == "change" { web.evaluateJavaScript("window.bookMindMap.ack(true,'')",completionHandler:nil) }
        if type == "error" { print("WEB_ERROR \(body)") }
        guard type == "loaded" else { return }
        Task { @MainActor in
            do {
                let result=try await web.callAsyncJavaScript("""
                const pause=()=>new Promise(r=>setTimeout(r,100));
                const check=(condition,message)=>{if(!condition)throw Error(message);};
                await window.bookMindMap.update({session:'touch-check',version:1,editor:false,dark:false,paper:'#FFFFFF',document:{direction:1,arrows:[],nodeData:{id:'book',topic:'把阅读变成自己的理解',metadata:{kind:'book'},children:[
                  {id:'chapter-one',topic:'01 · 留一点时间，给阅读',metadata:{kind:'chapter',chapterID:0},children:[{id:'note-one',topic:'阅读不是完成进度',metadata:{kind:'note',preview:'慢一点，把眼前这一段读成自己的理解。'},children:[]}]},
                  {id:'chapter-two',topic:'02 · 在文字之间呼吸',metadata:{kind:'chapter',chapterID:1},children:[{id:'note-two',topic:'让线索彼此连接',metadata:{kind:'note',preview:'把原文、想法和人物放在同一条脉络上。'},children:[]}]}
                ]}}});
                await pause();
                const find=(id,node=window.bookMindMap.inspect().data.nodeData,parent=null)=>node.id===id?{node,parent}:(node.children||[]).map(c=>find(id,c,node.id)).find(Boolean);
                const element=id=>document.querySelector('[data-nodeid="me'+id+'"]');
                const drag=async(source,target,fraction=.5)=>{
                  window.bookMindMap.command({id:crypto.randomUUID(),name:'center'});await pause();
                  const from=element(source), to=element(target),a=from.getBoundingClientRect(),b=to.getBoundingClientRect();
                  for(const [type,x,y] of [['pointerdown',a.x+a.width/2,a.y+a.height/2],['pointermove',b.x+b.width/2,b.y+b.height*fraction],['pointerup',b.x+b.width/2,b.y+b.height*fraction]])
                    from.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:91,clientX:x,clientY:y,button:0}));
                  await pause();
                };
                await drag('note-one','note-two');
                check(find('note-one').parent==='note-two','Touch dragging must reparent the note');
                await drag('chapter-two','chapter-one',.05);
                check(window.bookMindMap.inspect().data.nodeData.children[0].id==='chapter-two','Dragging a chapter to the top edge must reorder it');
                window.bookMindMap.command({id:crypto.randomUUID(),name:'undo'});await pause();
                check(window.bookMindMap.inspect().data.nodeData.children[0].id==='chapter-one','Chapter drag must be undoable');
                window.bookMindMap.command({id:crypto.randomUUID(),name:'undo'});await pause();
                check(find('note-one').parent==='chapter-one','Note reparent must be undoable');
                window.bookMindMap.command({id:crypto.randomUUID(),name:'redo'});await pause();
                check(find('note-one').parent==='note-two','Redo must restore the new branch');
                check(getComputedStyle(element('note-one')).borderRadius==='14px','Notes render as consistent cards');
                check(element('note-one').getBoundingClientRect().height>40,'Notes retain a usable touch target');
                return JSON.stringify(window.bookMindMap.inspect().data);
                """,arguments:[:],in:nil,contentWorld:.page)
                try (result as? String ?? "").write(to:output.appendingPathComponent("webkit-drag-state.json"),atomically:true,encoding:.utf8)
                for size in [NSSize(width:1194,height:834),NSSize(width:834,height:1194)] {
                    window.setContentSize(size); web.frame.size=size
                    _ = try await web.callAsyncJavaScript("await new Promise(r=>setTimeout(r,150));window.bookMindMap.command({id:crypto.randomUUID(),name:'center'});await new Promise(r=>setTimeout(r,150));return true",arguments:[:],in:nil,contentWorld:.page)
                    let image=try await web.takeSnapshot(configuration:nil)
                    guard let data=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data),let png=bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
                    try png.write(to:output.appendingPathComponent("graph-webkit-\(Int(size.width))x\(Int(size.height)).png"))
                }
                print("PASS: WebKit touch reparenting, chapter ordering, undo, redo and card rendering")
                exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let probe=GraphTouchProbe(); probe.start(); app.run()
}
