// Run with: xcrun swift scripts/checks/reader-webkit-check.swift
// Exercises the real script-disabled EPUB frame in WebKit, not a DOM mock.
import Cocoa
import WebKit

final class ReaderProbe: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    override init() {
        let configuration = WKWebViewConfiguration()
        web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:700),configuration:configuration)
        super.init()
        configuration.userContentController.add(self,name:"reader")
    }
    func start() {
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+30) { print("FAIL: timed out"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any], body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                let result = try await web.callAsyncJavaScript("""
                await reader.open(data,"",{theme:"paper",font:"sans",fontSize:20,lineHeight:1.7,margin:32,mode:"paged",nativeTouchControls:true},null);
                const check = (condition,message) => { if(!condition) throw Error(message); };
                const frame = document.querySelector('iframe');
                check(frame.sandbox.contains('allow-same-origin') && !frame.sandbox.contains('allow-scripts'),'EPUB script isolation');
                const doc = frame.contentDocument;
                let callbacks=0;
                doc.addEventListener('click',()=>callbacks++);
                doc.body.dispatchEvent(new MouseEvent('click',{bubbles:true}));
                check(callbacks === 0,'Expected WebKit sandbox to suppress frame callbacks');
                check(reader.allowsReadingGesture(195,300),'Native host can interact with body');
                const selection=frame.contentWindow.getSelection(), range=doc.createRange();
                range.selectNodeContents(doc.body); selection.addRange(range);
                check(!reader.allowsReadingGesture(195,300),'Selected text blocks page gestures');
                selection.removeAllRanges();
                const hit = doc.elementFromPoint(195-frame.getBoundingClientRect().left,300-frame.getBoundingClientRect().top);
                const old=hit.getAttribute('contenteditable'); hit.setAttribute('contenteditable','true');
                check(!reader.allowsReadingGesture(195,300),'Interactive element blocks page gestures');
                if(old===null)hit.removeAttribute('contenteditable');else hit.setAttribute('contenteditable',old);
                await reader.turn('next');
                check(reader.allowsReadingGesture(195,300),'Host coordinates still work after pagination');
                reader.cancel();
                check(!reader.allowsReadingGesture(195,300),'Closed book blocks gestures');
                return 'PASS: sandbox reproduced; native hit test, selection, interactive content, pagination and close';
                """,arguments:["data":data.base64EncodedString()],in:nil,contentWorld:.page)
                print(result ?? "nil"); exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }
}
let app=NSApplication.shared
let probe=ReaderProbe()
probe.start()
app.run()
