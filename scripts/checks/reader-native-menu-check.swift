// Compile with ReaderAnnotation.swift and ReaderAnnotationWebView.swift, then run.
// Exercises the production native context-menu adapter against real EPUB selection.
import AppKit
import WebKit

@main
struct NativeMenuCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let probe = NativeMenuProbe(); probe.start(); app.run()
    }
}

@MainActor
final class NativeMenuProbe: NSObject, WKScriptMessageHandler {
    let web: ReaderAnnotationWebView
    var window: NSWindow?
    var actions: [(String,[String:Any])] = []
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    override init() {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        web = ReaderAnnotationWebView(frame:NSRect(x:0,y:0,width:800,height:650),configuration:configuration)
        super.init()
        configuration.userContentController.add(self,name:"reader")
        web.onAnnotationAction = { [weak self] type,value in self?.actions.append((type,value)) }
    }
    func start() {
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window?.contentView = web; window?.orderFront(nil)
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+45) { print("FAIL: native menu timeout"); exit(1) }
    }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain:message,code:1) }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any] else { return }
        if body["type"] as? String == "annotationSelection" { web.annotationContext = body["value"] as? [String:Any]; return }
        guard body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                let selection = try await web.callAsyncJavaScript("""
                await reader.open(data,'',{theme:'paper',font:'sans',fontSize:24,lineHeight:1.7,margin:32,mode:'scroll',nativeAnnotationMenu:true,annotationSession:'native-menu'},null);
                const frame = document.querySelector('iframe'), doc = frame.contentDocument;
                const node = Array.from(doc.querySelectorAll('p')).find(p=>p.firstChild?.nodeType===3 && p.firstChild.length>30).firstChild;
                const range = doc.createRange(); range.setStart(node,0); range.setEnd(node,30);
                frame.contentWindow.getSelection().addRange(range);
                await new Promise(resolve=>setTimeout(resolve,350));
                if (!document.getElementById('annotation-menu').hidden) throw Error('Mac must use one native menu');
                return reader.annotationContext();
                """,arguments:["data":data.base64EncodedString()],in:nil,contentWorld:.page) as? [String:Any]
                try check(selection?["session"] as? String == "native-menu","Selection reaches native host")
                try check(web.annotationContext?["quote"] as? String == selection?["quote"] as? String,"Polling and on-demand context agree")
                let event = NSEvent.mouseEvent(with:.rightMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window?.windowNumber ?? 0,context:nil,eventNumber:0,clickCount:1,pressure:0)!
                let menu = NSMenu()
                let copy = NSMenuItem(title:"拷贝",action:#selector(NSText.copy(_:)),keyEquivalent:"")
                copy.identifier = .init("WKMenuItemIdentifierCopy")
                let lookup = NSMenuItem(title:"查询",action:nil,keyEquivalent:"")
                let translate = NSMenuItem(title:"翻译",action:nil,keyEquivalent:"")
                menu.addItem(lookup); menu.addItem(translate); menu.addItem(copy)
                web.willOpenMenu(menu,with:event)
                try check(menu.items.contains(copy) && menu.items.contains(lookup) && !menu.items.contains(translate),"AI translation replaces system translation alongside copy and lookup")
                try check(menu.items.first?.identifier?.rawValue == "BookSlideAnnotationPalette","Native palette is first")
                let palette = menu.items.first!.view!
                let buttons = palette.subviews.compactMap { $0 as? NSButton }
                try check(buttons.count == 6,"Five native swatches and underline")
                buttons[1].performClick(nil)
                try await Task.sleep(nanoseconds:80_000_000)
                try check(actions.last?.0 == "annotationChange" && actions.last?.1["color"] as? String == "green","Native swatch invokes annotation change")
                let note = menu.items.first { $0.title == "写笔记" }!
                _ = (note.target as? NSObject)?.perform(note.action!,with:note)
                try await Task.sleep(nanoseconds:80_000_000)
                try check(actions.last?.0 == "annotationEdit" && actions.last?.1["cfi"] as? String == selection?["cfi"] as? String,"Note action keeps the original selected range after menu closes")
                let discuss = menu.items.first { $0.title == "问 AI" }!
                _ = (discuss.target as? NSObject)?.perform(discuss.action!,with:discuss)
                try await Task.sleep(nanoseconds:80_000_000)
                try check(actions.last?.0 == "annotationDiscuss" && actions.last?.1["cfi"] as? String == selection?["cfi"] as? String,"Discussion action keeps the same original range")
                let aiTranslation = menu.items.first { $0.title == "翻译" }!
                _ = (aiTranslation.target as? NSObject)?.perform(aiTranslation.action!,with:aiTranslation)
                try await Task.sleep(nanoseconds:80_000_000)
                try check(actions.last?.0 == "annotationTranslate" && actions.last?.1["quote"] as? String == selection?["quote"] as? String,"AI translation receives the original selected text")
                let before = try await web.callAsyncJavaScript("return await reader.discussionExcerpt(locator)",arguments:["locator":selection?["cfi"] as? String ?? ""],in:nil,contentWorld:.page) as? String ?? ""
                try check(!before.contains(selection?["quote"] as? String ?? "missing"),"Discussion context ends before the selected passage")
                let scoped = try await web.callAsyncJavaScript("""
                const outline = await reader.outline();
                const root = await reader.readingDiscussionExcerpts(locator,'','');
                const future = await reader.readingDiscussionExcerpts(locator,outline.at(-1).href,'');
                return root.length > 0 && future.length === 0;
                """,arguments:["locator":selection?["cfi"] as? String ?? ""],in:nil,contentWorld:.page) as? Bool
                try check(scoped == true,"The root draws on reached text and an unread chapter supplies no excerpts")
                try check(!menu.items.contains { $0.title == "留下疑问" },"Removed question action is absent")
                var existing = selection!; existing["existing"] = true; existing["note"] = "已有笔记"
                web.annotationContext = existing
                let editing = NSMenu(); editing.addItem(copy.copy() as! NSMenuItem)
                web.willOpenMenu(editing,with:event)
                try check(editing.items.contains { $0.title == "编辑笔记" },"Existing note offers Edit")
                let remove = editing.items.first { $0.title == "移除标记" }!
                _ = (remove.target as? NSObject)?.perform(remove.action!,with:remove)
                try await Task.sleep(nanoseconds:80_000_000)
                try check(actions.last?.0 == "annotationRemove","Remove invokes annotation deletion")
                web.annotationContext = nil
                let blank = NSMenu(); blank.addItem(withTitle:"重新载入",action:nil,keyEquivalent:"")
                web.willOpenMenu(blank,with:event)
                try check(blank.items.count == 1,"Blank background has no annotation actions")
                print("PASS: real EPUB selection, native color row, add/edit note, AI discussion, preceding context, remove, original range snapshot and preserved system actions")
                exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
