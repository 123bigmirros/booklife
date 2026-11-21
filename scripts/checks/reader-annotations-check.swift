// Run: xcrun swift scripts/checks/reader-annotations-check.swift
// Test actual selection, SVG rendering and host controls with book scripts disabled.
import Cocoa
import WebKit

@MainActor final class AnnotationProbe: NSObject, WKScriptMessageHandler {
    let web: WKWebView = {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame:CGRect(x:0,y:0,width:CommandLine.arguments.contains("--phone") ? 390 : 600,height:700),configuration:configuration)
    }()
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    var window: NSWindow?
    var events: [String] = []
    func start() {
        web.configuration.userContentController.add(self,name:"reader")
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window?.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window?.level = .floating
        window?.center()
        window?.contentView = web; window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        window?.orderFrontRegardless()
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+60) { print("FAIL: annotation timeout"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any], let type = body["type"] as? String else { return }
        if type.hasPrefix("annotation") { events.append(type); return }
        guard type == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                let result = try await web.callAsyncJavaScript("""
                const check = (ok,message) => { if(!ok) throw Error(message); };
                const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
                const settings = {theme:'paper',font:'sans',fontSize:20,lineHeight:1.7,margin:32,mode:'scroll',annotationSession:'test-session',annotations:[]};
                const start = await reader.open(data,'',settings,null);
                let frame = document.querySelector('iframe');
                check(!frame.sandbox.contains('allow-scripts'),'Book script isolation retained');
                let doc = frame.contentDocument;
                const text = Array.from(doc.querySelectorAll('p')).find(p => p.firstChild?.nodeType === 3 && p.firstChild.length > 30).firstChild;
                const range = doc.createRange(); range.setStart(text,0); range.setEnd(text,Math.min(72,text.length));
                frame.contentWindow.getSelection().addRange(range);
                await wait(400);
                const menu = document.getElementById('annotation-menu');
                for(let i=0;i<20 && menu.hidden;i++) await wait(100);
                check(!menu.hidden,'Selection opens annotation palette');
                check(menu.querySelectorAll('[data-color]').length === 6,'Five colors and underline');
                const selectedBounds = range.getBoundingClientRect(), frameBounds = frame.getBoundingClientRect(), menuBounds = menu.getBoundingClientRect();
                check(menuBounds.top >= selectedBounds.bottom+frameBounds.top || menuBounds.bottom <= selectedBounds.top+frameBounds.top,'Palette leaves multiline selection visible');
                const selectionQuote = range.toString();
                check(!reader.allowsReadingGesture(innerWidth/2,300),'Palette blocks accidental reading gesture');
                menu.querySelector('[data-color=green]').click();
                check(menu.hidden && !frame.contentWindow.getSelection().toString(),'Color clears selection and closes menu');
                // Re-create the CFI without changing the EPUB DOM, as the bridge does.
                const cfi = new ePub.CFI(range,start.locator.slice(8,start.locator.indexOf('!'))).toString();
                const item = {id:'A102D98E-73A8-4E1D-B8B0-6E3CE78A73DC',cfi,quote:selectionQuote,chapter:start.chapter,progress:start.progress,color:'green',note:'第一行\\n<script>只是笔记</script>'};
                reader.setAnnotations([item],'test-session');
                await wait(150);
                check(document.querySelectorAll('.bookslide-highlight rect').length > 0,'SVG highlights render outside the book DOM');
                await wait(100);
                let rect = range.getClientRects()[0], bounds = frame.getBoundingClientRect();
                check(reader.annotationTap(bounds.left+rect.left+2,bounds.top+rect.top+2),'Native tap finds highlight');
                check(!menu.hidden && menu.textContent.includes('编辑笔记'),'Existing note can be edited');
                check(!menu.querySelector('script') && menu.textContent.includes('<script>只是笔记</script>'),'Notes are displayed as plain text');
                const mr = menu.getBoundingClientRect();
                check(mr.left >= 0 && mr.right <= innerWidth && mr.top >= 0 && mr.bottom <= innerHeight,'Palette stays in viewport');
                Array.from(menu.querySelectorAll('button')).find(b=>b.textContent === '编辑笔记').click();
                check(menu.hidden,'Editor action closes palette');
                await reader.appearance({...settings,fontSize:30,mode:'paged',theme:'night'});
                await reader.go(item.cfi);
                check(document.querySelectorAll('.bookslide-highlight rect').length > 0,'Highlight survives typography and mode changes');
                reader.cancel();
                await reader.open(data,item.cfi,{...settings,annotations:[item]},null);
                check(document.querySelectorAll('.bookslide-highlight rect').length > 0,'Persisted highlight restores on reopen');
                const beforeSource = await reader.capturePageNoteAnchor();
                const source = await reader.sourceExcerpt(item.cfi,'');
                check(source.includes(selectionQuote),'Unified inspector expands actual source text');
                const chapterSource = await reader.sourceExcerpt('',beforeSource.chapterHref);
                check(chapterSource.length > 20,'Chapter notes expand actual chapter content');
                const afterSource = await reader.capturePageNoteAnchor();
                check(beforeSource.locator === afterSource.locator,'Expanding source does not move the reading position');
                reader.setAnnotations([],'old-session');
                check(document.querySelectorAll('.bookslide-highlight rect').length > 0,'Stale bridge writes are ignored');
                reader.setAnnotations([{...item,color:'underline'}],'test-session');
                check(document.querySelector('.bookslide-highlight'),'Can replace highlight with underline');
                reader.setAnnotations([],'test-session');
                check(!document.querySelector('.bookslide-highlight'),'Deleting removes rendered annotation');
                reader.cancel();
                check(menu.hidden && !reader.annotationTap(300,300),'Closing clears annotation state');
                await reader.open(data,'',{...settings,annotationSession:'other-book',annotations:[]},null);
                check(!document.querySelector('.bookslide-highlight'),'Annotations do not leak into another book session');
                reader.cancel();
                if (snapshot) {
                  const preview = {...item,note:'这句话值得记住。\\n下次阅读时，回到这里。'};
                  await reader.open(data,item.cfi,{...settings,annotations:[preview]},null);
                  const highlight = document.querySelector('.bookslide-highlight rect').getBoundingClientRect();
                  reader.annotationTap(highlight.left+2,highlight.top+2);
                }
                return 'PASS: selected text palette, colors, note actions, safe text, native hit testing, reflow, reopen, session isolation, underline and removal';
                """,arguments:["data":data.base64EncodedString(),"snapshot":CommandLine.arguments.contains("--snapshot")],in:nil,contentWorld:.page)
                guard events.contains("annotationChange"), events.contains("annotationEdit") else { throw NSError(domain:"Annotation bridge events missing: \(events)",code:1) }
                if CommandLine.arguments.contains("--snapshot") {
                    let image = try await web.takeSnapshot(configuration:nil)
                    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) {
                        try png.write(to:URL(fileURLWithPath:"/private/tmp/bookslide-annotations\(CommandLine.arguments.contains("--phone") ? "-phone" : "").png"))
                    }
                }
                print(result ?? "nil"); exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let probe = AnnotationProbe(); probe.start(); app.run()
}
