// Run with: xcrun swift scripts/checks/reader-scroll-check.swift
// Exercises the real script-disabled EPUB frame in WebKit, not a DOM mock.
import Cocoa
import WebKit

final class ReaderProbe: NSObject, WKScriptMessageHandler {
    var window: NSWindow?
    let web: WKWebView
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    override init() {
        let configuration = WKWebViewConfiguration()
        web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:700),configuration:configuration)
        super.init()
        configuration.userContentController.add(self,name:"reader")
    }
    func start() {
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window?.contentView = web; window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
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
                const wait = () => new Promise(r => setTimeout(r,350));
                const settings = {theme:'paper',font:'sans',fontSize:20,lineHeight:1.7,margin:32,nativeTouchControls:true};
                let first = await reader.open(data,'',settings,null);
                check(first.mode === 'scroll','Scroll is the default');
                let container = document.querySelector('.epub-container');
                check(container.scrollHeight > container.clientHeight,'Continuous content has scroll range');
                check(!first.canGoPrevious,'Start boundary');

                const streamTimes = [];
                for (let i=0;i<16;i++) {
                    const began = performance.now();
                    await reader.turn('next',1/16,true);
                    streamTimes.push(performance.now()-began);
                    await new Promise(r=>setTimeout(r,20));
                }
                await wait();
                check(Math.abs(container.scrollTop-34)<2,'Fractional network samples retain one full line of travel');
                streamTimes.sort((a,b)=>a-b);
                check(true,`Stream acceptance timing: median=${streamTimes[8].toFixed(1)}ms max=${streamTimes[15].toFixed(1)}ms (excludes transport)`);
                first = await reader.open(data,'',settings,null);
                container = document.querySelector('.epub-container');
                await reader.turn('next',1,true);
                await reader.turn('previous',1,true);
                await wait();
                check(container.scrollTop<2,'Immediate reversal cancels accepted motion even before the first frame');

                const fineTimes = [];
                for (let i = 0; i < 20; i++) {
                    const began = performance.now();
                    await reader.turn(i % 2 === 0 ? 'next' : 'previous',1);
                    fineTimes.push(performance.now()-began);
                }
                fineTimes.sort((a,b)=>a-b);
                check(true,`Fine-scroll engine timing: median=${fineTimes[10].toFixed(1)}ms max=${fineTimes[19].toFixed(1)}ms (20 operations; excludes transport)`);
                first = await reader.open(data,'',settings,null);
                container = document.querySelector('.epub-container');
                const fine = await reader.turn('next',1);
                check(Math.abs(container.scrollTop-34)<2,'Crown follows the full received distance on the first frame');
                await wait();
                check(Math.abs(container.scrollTop - 34) < 3,'One crown step moves one text line');
                const fineBack = await reader.turn('previous',1);
                await wait();
                check(container.scrollTop < 2,'Fine reverse returns to start');
                await reader.turn('next',12);
                check(Math.abs(container.scrollTop-408)<3,'Fast crown batch follows all twelve lines on the first frame');
                const stoppedAt = container.scrollTop;
                await wait();
                check(Math.abs(container.scrollTop-stoppedAt)<1,'No reader-added motion after received distance');
                await reader.turn('previous',12);
                check(container.scrollTop<2,'Large reverse returns immediately');
                for (let i=0;i<5;i++) await reader.turn('next',1);
                await wait();
                check(Math.abs(container.scrollTop-170)<3,'Overlapping crown samples preserve total distance');
                await reader.turn('next',4);
                const reversingAt = container.scrollTop;
                await reader.turn('previous',1);
                check(container.scrollTop < reversingAt,'Reversal brakes forward tail immediately');
                await wait();
                for (const invalid of [0,-1,17,0.01,NaN]) {
                    let rejected = false; try { await reader.turn('next',invalid); } catch { rejected = true; }
                    check(rejected,'Reject invalid fine-scroll distance');
                }
                let fineCurrent = fineBack, fineCount = 0, fineChapters = new Set([fineBack.chapter]);
                while (fineCurrent.canGoNext && fineCount++ < 200) {
                    const after = await reader.turn('next',4);
                    await wait();
                    if (after.locator === fineCurrent.locator && Math.abs(after.viewportOffset-fineCurrent.viewportOffset) <= 0.5) throw Error('Fine scroll stalled');
                    fineCurrent = after; fineChapters.add(after.chapter);
                }
                check(!fineCurrent.canGoNext && fineCount < 200 && fineChapters.size > 1,'Continuous fine scrolling crosses chapters and reaches boundary');
                first = await reader.open(data,'',settings,null);
                container = document.querySelector('.epub-container');
                const next = await reader.turn('next');
                
                check(next.locator !== first.locator && next.canGoPrevious,'Remote scroll moves and enables reverse');
                const back = await reader.turn('previous');
                check(back.locator !== next.locator,'Reverse scroll moves back');
                container.scrollTop += 180;
                await wait();
                const direct = await reader.appearance({...settings,fontSize:21});
                check(direct.locator !== first.locator,'Natural scroll persists a content anchor');
                const paged = await reader.appearance({...settings,mode:'paged'});
                check(paged.mode === 'paged','Switch to pages');
                const pageNext = await reader.turn('next');
                check(pageNext.locator !== paged.locator,'Paged next still works');
                const scroll = await reader.appearance({...settings,mode:'scroll'});
                check(scroll.mode === 'scroll' && scroll.chapter === pageNext.chapter,'Switch back retains chapter');
                check(Math.abs(scroll.progress-pageNext.progress) < 0.12,'Switch keeps nearby content');
                let current = scroll, count = 0, chapters = new Set([current.chapter]);
                while(current.canGoNext && count++ < 40) {
                    const after = await reader.turn('next');
                    check(after.locator !== current.locator,'Every successful scroll advances content');
                    current = after; chapters.add(current.chapter);
                }
                check(!current.canGoNext && count < 40,'Reach final boundary');
                check(chapters.size > 1,'Continuous scrolling crosses chapters');
                const end = await reader.turn('next');
                check(end.locator === current.locator,'End does not wrap');
                const reverse = await reader.turn('previous');
                check(reverse.canGoNext && reverse.locator !== end.locator,'Reverse from final screen');
                const resumed = await reader.open(data,reverse.locator,{...settings,mode:'scroll'},null);
                check(resumed.chapter === reverse.chapter,'Reopen restores chapter');
                check(resumed.locator === reverse.locator,'Reopen restores exact content anchor');
                check([...document.querySelectorAll('iframe')].every(f => !f.sandbox.contains('allow-scripts')),'Book scripts remain disabled');
                reader.cancel();
                return 'PASS: default scroll, natural/remote/reverse scrolling, mode switch, chapters, boundaries, resume, sandbox';
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
