// Run with: xcrun swift scripts/checks/reader-resize-check.swift
// Real WebKit regression for opening/closing iPad notes, including chapter edges.
import Cocoa
import WebKit

final class ResizeProbe: NSObject, WKScriptMessageHandler {
    let web = WKWebView(frame:CGRect(x:0,y:0,width:1194,height:752))
    var window: NSWindow!
    var positions: [[String:Any]] = []
    let resources = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/BookSlideMac/Resources/Reader")
    func start() {
        web.configuration.userContentController.add(self,name:"reader")
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        DispatchQueue.main.asyncAfter(deadline:.now()+120) { print("FAIL: resize timeout"); exit(1) }
    }
    func check(_ condition: Bool,_ message: String) throws {
        if !condition { throw NSError(domain:"ReaderResize",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    @MainActor func resize(_ size: NSSize) async throws {
        window.setContentSize(size)
        try await Task.sleep(for:.milliseconds(500))
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String:Any] else { return }
        if body["type"] as? String == "position", let p = body["value"] as? [String:Any] { positions.append(p) }
        guard body["type"] as? String == "ready" else { return }
        Task { @MainActor in
            do {
                let data = try Data(contentsOf:resources.appendingPathComponent("QuietHours.epub"))
                for mode in ["scroll","paged"] {
                    for (full,notes) in [(NSSize(width:1194,height:752),NSSize(width:713,height:752)),
                                         (NSSize(width:834,height:1112),NSSize(width:834,height:467)),
                                         (NSSize(width:600,height:718),NSSize(width:600,height:286))] {
                        try await resize(full)
                        _ = try await web.callAsyncJavaScript("""
                        const settings={theme:'paper',font:'sans',fontSize:32,lineHeight:1.65,margin:32,mode,
                          scrollMaxTextWidth:1040,paragraphSpacing:0.65,headingSpacing:0.75};
                        await reader.open(data,'',settings,null);
                        await reader.go('chapter1.xhtml');
                        await reader.turn('next');
                        if (mode==='scroll') await reader.turn('previous',0.25);
                        return true;
                        """,arguments:["data":data.base64EncodedString(),"mode":mode],in:nil,contentWorld:.page)
                        try await Task.sleep(for:.milliseconds(400))
                        let before = try positions.last.unwrap("Missing initial position")
                        let locator = try (before["locator"] as? String).unwrap("Missing CFI")
                        let progress = try (before["progress"] as? Double).unwrap("Missing progress")
                        for cycle in 0..<4 {
                            positions = []
                            try await resize(notes)
                            try check(!positions.isEmpty,"No position after opening notes")
                            try await resize(full)
                            let after = try positions.last.unwrap("Missing restored position")
                            try check(after["locator"] as? String == locator,"\(mode) \(full) cycle \(cycle): CFI changed: \(locator) -> \(after)")
                            try check(abs((after["progress"] as? Double ?? -1)-progress)<0.00001,"Progress changed after closing notes")
                            if mode == "scroll", let offset = before["viewportOffset"] as? Double {
                                try check(abs((after["viewportOffset"] as? Double ?? -1)-offset)<=1,"Partial-line position drifted")
                                try check(positions.allSatisfy { $0["locator"] as? String == locator },"A temporary resize position escaped to native persistence")
                            }
                            try check(positions.allSatisfy { ($0["userDriven"] as? Bool) == false },"Resize published user activity")
                        }
                        // Keyboard/layout animations may resize again before a restore finishes.
                        positions = []
                        for size in [notes,full,notes,full] {
                            window.setContentSize(size)
                            try await Task.sleep(for:.milliseconds(35))
                        }
                        _ = try await web.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page)
                        try await Task.sleep(for:.milliseconds(150))
                        try check(positions.last?["locator"] as? String == locator,"Rapid resizing lost the original passage: expected \(locator), got \(String(describing:positions.last))")
                        // Background layout must retain the last stable cursor until active.
                        positions = []
                        _ = try await web.callAsyncJavaScript("await reader.setActive(false); return true",arguments:[:],in:nil,contentWorld:.page)
                        try await resize(notes); try await resize(full)
                        try check(positions.isEmpty,"Background reflow escaped to persistence")
                        _ = try await web.callAsyncJavaScript("await reader.setActive(true); return true",arguments:[:],in:nil,contentWorld:.page)
                        try await Task.sleep(for:.milliseconds(200))
                        try check(positions.last?["locator"] as? String == locator,"Foreground restore lost its passage")
                        // Reading while notes are open establishes a new return position.
                        if mode == "scroll" {
                            try await resize(notes)
                            _ = try await web.callAsyncJavaScript("return await reader.turn('next',1)",arguments:[:],in:nil,contentWorld:.page)
                            try await Task.sleep(for:.milliseconds(350))
                            let moved = try positions.last.unwrap("Missing movement with notes open")
                            try await resize(full)
                            try check(positions.last?["locator"] as? String == moved["locator"] as? String,"Closing notes undid reading performed beside notes")
                        }
                        // Rotation/split-window changes can arrive during the initial book load.
                        let checkpoint = try positions.last.unwrap("Missing cursor before reopening")
                        let reopen = Task { @MainActor in
                            try await self.web.callAsyncJavaScript("""
                            return await reader.open(data,locator,{theme:'paper',font:'sans',fontSize:32,lineHeight:1.65,margin:32,mode,
                              scrollMaxTextWidth:1040,paragraphSpacing:0.65,headingSpacing:0.75},null,viewport);
                            """,arguments:["data":data.base64EncodedString(),"locator":checkpoint["locator"]!,"viewport":checkpoint["viewport"]!,"mode":mode],in:nil,contentWorld:.page)
                        }
                        try await Task.sleep(for:.milliseconds(35))
                        window.setContentSize(notes)
                        try await Task.sleep(for:.milliseconds(35))
                        window.setContentSize(full)
                        _ = try await reopen.value
                        let reopened = try await web.callAsyncJavaScript("return await reader.settledPosition()",arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
                        try check(reopened?["locator"] as? String == checkpoint["locator"] as? String,"Resize during book loading changed its saved passage")
                        print("PASS: \(mode) \(Int(full.width))x\(Int(full.height)); 4 notes cycles, CFI, offset, persistence events, continued reading")
                        _ = try await web.callAsyncJavaScript("reader.cancel(); return true",arguments:[:],in:nil,contentWorld:.page)
                    }
                }
                exit(0)
            } catch { print("FAIL: \(error) \((error as NSError).userInfo)"); exit(1) }
        }
    }
}
extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw NSError(domain:"ReaderResize",code:2,userInfo:[NSLocalizedDescriptionKey:message]) }
        return value
    }
}
let app = NSApplication.shared
let probe = ResizeProbe(); probe.start(); app.run()
