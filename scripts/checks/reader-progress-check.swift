// Run with: xcrun swift scripts/checks/reader-progress-check.swift
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
        DispatchQueue.main.asyncAfter(deadline:.now()+90) { print("FAIL: timed out"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any] else { return }
        if body["type"] as? String == "probe" { print(body["value"] ?? ""); fflush(stdout); return }
        guard body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                let result = try await web.callAsyncJavaScript("""
                const check = (ok,msg) => { if(!ok) throw Error(msg); window.webkit.messageHandlers.reader.postMessage({type:'probe',value:msg}); };
                const settings = {theme:'paper',font:'sans',fontSize:20,lineHeight:1.7,margin:32,mode:'scroll'};
                const first=await reader.open(data,'',settings,null);
                check(first.anchor.quote.length>10,'Opening captures text content anchor');
                check(!first.userDriven,'Opening is not a new reading action');
                const forward=await reader.turn('next');
                check(forward.userDriven && forward.anchor.fraction>first.anchor.fraction,'Actual movement records portable progress');
                await reader.appearance({...settings,fontSize:24});
                const precise=await reader.restore({cfi:forward.locator,anchor:forward.anchor});
                check(!precise.userDriven,'Remote restore does not publish a fresh competing record');
                check(precise.locator===forward.locator,'CFI resumes exact content after font change');
                await reader.restore({cfi:first.locator,anchor:first.anchor});
                const portable=await reader.restore({anchor:forward.anchor});
                check(portable.anchor.quote.slice(0,20)===forward.anchor.quote.slice(0,20),'Text-only terminal anchor resumes the same passage');
                check(Math.abs(portable.progress-forward.progress)<0.01,'Shared percentage is independent of typography');
                const narrow=await reader.appearance({...settings,margin:0});
                const wide=await reader.appearance({...settings,margin:96});
                check(!wide.userDriven,'Changing margins does not overwrite shared reading progress');
                const exported=JSON.stringify({anchor:portable.anchor,cfi:portable.locator,progress:portable.progress});
                reader.cancel();
                return 'PASS: portable anchors, CFI, typography, progress consistency, passive restores\\n'+exported;
                """,arguments:["data":data.base64EncodedString()],in:nil,contentWorld:.page)
                print(result ?? "nil"); exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
let app=NSApplication.shared
let probe=ReaderProbe()
probe.start()
app.run()
