// Compile with ReaderPageNote.swift and ReaderPageNoteSchemeHandler.swift.
// Verify real WebKit anchoring, custom-scheme images and safe reflow behavior.
import AppKit
import WebKit

@main struct PageNoteCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let probe = PageNoteProbe(); probe.start(); app.run()
    }
}
@MainActor final class PageNoteProbe: NSObject, WKScriptMessageHandler {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    var window: NSWindow?
    var web: WKWebView!
    var hiddenReported = false
    func start() {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ReaderPageNoteSchemeHandler(directory:root),forURLScheme:"bookslide-ink")
        configuration.userContentController.add(self,name:"reader")
        web = WKWebView(frame:CGRect(x:0,y:0,width:600,height:700),configuration:configuration)
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window?.contentView = web; window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+45) { print("FAIL: page-note timeout"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any], let type = body["type"] as? String else { return }
        if type == "pageNoteVisibility" {
            if let value = body["value"] as? [String:Any], let hidden = value["hidden"] as? [String], !hidden.isEmpty,
               value["session"] as? String == "ink-session" { hiddenReported = true }
            return
        }
        guard type == "ready" else { return }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at:root) }
            do {
                let epub = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                let anchorValue = try await web.callAsyncJavaScript("""
                window.pageNoteSettings = {theme:'paper',font:'sans',fontSize:24,lineHeight:1.7,margin:32,mode:'scroll',annotationSession:'ink-session'};
                await reader.open(data,'',pageNoteSettings,null);
                return await reader.capturePageNoteAnchor();
                """,arguments:["data":epub.base64EncodedString()],in:nil,contentWorld:.page)
                let anchor = try JSONDecoder().decode(ReaderPageAnchor.self,from:JSONSerialization.data(withJSONObject:anchorValue!))
                let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600,pixelsHigh:700,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                let png = bitmap.representation(using:.png,properties:[:])!
                let assets = ReaderPageNoteStore(libraryDirectory:root)
                let assetID = try assets.save(.init(drawing:Data("vector fixture".utf8),page:png,ink:png,preview:png))
                let note = ReaderPageNote(assetID:assetID,anchor:anchor)
                let values = try JSONSerialization.jsonObject(with:JSONEncoder().encode([note]))
                let result = try await web.callAsyncJavaScript("""
                const check=(ok,message)=>{if(!ok)throw Error(message);};
                const wait=ms=>new Promise(r=>setTimeout(r,ms));
                reader.setPageNotes(notes,'ink-session'); await wait(300);
                let image=document.querySelector('#page-note-layer img');
                check(image && image.naturalWidth===600,'Production scheme handler serves ink image');
                check(image.style.display==='block','Matching layout displays ink');
                check(reader.pageNotesOnScreen().includes(notes[0].id),'Pencil entry can find existing editable ink on the current page');
                check(reader.pageNoteAnchorsOnScreen(notes).includes(notes[0].id),'An unfinished ink draft can be found by its text anchor');
                const oldTop=parseFloat(image.style.top);
                await reader.turn('next'); await wait(250);
                check(parseFloat(image.style.top)!==oldTop,'Ink follows the original text anchor while scrolling');
                reader.setPageHandwriting(true);
                check(document.getElementById('page-note-layer').style.visibility==='hidden','A new page snapshot does not flatten earlier editable ink');
                for (const operation of [()=>reader.turn('next'),()=>reader.go(notes[0].anchor.locator),()=>reader.progress(0.5)]) {
                  let blocked=false; try{await operation();}catch(_){blocked=true;} check(blocked,'Writing prevents page navigation');
                }
                check(!reader.allowsReadingGesture(300,300),'Writing prevents reading gestures');
                reader.setPageHandwriting(false);
                await reader.go(notes[0].anchor.locator);
                await reader.appearance({...pageNoteSettings,fontSize:30}); await wait(200);
                await reader.go(notes[0].anchor.locator); await wait(200);
                check(image.style.display==='none','Reflow hides ink instead of marking different words');
                check(reader.pageNotesOnScreen().includes(notes[0].id),'Reflow keeps a discoverable original-page entry at the text anchor');
                await reader.appearance(pageNoteSettings); await reader.go(notes[0].anchor.locator); await wait(250);
                check(image.style.display==='block','Original layout restores anchored ink');
                reader.setPageNotes([],'old-session'); check(document.querySelector('#page-note-layer img'),'Stale session cannot erase current ink');
                const blockedImage=new Image();
                const restricted=await new Promise(resolve=>{blockedImage.onload=()=>resolve(false);blockedImage.onerror=()=>resolve(true);blockedImage.src=image.src.replace('ink.png','page.png');});
                check(restricted,'Scheme does not expose original page snapshots');
                await reader.appearance({...pageNoteSettings,mode:'paged'});
                await reader.go(notes[0].anchor.locator);
                const paged={...notes[0],anchor:await reader.capturePageNoteAnchor()};
                reader.setPageNotes([paged],'ink-session'); await wait(200);
                const pagedImage=document.querySelector('#page-note-layer img'), oldLeft=pagedImage.style.left;
                check(pagedImage.style.display==='block','Paginated layout displays saved ink');
                await reader.turn('next'); await wait(250);
                check(pagedImage.style.display==='none' || pagedImage.style.left!==oldLeft,'Page turning moves old ink off the page');
                reader.cancel(); check(!document.querySelector('#page-note-layer img'),'Closing clears page overlays');
                await reader.open(data,notes[0].anchor.locator,{...pageNoteSettings,pageNotes:notes},null); await wait(250);
                check(document.querySelector('#page-note-layer img')?.naturalWidth===600,'Reopening restores saved page ink');
                reader.setPageNotes([],'ink-session'); check(!document.querySelector('#page-note-layer img'),'Removing a page note clears its overlay');
                reader.cancel();
                return 'PASS: actual ink scheme, text-anchor scrolling, writing lock, safe reflow, layout restoration, session isolation and reopen';
                """,arguments:["notes":values,"data":epub.base64EncodedString()],in:nil,contentWorld:.page)
                guard hiddenReported else { throw NSError(domain:"Reflow did not report the original-page entry to native UI",code:1) }
                print(result ?? "nil"); exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
