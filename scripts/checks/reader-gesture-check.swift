// Run with: xcrun swift scripts/checks/reader-gesture-check.swift
// Exercises the real script-disabled EPUB frame in WebKit, not a DOM mock.
import Cocoa
import WebKit

final class GestureProbe: NSObject, WKScriptMessageHandler {
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
        DispatchQueue.main.asyncAfter(deadline:.now()+300) { print("FAIL: timed out"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any] else { return }
        if body["type"] as? String == "probe" { print(body["value"] ?? ""); fflush(stdout); return }
        guard body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                for size in [NSSize(width:1194,height:752),NSSize(width:834,height:1112),NSSize(width:600,height:718)] {
                window?.setContentSize(size)
                try await Task.sleep(for:.milliseconds(350))
                let result = try await web.callAsyncJavaScript(#"""
                const failures=[];
                const check=(ok,msg)=>{window.webkit.messageHandlers.reader.postMessage({type:'probe',value:(ok?'PASS: ':'FAIL: ')+msg});if(!ok) failures.push(msg);};
                const wait=ms=>new Promise(r=>setTimeout(r,ms));
                const original=ePub;
                window.ePub=(...args)=>{const b=original(...args),render=b.renderTo.bind(b);b.renderTo=(...args)=>{window.probeRendition=render(...args);return probeRendition;};return b;};
                Object.assign(window.ePub,original);
                const zip=await JSZip.loadAsync(data,{base64:true});
                for(const file of Object.values(zip.files).filter(f=>/chapter[0-9]+\.xhtml$/.test(f.name))) {
                  const text=await file.async('string');
                  zip.file(file.name,text.replace('</body>',Array.from({length:80},(_,i)=>`<p>连续滚动测试第${i+1}段。章节加载和回收必须保持当前文字可见。向前阅读，再向后阅读，文字的位置应该只跟随手指移动。</p>`).join('')+'</body>'));
                }
                const fixture=await zip.generateAsync({type:'base64'});
                const settings={theme:'paper',font:'sans',fontSize:20,lineHeight:1.7,margin:32,nativeTouchControls:true};
                await reader.open(fixture,'',settings,null);
                await reader.go('chapter1.xhtml'); await wait(400);
                let manager=probeRendition.manager, container=manager.container;
                const originalCheck=manager.check; let checks=0;
                manager.check=function(...args){checks++;return originalCheck.apply(this,args);};
                reader.beginReadingInput();
                for(let i=0;i<35;i++) {container.scrollTop+=5;container.dispatchEvent(new Event('scroll'));await wait(10);}
                check(checks>0,'Chapter preparation runs during an uninterrupted scroll stream');
                manager.check=originalCheck;await wait(400);
                // Hold work queued by update, reverse before that work executes.
                const view=manager.views.all().find(v=>v.displayed);
                for(let i=0;i<2;i++){const next=manager.views.last().section.next();if(next) await manager.append(next).display(manager.request);}
                await wait(100);
                const originalEnqueue=manager.q.enqueue; const queued=[];
                manager.q.enqueue=function(fn,...args){queued.push(()=>fn.apply(this.context||manager,args));return Promise.resolve();};
                container.scrollTop=view.element.offsetTop+view.element.offsetHeight+1200;
                check(view.element.getBoundingClientRect().bottom < container.getBoundingClientRect().top,'Recycle fixture has moved beyond the old chapter');
                await manager.update(0);
                container.scrollTop=view.element.offsetTop+100;
                manager.q.enqueue=originalEnqueue;
                for(const run of queued) await run();
                check(view.displayed && view.iframe?.isConnected,'A delayed recycle cannot destroy text after the reader reverses into it');
                // Exercise actual container scroll events every frame, without
                // reader.turn()'s explicit fill/update preparation or idle gaps.
                await reader.go('chapter1.xhtml'); await wait(350);
                let blankFrames=0, jumps=0, skipped=0, previousIndex=null;
                const visited=new Set();
                for(const direction of [1,-1,1,-1]) {
                  reader.beginReadingInput();
                  for(let frame=0;frame<170;frame++) {
                    const bounds=container.getBoundingClientRect();
                    const visible=manager.views.all().filter(v=>v.element.getBoundingClientRect().bottom>bounds.top+1 && v.element.getBoundingClientRect().top<bounds.bottom-1);
                    const marker=visible.find(v=>v.displayed)?.element;
                    const top=marker?.getBoundingClientRect().top;
                    const start=container.scrollTop;
                    container.scrollTop+=direction*95;
                    const travel=container.scrollTop-start;
                    container.dispatchEvent(new Event('scroll'));
                    await new Promise(requestAnimationFrame);
                    const now=manager.views.all().filter(v=>v.element.getBoundingClientRect().bottom>bounds.top+1 && v.element.getBoundingClientRect().top<bounds.bottom-1);
                    if(!now.length || now.some(v=>!v.displayed || !v.iframe?.isConnected || v.element.style.visibility==='hidden')) blankFrames++;
                    if(marker?.isConnected && Math.abs(marker.getBoundingClientRect().top-top+travel)>2) { jumps++; window.webkit.messageHandlers.reader.postMessage({type:'probe',value:JSON.stringify({direction,frame,top,after:marker.getBoundingClientRect().top,travel,scrollTop:container.scrollTop,index:manager.views.all().find(v=>v.element===marker)?.section.index})}); }
                    const index=now.find(v=>v.displayed)?.section.index;
                    if(index!=null) {
                      visited.add(index);
                      if(previousIndex!=null && Math.abs(index-previousIndex)>1) skipped++;
                      previousIndex=index;
                    }
                  }
                  await wait(350); // Exercise idle trim as well as reversal.
                }
                check(visited.size>=3,'Direct scrolling traverses at least three spine sections');
                check(blankFrames===0,`No missing visible chapter frames (${blankFrames})`);
                check(jumps===0,`Text tracks scroll distance without layout jumps (${jumps})`);
                check(skipped===0,`No skipped spine sections (${skipped})`);
                check(manager.views.length<=6,'Idle chapter reclamation keeps a bounded working set');
                await reader.go('chapter1.xhtml');
                container.scrollTop+=220; await wait(350);
                if(failures.length) throw Error(failures.join('; '));
                return 'PASS: native scroll scheduling and reversal recycle regression';
                """#,arguments:["data":data.base64EncodedString()],in:nil,contentWorld:.page)
                print("\(Int(size.width))×\(Int(size.height)): \(result ?? "nil")")
                let image = try await web.takeSnapshot(configuration:nil)
                if let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) {
                    let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/reader-gesture-\(Int(size.width)).png")
                    try png.write(to:output)
                }
                }
                _ = try await web.callAsyncJavaScript("reader.cancel(); return true",arguments:[:],in:nil,contentWorld:.page)
                exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
let app=NSApplication.shared
let probe=GestureProbe()
probe.start()
app.run()
