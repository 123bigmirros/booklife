// Run with: xcrun swift scripts/checks/reader-layout-check.swift
// Measures the real EPUB layout at phone, iPad and split-window sizes.
import Cocoa
import WebKit

final class LayoutProbe: NSObject, WKScriptMessageHandler {
    let web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:700))
    var window: NSWindow?
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    func start() {
        web.configuration.userContentController.add(self,name:"reader")
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window?.contentView = web
        window?.makeKeyAndOrderFront(nil)
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+90) { print("FAIL: layout timeout"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any],body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                for (width,height,tablet,theme) in [(390,700,false,"paper"),(834,1194,true,"light"),(1194,834,true,"night"),(520,700,true,"paper")] {
                    window?.setContentSize(NSSize(width:width,height:height))
                    let result = try await web.callAsyncJavaScript("""
                    const check = (ok,message) => { if(!ok) throw Error(message); };
                    const settings = {mode:'scroll',theme,font:'pingfang',fontSize:32,lineHeight:1.55,margin:32,
                      nativeTouchControls:true,scrollMinimumInset:16,scrollStartInset:64,scrollEndInset:88,
                      scrollSideInset:0};
                    let current = await reader.open(data,'',settings,null);
                    check(current,'Open returns a reading position');
                    let movingContainer = document.querySelector('.epub-container');
                    const initialTop = movingContainer.scrollTop;
                    const samples = [], originalMove = BookSlideScroll.prototype.move;
                    BookSlideScroll.prototype.move = function(distance) {
                      return originalMove.call(this,distance).then(()=>samples.push({distance,target:this.target,top:this.container.scrollTop}));
                    };
                    for (let i=0;i<3;i++) await reader.turn('next',1);
                    await new Promise(resolve=>setTimeout(resolve,350));
                    check(Math.abs(movingContainer.scrollTop-initialTop-148.8)<3,`Crown stream preserves distance at ${innerWidth}px: ${movingContainer.scrollTop} from ${initialTop}`);
                    await reader.turn('previous',1);
                    await new Promise(resolve=>setTimeout(resolve,350));
                    BookSlideScroll.prototype.move = originalMove;
                    check(Math.abs(movingContainer.scrollTop-initialTop-99.2)<3,`Crown stream reverses at ${innerWidth}px: ${movingContainer.scrollTop} from ${initialTop}; samples=${JSON.stringify(samples)}`);
                    current = await reader.open(data,'',settings,null);
                    const container = document.querySelector('.epub-container');
                    function checkChapterSeams() {
                      const chapters=[...document.querySelectorAll('iframe')].filter(f=>f.contentDocument?.body?.textContent.trim() && f.getBoundingClientRect().bottom>0 && f.getBoundingClientRect().top<innerHeight);
                      for (const chapter of chapters) {
                        const body=chapter.contentDocument.body, style=chapter.contentWindow.getComputedStyle(body);
                        check(parseFloat(style.marginTop)===0 && parseFloat(style.marginBottom)===0,`No default body margins between continuous chapters: ${chapter.src} top=${style.marginTop} bottom=${style.marginBottom} frame=${JSON.stringify(chapter.getBoundingClientRect().toJSON())}`);
                        if (!body.hasAttribute('data-bookslide-first')) check(parseFloat(style.paddingTop)===0,'No repeated top strip at a chapter boundary');
                        if (!body.hasAttribute('data-bookslide-last')) check(parseFloat(style.paddingBottom)===0,'No repeated bottom strip at a chapter boundary');
                      }
                      for (let i=1;i<chapters.length;i++) {
                        check(Math.abs(chapters[i].getBoundingClientRect().top-chapters[i-1].getBoundingClientRect().bottom)<2,'Chapter frames join without a blank spacer');
                      }
                    }
                    checkChapterSeams();
                    const frame = document.querySelector('iframe');
                    const rect = container.getBoundingClientRect();
                    const css = frame.contentWindow.getComputedStyle(frame.contentDocument.body);
                    check(Math.abs(rect.width-innerWidth)<2 && Math.abs(rect.height-innerHeight)<2,'Viewport must fill canvas');
                    check(Math.abs(frame.getBoundingClientRect().width-innerWidth)<2,'Chapter must fill canvas');
                    const padding = parseFloat(css.paddingLeft);
                    const expected = 16;
                    check(Math.abs(padding-expected)<2,'Reading margins belong inside full-width chapter');
                    const paragraph=[...frame.contentDocument.querySelectorAll('p')].find(p=>p.textContent.length>45);
                    const paragraphStyle=frame.contentWindow.getComputedStyle(paragraph);
                    check(paragraphStyle.fontFamily.includes('PingFang SC') && paragraphStyle.fontWeight==='300','Selected PingFang Light overrides publisher body font');
                    check(Math.abs(parseFloat(css.fontSize)-32)<0.1 && Math.abs(parseFloat(paragraphStyle.lineHeight)-49.6)<0.1,`Reference font size and line height: ${css.fontSize}, ${paragraphStyle.lineHeight}`);
                    check(parseFloat(css.paddingTop)===64,'First text clears top edge');
                    check(frame.contentDocument.documentElement.scrollWidth<=innerWidth+2,'No horizontal overflow');
                    let count=0;
                    while(current.canGoNext && count++<50) {
                      current=await reader.turn('next');
                      checkChapterSeams();
                      check(current,`Scroll ${count} returns a reading position at ${innerWidth}px; top=${container.scrollTop}, height=${container.scrollHeight}; frames=${[...document.querySelectorAll('iframe')].map(f=>JSON.stringify(f.getBoundingClientRect().toJSON())).join(',')}`);
                    }
                    check(!current.canGoNext,'Reach final chapter');
                    const last=[...document.querySelectorAll('iframe')].at(-1);
                    check(parseFloat(last.contentWindow.getComputedStyle(last.contentDocument.body).paddingBottom)===88,'Last text clears progress overlay');
                    await reader.appearance({...settings,font:'sans'});
                    const changedFrame=document.querySelector('iframe');
                    check(changedFrame.contentWindow.getComputedStyle(changedFrame.contentDocument.body).fontWeight!=='300','Changing font clears the PingFang weight override');
                    reader.cancel();
                    return `PASS: ${innerWidth}x${innerHeight} ${theme}; edge-to-edge viewport, inset=${padding}px, first/last clearance`;
                    """,arguments:["data":data.base64EncodedString(),"tablet":tablet,"theme":theme],in:nil,contentWorld:.page)
                    print(result ?? "nil")
                }
                exit(0)
            } catch {
                if let image = try? await web.takeSnapshot(configuration:nil), let tiff=image.tiffRepresentation,
                   let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) {
                    try? png.write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/style23-layout-failure.png"))
                }
                print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1)
            }
        }
    }
}
let app = NSApplication.shared
let probe = LayoutProbe()
probe.start()
app.run()
