import Foundation
import WebKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Only immutable, UUID-addressed ink images are exposed to the offline host.
final class ReaderPageNoteSchemeHandler: NSObject, WKURLSchemeHandler {
    let store: ReaderPageNoteStore
    init(directory: URL) { store = ReaderPageNoteStore(libraryDirectory:directory) }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host, let id = UUID(uuidString:host),
              ["/ink.png","/preview.png"].contains(url.path) else { urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission)); return }
        do {
            let data: Data
            if url.path=="/preview.png" {
                let values=Dictionary((URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ first,_ in first })
                guard let x=Double(values["x"] ?? ""),let y=Double(values["y"] ?? ""),let w=Double(values["w"] ?? ""),let h=Double(values["h"] ?? "") else { throw CocoaError(.fileReadNoPermission) }
                data=try store.croppedPreview(id,rect:.init(x:x,y:y,width:w,height:h))
            } else { data=try store.image(id,name:"ink.png") }
            urlSchemeTask.didReceive(URLResponse(url:url,mimeType:"image/png",expectedContentLength:data.count,textEncodingName:nil))
            urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

