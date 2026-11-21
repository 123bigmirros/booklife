// Run with: xcrun swift scripts/checks/reader-position-check.swift
// Real WebKit sweep of reading-position preservation across reader operations.
import Cocoa
import WebKit

final class PositionProbe: NSObject, WKScriptMessageHandler {
    let web = WKWebView(frame:CGRect(x:0,y:0,width:1194,height:752))
    var window: NSWindow!
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    func start() {
        web.configuration.userContentController.add(self,name:"reader")
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+360) { print("FAIL: position audit timeout"); exit(1) }
    }
    @MainActor func resize(_ size: NSSize) async throws {
        window.setContentSize(size)
        try await Task.sleep(for:.milliseconds(500))
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any] else { return }
        if body["type"] as? String == "probe" { print(body["value"] ?? ""); fflush(stdout); return }
        guard body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                let font = try Data(contentsOf:resources.appendingPathComponent("ReadingSerif.woff2")).base64EncodedString()
                var failed = false
                for size in [NSSize(width:1194,height:752),NSSize(width:834,height:1112),NSSize(width:600,height:718)] {
                try await resize(size)
                for mode in ["scroll","paged"] {
                let result = try await web.callAsyncJavaScript("""
                const settings={theme:'paper',font:'sans',fontSize:32,lineHeight:1.65,margin:32,mode,
                  scrollMaxTextWidth:1040,paragraphSpacing:0.65,headingSpacing:0.75};
                const failures=[], passes=[];
                const samePoint=(a,b)=>a && b && Math.abs(a.x-b.x)<=1 && Math.abs(a.y-b.y)<=1;
                const originalEPub=ePub;
                window.ePub=(...args)=>{
                  const b=originalEPub(...args), render=b.renderTo.bind(b);
                  b.renderTo=(...args)=>{ window.probeRendition=render(...args); return window.probeRendition; };
                  return b;
                };
                Object.assign(window.ePub,originalEPub);
                function point(cfi) {
                  try {
                    const c=probeRendition.getContents().find(c=>c.sectionIndex===new ePub.CFI(cfi).spinePos);
                    const r=c.range(cfi).getBoundingClientRect(), f=c.document.defaultView.frameElement.getBoundingClientRect();
                    return {x:f.left+r.left,y:f.top+r.top};
                  } catch { return null; }
                }
                async function prepare() {
                  await reader.open(data,'',settings,font);
                  await reader.go('chapter1.xhtml');
                  let p=await reader.turn('next');
                  if (mode==='scroll') p=await reader.turn('previous',0.25);
                  return {p,point:point(p.locator)};
                }
                for (const [name,changes] of [
                  ['theme',[{theme:'night'},{theme:'light'},{theme:'paper'}]],
                  ['font size',[{fontSize:44},{fontSize:20},{fontSize:32}]],
                  ['font family',[{font:'pingfang'},{font:'serif'},{font:'publisher'},{font:'sans'}]],
                  ['line height',[{lineHeight:2},{lineHeight:1.3},{lineHeight:1.65}]],
                  ['margin',[{margin:0},{margin:96},{margin:32}]],
                  ['reading mode',[{mode:mode==='paged'?'scroll':'paged'},{mode}]],
                  ['rapid settings',[{fontSize:40},{fontSize:24},{fontSize:32}]]
                ]) {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} ${name}`});
                  const before=await prepare(); let after;
                  if (name==='rapid settings') {
                    const results=await Promise.all(changes.map(c=>reader.appearance({...settings,...c})));
                    after=results.at(-1);
                  } else for(const c of changes) after=await reader.appearance({...settings,...c});
                  await new Promise(r=>setTimeout(r,250));
                  const final=point(before.p.locator);
                  const detail={name,before:before.p.locator,after:after?.locator,offsetBefore:before.point,offsetAfter:final};
                  if (after?.locator!==before.p.locator || !samePoint(final,before.point)) failures.push(detail);
                  else passes.push(name);
                }
                {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} auxiliary`});
                  const before=await prepare();
                  await reader.search('阅读');
                  await reader.sourceExcerpt(before.p.locator,'');
                  reader.dismissAnnotations();
                  reader.setPageHandwriting(true,false); reader.setPageHandwriting(false,false);
                  const after=point(before.p.locator);
                  if (!samePoint(after,before.point)) failures.push({name:'search/source/selection/ink',before:before.point,after});
                  else passes.push('search/source/selection/ink');
                }
                {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} auxiliary`});
                  const before=await prepare();
                  const after=await reader.open(data,before.p.locator,settings,font,before.p.viewport);
                  const final=point(before.p.locator);
                  if (after.locator!==before.p.locator || !samePoint(final,before.point)) failures.push({name:'close/reopen',before:before.p.locator,after:after.locator,offsetBefore:before.point,offsetAfter:final});
                  else passes.push('close/reopen');
                }
                {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} auxiliary`});
                  const before=await prepare();
                  await reader.setActive(false);
                  await reader.appearance({...settings,fontSize:44});
                  await reader.setActive(true);
                  const after=await reader.appearance(settings);
                  if(after.locator!==before.p.locator || !samePoint(point(before.p.locator),before.point)) failures.push({name:'background preference update'});
                  else passes.push('background preference update');
                }
                {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} auxiliary`});
                  const before=await prepare();
                  const layout=reader.appearance({...settings,fontSize:44});
                  const jump=reader.go('chapter2.xhtml');
                  await layout;
                  const arrived=await jump;
                  if (arrived.anchor.href!=='chapter2.xhtml') failures.push({name:'navigation during reflow',arrived:arrived.locator});
                  else passes.push('navigation during reflow');
                  await reader.appearance(settings);
                  const returned=await reader.go(before.p.locator,before.p.viewport);
                  if(returned.locator!==before.p.locator || !samePoint(point(before.p.locator),before.point)) failures.push({name:'bookmark/return point'});
                  else passes.push('bookmark/return point');
                }
                {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} long paragraph`});
                  const zip=await JSZip.loadAsync(data,{base64:true}),source=await zip.file('EPUB/chapter1.xhtml').async('string');
                  const text=Array.from({length:250},(_,i)=>`第${i}句：阅读需要一点耐心，把想法留在原文中的位置。`).join('');
                  zip.file('EPUB/chapter1.xhtml',source.slice(0,source.indexOf('<body>')+6)+`<h1>长段落</h1><p id="long">${text}</p>`+source.slice(source.indexOf('</body>')));
                  const fixture=await zip.generateAsync({type:'base64'});
                  await reader.open(fixture,'',settings,font);
                  await reader.go('chapter1.xhtml');
                  const c=probeRendition.getContents().find(c=>c.sectionIndex===1),r=c.document.createRange();
                  r.setStart(c.document.getElementById('long').firstChild,2000);r.collapse(true);
                  const wanted=c.cfiFromRange(r);
                  const arrived=await reader.go(wanted);
                  // Pagination preserves the first visible text, since a larger
                  // font legitimately moves the bottom of the old page out.
                  const reference=arrived.viewport.locator, before=point(reference);
                  await reader.appearance({...settings,fontSize:44});
                  const large=point(reference);
                  await reader.appearance(settings);
                  if(!large || large.x<0 || large.x>=innerWidth || large.y < -50 || large.y>=innerHeight || !samePoint(point(reference),before)) failures.push({name:'long paragraph character anchor',reference,before,large,after:point(reference)});
                  else passes.push('long paragraph character anchor');
                }
                {
                  window.webkit.messageHandlers.reader.postMessage({type:'probe',value:`CHECK ${mode} ${innerWidth} cancellation`});
                  await prepare();
                  const pending=reader.appearance({...settings,fontSize:44});
                  await new Promise(requestAnimationFrame);
                  reader.cancel();
                  const opened=await reader.open(data,'chapter2.xhtml',settings,font);
                  await Promise.allSettled([pending]);
                  const settled=await reader.settledPosition();
                  if(settled.anchor.href!=='chapter2.xhtml' || settled.locator!==opened.locator) failures.push({name:'cancel/reopen during reflow'});
                  else passes.push('cancel/reopen during reflow');
                }
                reader.cancel();
                return JSON.stringify({passes,failures});
                """,arguments:["data":data.base64EncodedString(),"mode":mode,"font":font],in:nil,contentWorld:.page)
                let output = result as? String ?? "{}"
                let summary = try JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any]
                let failures = summary?["failures"] as? [[String:Any]] ?? [["error":"Missing results"]]
                failed = failed || !failures.isEmpty
                print("\(mode) \(Int(size.width))x\(Int(size.height)): \(output)")
                }
                }
                exit(failed ? 1 : 0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
let app = NSApplication.shared
let probe = PositionProbe(); probe.start(); app.run()
