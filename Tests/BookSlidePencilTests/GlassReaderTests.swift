import XCTest
import SwiftUI
import UIKit
@testable import BookSlidePhone

@MainActor final class GlassReaderTests: XCTestCase {
    func testScrollingPageReachesThePhysicalScreenEdges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance = ReaderAppearance(); reader.appearance.mode = .scroll
        reader.appearance.fontSize = 24
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            reader.close(); window.isHidden = true; previous?.makeKey()
            try? FileManager.default.removeItem(at:root)
        }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        _ = try await reader.webView.callAsyncJavaScript("""
        await reader.settledPosition(); await reader.turn('next',8);
        // Put a real text line halfway through the bottom edge. Checking only
        // the WKWebView frame would miss an ancestor still clipping its ink.
        const lines=[...document.querySelectorAll('iframe')].flatMap(frame=>{
            const doc=frame.contentDocument, offset=frame.getBoundingClientRect().top;
            return [...doc.querySelectorAll('p')].flatMap(p=>{
                const range=doc.createRange(); range.selectNodeContents(p);
                return [...range.getClientRects()].map(r=>({top:offset+r.top,height:r.height,width:r.width}));
            });
        });
        const line=lines.find(r=>r.top>innerHeight-100 && r.top<innerHeight+100 && r.width>200 && r.height>20);
        if (!line) throw Error('Missing bottom-edge text fixture');
        document.querySelector('.epub-container').scrollTop+=line.top-(innerHeight-line.height/2);
        return true;
        """,arguments:[:],in:nil,contentWorld:.page)
        reader.readingControlsVisible = false
        try await Task.sleep(for:.milliseconds(300)); host.view.layoutIfNeeded()
        let page = reader.webView.convert(reader.webView.bounds,to:window)
        print("SCROLL_EDGE window=\(window.bounds) page=\(page) safe=\(window.safeAreaInsets)")
        let image = UIGraphicsImageRenderer(size:window.bounds.size).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image)
        attachment.name = "scroll-screen-edge-\(window.bounds.width > window.bounds.height ? "landscape" : "portrait")"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(page.minY,window.bounds.minY,accuracy:1,"Text must scroll out through the physical top edge")
        XCTAssertEqual(page.maxY,window.bounds.maxY,accuracy:1,"New lines must enter at the physical bottom edge, without a fixed empty strip")
        let bitmap = try XCTUnwrap(image.cgImage)
        let strip = try XCTUnwrap(bitmap.cropping(to:CGRect(x:0,y:bitmap.height-4,width:bitmap.width,height:4)))
        var pixels = [UInt8](repeating:0,count:strip.width*strip.height*4)
        let darkPixels = pixels.withUnsafeMutableBytes { bytes -> Int in
            guard let context = CGContext(data:bytes.baseAddress,width:strip.width,height:strip.height,bitsPerComponent:8,
                                          bytesPerRow:strip.width*4,space:CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(strip,in:CGRect(x:0,y:0,width:strip.width,height:strip.height))
            let data = bytes.bindMemory(to:UInt8.self)
            return stride(from:0,to:data.count,by:4).filter { data[$0]<120 && data[$0+1]<120 && data[$0+2]<120 }.count
        }
        XCTAssertGreaterThan(darkPixels,20,"Actual text ink must reach the last screen pixels, through every SwiftUI ancestor")
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("玻璃阅读页未完成排版")
        throw ReaderError.message("Glass reader timeout")
    }
    func testReadingUsesThePageHeightAndKeepsToolsUntilReadingResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.close(); window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil }
        try await Task.sleep(for:.milliseconds(200)); host.view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(host.view.bounds.height-reader.webView.bounds.height,60,"Floating controls must not reserve large top and bottom strips")
        let chapter = try XCTUnwrap(reader.chapters.indices.first { reader.chapters[$0].href.contains("chapter2.xhtml") })
        reader.readingControlsVisible = true
        XCTAssertTrue(reader.openReadingChapter(chapter))
        try await waitUntil { !reader.busy && reader.position?.chapterHref?.contains("chapter2.xhtml") == true }
        XCTAssertFalse(reader.readingControlsVisible)
        let viewport = reader.webView.bounds.size
        reader.readingControlsVisible = true
        try await Task.sleep(for:.milliseconds(4500))
        XCTAssertTrue(reader.readingControlsVisible,"Visible tools must not disappear while the reader is choosing an action")
        XCTAssertEqual(reader.webView.bounds.size,viewport,"Showing or hiding tools must not reflow the reading page")
        let image = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "reading-hidden-controls-full-height"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testProductionGlassChromeWithLightAndNightPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.appearance = ReaderAppearance(); reader.appearance.theme = "light"; reader.appearance.fontSize = 22
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:PhoneReadingView(reader:reader,ipadReceiver:IPadReaderReceiver(reader:reader)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            reader.close(); window.isHidden = true; previous?.makeKey()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:.portrait))
            try? FileManager.default.removeItem(at:root)
        }
        reader.open(try XCTUnwrap(reader.books.first?.id))
        try await waitUntil { !reader.loading && reader.position != nil && reader.inlineInk != nil }
        XCTAssertEqual(reader.inlineInkTool,.reading,"Reading starts without an active writing canvas")
        reader.readingControlsVisible = true
        XCTAssertEqual(reader.inlineInk?.canvas.bounds.size,reader.webView.bounds.size)
        print("BOOKSLIDE_GLASS_CAPTURE_light_\(window.bounds.width > window.bounds.height ? "landscape" : "portrait")")
        try await Task.sleep(for:.seconds(3))
        reader.appearance.theme = "night"; reader.appearance.mode = .paged
        host.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations:.landscapeLeft))
        try await Task.sleep(for:.seconds(1))
        try await waitUntil { !reader.busy && reader.position?.mode == .paged }
        XCTAssertEqual(reader.inlineInk?.canvas.bounds.size,reader.webView.bounds.size)
        print("BOOKSLIDE_GLASS_CAPTURE_night_\(window.bounds.width > window.bounds.height ? "landscape" : "portrait")")
        try await Task.sleep(for:.seconds(3))
    }
    func testGlassMenuAndProgressPanelsRenderOverThePage() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene:scene)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        reader.currentID = try XCTUnwrap(reader.books.first?.id)
        reader.position = EnginePosition(chapterHref:nil,viewportOffset:nil,anchor:nil,userDriven:nil,mode:.scroll,locator:"current",chapter:"第一章 · 阅读与思考",page:3,pageCount:12,progress:0.35,canGoNext:true,canGoPrevious:true)
        let menu = ReaderMenuPanel(reader:reader,navigate:{_ in},perform:{_ in},close:{})
            .environment(\.readerGlassPanel,true).frame(width:344,height:500)
            .modifier(ReaderGlassSurface(shape:RoundedRectangle(cornerRadius:28)))
        let host = UIHostingController(rootView:ZStack {
            Color(white:0.27).ignoresSafeArea()
            VStack(alignment:.leading,spacing:28) {
                ForEach(0..<10) { _ in Text("在文字之间，留一点时间给阅读。\n把想法留在读到的地方。").font(.system(size:26)).foregroundStyle(.white.opacity(0.9)) }
            }.padding(32)
            menu.padding(.trailing,24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing).padding(.bottom,76)
        })
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at:root) }
        try await Task.sleep(for:.milliseconds(500))
        print("BOOKSLIDE_GLASS_CAPTURE_menu")
        try await Task.sleep(for:.seconds(3))
    }
}
