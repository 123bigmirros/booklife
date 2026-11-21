// Run with: xcrun swift scripts/checks/reader-structure-check.swift
// Exercise actual EPUB 2/3 navigation and same-document anchors in WebKit.
import Cocoa
import WebKit

final class StructureProbe: NSObject, WKScriptMessageHandler {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
    var window: NSWindow?
    var metadata: [[String: Any]] = []
    let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    func start() {
        web.configuration.userContentController.add(self, name: "reader")
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window?.contentView = web
        window?.orderFront(nil)
        web.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("FAIL: structure timeout"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "diagnostic" { print(body["value"] ?? ""); fflush(stdout) }
        if body["type"] as? String == "metadata", let value = body["value"] as? [String: Any] { metadata.append(value); return }
        guard body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                if CommandLine.arguments.count > 1 {
                    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
                    _ = try await web.callAsyncJavaScript("return await reader.open(data,'',{theme:'paper',font:'sans',fontSize:20,lineHeight:1.7,margin:32,mode:'scroll'},null)", arguments: ["data": data.base64EncodedString()], in: nil, contentWorld: .page)
                    guard let toc = metadata.last?["toc"] as? [[String: Any]], !toc.isEmpty else { throw NSError(domain: "missing navigation", code: 1) }
                    let outline = try await web.callAsyncJavaScript("return await reader.outline()",arguments:[:],in:nil,contentWorld:.page) as? [[String:Any]] ?? []
                    guard outline.count >= toc.count, Set(outline.compactMap { $0["id"] as? String }).count == outline.count else { throw NSError(domain:"incomplete outline",code:1) }
                    let extra = outline.filter { ($0["id"] as? String)?.hasPrefix("heading-") == true }
                    for item in extra.prefix(3) {
                        let href = item["href"] as? String ?? "", title = item["title"] as? String ?? ""
                        let position = try await web.callAsyncJavaScript("return await reader.go(href)",arguments:["href":href],in:nil,contentWorld:.page) as? [String:Any]
                        guard position?["chapter"] as? String == title else { throw NSError(domain:"subheading destination",code:1) }
                    }
                    print("PASS: supplied EPUB outline has \(outline.count) nodes, including \(extra.count) body headings omitted from its \(toc.count)-entry TOC"); fflush(stdout)
                    let indices = Set([0, toc.count / 4, toc.count / 2, toc.count * 3 / 4, toc.count - 1])
                    for index in indices.sorted() {
                        guard let href = toc[index]["href"] as? String, !href.isEmpty else { continue }
                        let result = try await web.callAsyncJavaScript("const p=await reader.go(href); if(p.chapterHref !== href) throw Error('Wrong chapter: '+p.chapterHref); return p.chapter", arguments: ["href": href], in: nil, contentWorld: .page)
                        print("PASS: chapter \(index + 1): \(result ?? "")"); fflush(stdout)
                    }
                    print("PASS: opened supplied EPUB, \(toc.count) navigation nodes, five chapter destinations")
                    exit(0)
                }
                let result = try await web.callAsyncJavaScript("""
                const check = (ok, message) => { if (!ok) throw Error(message); };
                const settings = {theme:'paper', font:'sans', fontSize:20, lineHeight:1.7, margin:32, mode:'scroll'};
                async function fixture(version) {
                  const zip = new JSZip();
                  zip.file('mimetype','application/epub+zip');
                  zip.file('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>');
                  const links = [['part','chapter.xhtml','第一部分'],['one','chapter.xhtml#one','第一章'],['deep','chapter.xhtml#deep','小节'],['two','chapter.xhtml#two','第二章'],['next','next.xhtml','第二部分']];
                  const nav = '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li id="part"><a href="chapter.xhtml">第一部分</a><ol><li id="duplicate"><a href="chapter.xhtml#one">第一章</a><ol><li><a href="chapter.xhtml#deep">小节</a></li></ol></li><li id="duplicate"><a href="chapter.xhtml#two">第二章</a></li></ol></li><li><a href="next.xhtml">第二部分</a></li></ol></nav></body></html>';
                  const point = i => '<navPoint id="'+links[i][0]+'" playOrder="'+(i+1)+'"><navLabel><text>'+links[i][2]+'</text></navLabel><content src="'+links[i][1]+'"/>';
                  const ncx = '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>测试</text></docTitle><navMap>'+point(0)+point(1)+point(2)+'</navPoint></navPoint>'+point(3)+'</navPoint></navPoint>'+point(4)+'</navPoint></navMap></ncx>';
                  const navItem = version === 3 ? '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' : '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>';
                  zip.file('EPUB/package.opf','<package xmlns="http://www.idpf.org/2007/opf" version="'+version+'.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">structure-test-'+version+'</dc:identifier><dc:title>结构测试</dc:title><dc:language>zh-CN</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="next" href="next.xhtml" media-type="application/xhtml+xml"/>'+navItem+'</manifest><spine'+(version === 2 ? ' toc="ncx"' : '')+'><itemref idref="chapter"/><itemref idref="next"/></spine></package>');
                  zip.file(version === 3 ? 'EPUB/nav.xhtml' : 'EPUB/toc.ncx', version === 3 ? nav : ncx);
                  const para = '<p>'+('足够长的章节正文，用于验证锚点和目录定位。'.repeat(30))+'</p>';
                  zip.file('EPUB/chapter.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>上篇</title></head><body><h1>第一部分</h1>'+para.repeat(3)+'<h2 id="one">第一章</h2>'+para.repeat(4)+'<h3 id="deep">小节</h3>'+para.repeat(2)+'<h4>目录没有收录的小标题</h4>'+para.repeat(2)+'<h2 id="two">第二章</h2>'+para.repeat(4)+'</body></html>');
                  zip.file('EPUB/next.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>下篇</title></head><body><h1>第二部分</h1>'+para.repeat(3)+'</body></html>');
                  return await zip.generateAsync({type:'base64'});
                }
                for (const version of [3,2]) {
                  const first = await reader.open(await fixture(version),'',settings,null);
                  const outline = await reader.outline();
                  const small = outline.find(item => item.title === '目录没有收录的小标题');
                  check(small && small.depth === 3 && small.href.startsWith('epubcfi('), 'Missing lower headings get stable CFI destinations');
                  check(outline.filter(item => item.title === '小节').length === 1, 'TOC headings are not duplicated');
                  const atSmall = await reader.go(small.href);
                  check(atSmall.chapter === small.title && atSmall.chapterHref === small.href, 'Subheading CFI opens its exact source');
                  const source = await reader.sourceExcerpt('',small.href);
                  check(source.includes(small.title), 'Subheading source can be read in the notes workspace');
                  check(first.chapter === '第一部分', 'EPUB '+version+' opening chapter');
                  for (const [href,title] of [['chapter.xhtml#one','第一章'],['chapter.xhtml#deep','小节'],['chapter.xhtml#two','第二章'],['next.xhtml','第二部分']]) {
                    const position = await reader.go(href);
                    check(position.chapterHref === href && position.chapter === title, 'EPUB '+version+' anchor '+href+': '+JSON.stringify(position));
                  }
                  await reader.go('chapter.xhtml#one');
                  const back = await reader.go('chapter.xhtml#deep');
                  check(back.chapter === '小节', 'Backward and forward anchors retain identity');
                  reader.cancel();
                }
                return 'PASS: EPUB 2/3 nested navigation, same-document headings and chapter jumps';
                """, arguments: [:], in: nil, contentWorld: .page)
                guard metadata.count == 2 else { throw NSError(domain: "metadata count", code: metadata.count) }
                for item in metadata {
                    let toc = item["toc"] as? [[String: Any]] ?? []
                    guard toc.compactMap({ $0["depth"] as? Int }) == [0,1,2,1,0],
                          Set(toc.compactMap { $0["id"] as? String }).count == 5 else {
                        throw NSError(domain: "hierarchy or duplicate TOC IDs", code: 1)
                    }
                }
                print(result ?? "nil"); exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
let app = NSApplication.shared
let probe = StructureProbe()
probe.start()
app.run()
