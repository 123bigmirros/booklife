// Compile with PageTurnSheet.swift; capture real EPUB pages and render the
// actual SwiftUI sheet at rest and halfway through both turn directions.
import Cocoa
import WebKit
import SwiftUI

enum PageDirection { case next, previous }
final class PageProbe: NSObject, WKScriptMessageHandler {
    let web = WKWebView(frame:CGRect(x:0,y:0,width:520,height:700))
    var window: NSWindow?
    let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
    func start() {
        web.configuration.userContentController.add(self,name:"reader")
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window?.contentView = web; window?.makeKeyAndOrderFront(nil)
        let folder = root.appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
        web.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder)
        DispatchQueue.main.asyncAfter(deadline:.now()+60) { print("FAIL: visual timeout"); exit(1) }
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any],body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let epub = try Data(contentsOf:root.appendingPathComponent("Sources/BookSlideMac/Resources/Reader/QuietHours.epub"))
                _ = try await web.callAsyncJavaScript("return await reader.open(data,'',{theme:'paper',font:'sans',fontSize:24,lineHeight:1.7,margin:36,mode:'paged'},null)",arguments:["data":epub.base64EncodedString()],in:nil,contentWorld:.page)
                let first = try await web.takeSnapshot(configuration:nil)
                _ = try await web.callAsyncJavaScript("return await reader.turn('next')",arguments:[:],in:nil,contentWorld:.page)
                let second = try await web.takeSnapshot(configuration:nil)
                for (name,angle,direction) in [("rest",0.0,PageDirection.next),("next",-45,.next),("previous",45,.previous)] {
                    let content = ZStack {
                        Image(nsImage:second).resizable()
                        PageTurnSheet(turn:ReaderPageTurn(image:first,direction:direction,angle:angle))
                    }.frame(width:520,height:700).clipped()
                    let renderer = ImageRenderer(content:content); renderer.scale = 1
                    guard let image = renderer.nsImage,let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data:tiff),let png = bitmap.representation(using:.png,properties:[:]) else { throw NSError(domain:"render",code:1) }
                    try png.write(to:root.appendingPathComponent("build/page-turn-\(name).png"))
                }
                print("PASS: real EPUB snapshots rendered with actual sheet view, both directions"); exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }
}
@main struct Main {
    static func main() {
        let app = NSApplication.shared, probe = PageProbe()
        probe.start(); app.run()
    }
}
