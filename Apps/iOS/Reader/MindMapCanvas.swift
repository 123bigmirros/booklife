import SwiftUI
import WebKit
import UIKit

/// Mind Elixir renders and operates the map; Swift owns the book's graph and editors.
struct MindMapCanvas: UIViewRepresentable {
    @ObservedObject var reader: ReaderModel
    let document: MindMapDocument
    let includeFuture: Bool
    var editor = false
    var expandedNode: String?
    var expandedSize: CGSize?
    var enabled = true
    var focus: String?
    var focusRequest = UUID()
    var command: MindMapCommand?
    let selected: (String,CGRect?) -> Void
    let action: (String,String,CGRect?) -> Void
    let edgeSelected: (ReadingEdge.ID) -> Void
    let frameChanged: (String,CGRect) -> Void
    var contentFrameChanged: ((String,CGRect?) -> Void)?
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        reader.mindMapInputFlush = (coordinator.flushID,{ [weak coordinator] in await coordinator?.flushInput() ?? true })
        return coordinator
    }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MindMapResources(),forURLScheme:"bookcanvas")
        config.setURLSchemeHandler(ReaderPageNoteSchemeHandler(directory:reader.directory),forURLScheme:"bookslide-ink")
        config.userContentController.add(context.coordinator,name:"mindmap")
        let web = WKWebView(frame:.zero,configuration:config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false; web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never; web.allowsLinkPreview = false
        web.accessibilityIdentifier = "book-note-graph-viewport"
        context.coordinator.web = web
        web.load(URLRequest(url:URL(string:"bookcanvas://local/index.html")!))
        return web
    }
    func updateUIView(_ web: WKWebView,context: Context) {
        context.coordinator.parent = self
        web.isUserInteractionEnabled = enabled
        context.coordinator.send()
    }
    static func dismantleUIView(_ web: WKWebView,coordinator: Coordinator) {
        if coordinator.parent.reader.mindMapInputFlush?.id == coordinator.flushID { coordinator.parent.reader.mindMapInputFlush = nil }
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName:"mindmap")
        coordinator.web = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MindMapCanvas
        weak var web: WKWebView?
        let flushID = UUID()
        let session = UUID().uuidString
        let bookID: UUID?
        var baseline: MindMapDocument
        var recovery: MindMapRecovery?
        var loaded = false, sending = false, pending = false
        var pendingSelection: (token:String,revision:Int)?
        var selectionRevision = 0
        var revision = 0
        init(_ parent: MindMapCanvas) {
            self.parent = parent; bookID = parent.reader.currentID
            recovery = bookID.flatMap { parent.reader.loadMindMapRecovery($0) }
            baseline = recovery?.baseline ?? parent.document
        }
        func send() {
            guard loaded, let web, parent.reader.currentID == bookID else { return }
            guard !sending else { pending = true; return }
            sending = true; revision += 1
            // A camera request may already be in flight when the user taps a new
            // card. Acknowledge that tap only once SwiftUI reflects the same target.
            if let selection = pendingSelection, selection.token == parent.focus {
                selectionRevision = selection.revision; pendingSelection = nil
            }
            do {
                let document = recovery?.document ?? parent.reader.mindMapDocument(includeFuture:parent.includeFuture)
                let colors = ReadingGraphColors(theme:parent.reader.appearance.theme)
                let payload: [String:Any] = ["session":session,"document":try parent.reader.dictionary(document),"version":revision,
                    "editor":parent.editor,
                    "expandedNode":parent.expandedNode as Any? ?? NSNull(),"expandedSize":parent.expandedSize.map { ["width":$0.width,"height":$0.height] } as Any? ?? NSNull(),
                    "selectionRevision":selectionRevision,"focus":parent.focus as Any? ?? NSNull(),"focusRequest":parent.focusRequest.uuidString,
                    "dark":colors.dark,"theme":parent.reader.appearance.theme,"colors":colors.css]
                var arguments: [String:Any] = ["payload":payload,"command":NSNull()]
                if parent.enabled, let command = parent.command { arguments["command"] = ["id":command.id.uuidString,"name":command.name,"target":command.target as Any? ?? NSNull()] }
                web.callAsyncJavaScript("await window.bookMindMap.update(payload); if(command) window.bookMindMap.command(command);",arguments:arguments,in:nil,in:.page) { [weak self] result in
                    guard let self else { return }; sending = false
                    if case .failure(let error) = result { parent.failed("结构图载入失败：\(error.localizedDescription)") }
                    if pending { pending = false; send() }
                }
            } catch { sending = false; parent.failed(error.localizedDescription) }
        }
        // Commit the browser's live contentEditable before its host is removed.
        // Returning the snapshot over the JS completion channel lets Swift
        // finish persistence even if the normal change message is still queued.
        @MainActor func flushInput() async -> Bool {
            guard parent.reader.currentID == bookID else { return true }
            guard loaded, let web, let bookID else { return true }
            do {
                let object = try await web.callAsyncJavaScript("document.getElementById('input-box')?.blur(); const state=window.bookMindMap.inspect(); return {data:state.data,needsSave:state.saving || state.pending || state.unsaved}",arguments:[:],in:nil,contentWorld:.page)
                guard parent.reader.currentID == bookID else { return true }
                guard let result = object as? [String:Any] else { parent.failed("编辑内容尚未提交，请稍后再关闭。"); return false }
                // Merely opening an empty note must not create a saved node.
                guard result["needsSave"] as? Bool == true else { return true }
                guard let document = result["data"], JSONSerialization.isValidJSONObject(document),
                      let incoming = try? JSONDecoder().decode(MindMapDocument.self,from:JSONSerialization.data(withJSONObject:document)) else {
                    parent.failed("编辑内容尚未提交，请稍后再关闭。"); return false
                }
                let saved = parent.reader.applyMindMapDocument(incoming,baseline:baseline,bookID:bookID)
                if saved { baseline = parent.reader.mindMapDocument(includeFuture:parent.includeFuture); recovery = nil }
                else { recovery = .init(bookID:bookID,document:incoming,baseline:baseline); parent.failed(parent.reader.error ?? "修改尚未保存，请重试。") }
                return saved
            } catch { parent.failed("编辑内容尚未保存：\(error.localizedDescription)"); return false }
        }
        private func rectangle(_ value: Any?) -> CGRect? {
            guard let v = value as? [String:Double], let x = v["x"], let y = v["y"], let w = v["width"], let h = v["height"],
                  [x,y,w,h].allSatisfy(\.isFinite) else { return nil }
            return CGRect(x:x,y:y,width:w,height:h)
        }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === web, parent.reader.currentID == bookID,
                  let body = message.body as? [String:Any], let type = body["type"] as? String else { return }
            if type == "loaded" { loaded = true; send(); return }
            guard body["session"] as? String == session else { return }
            if let revision = body["selectionRevision"] as? Int {
                if type == "select", let token = body["id"] as? String {
                    pendingSelection = (token,revision)
                } else {
                    selectionRevision = revision; pendingSelection = nil
                }
            }
            switch type {
            case "ready":
                if let draft = recovery, let bookID {
                    let saved = parent.reader.applyMindMapDocument(draft.document,baseline:draft.baseline,bookID:bookID)
                    if saved { recovery = nil; baseline = parent.reader.mindMapDocument(includeFuture:parent.includeFuture) }
                    else { parent.failed(parent.reader.error ?? "已恢复导图草稿，等待重试保存。") }
                }
            case "select":
                if let id = body["id"] as? String { parent.selected(id,rectangle(body["rect"])) }
            case "frame":
                if let id = body["id"] as? String, let rect = rectangle(body["rect"]) { parent.frameChanged(id,rect) }
                if let id = body["id"] as? String { parent.contentFrameChanged?(id,rectangle(body["contentRect"])) }
            case "action":
                if let id = body["id"] as? String, let name = body["action"] as? String { parent.action(name,id,rectangle(body["rect"])) }
            case "edge":
                if let value = body["edgeID"], let data = try? JSONSerialization.data(withJSONObject:value), let id = try? JSONDecoder().decode(ReadingEdge.ID.self,from:data) { parent.edgeSelected(id) }
            case "change":
                guard let bookID, let object = body["document"], JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject:object), data.count <= 16*1024*1024,
                      let incoming = try? JSONDecoder().decode(MindMapDocument.self,from:data) else { acknowledge(false,"导图内容无效，尚未保存。"); return }
                let saved = parent.reader.applyMindMapDocument(incoming,baseline:baseline,bookID:bookID)
                if saved { baseline = parent.reader.mindMapDocument(includeFuture:parent.includeFuture); recovery = nil }
                else { recovery = .init(bookID:bookID,document:incoming,baseline:baseline); parent.failed(parent.reader.error ?? "修改暂未保存。") }
                acknowledge(saved,parent.reader.error ?? "")
            case "error": parent.failed(body["message"] as? String ?? "结构图发生错误。")
            default: break
            }
        }
        func acknowledge(_ ok: Bool,_ error: String) {
            web?.callAsyncJavaScript("window.bookMindMap.ack(ok,error)",arguments:["ok":ok,"error":error],in:nil,in:.page,completionHandler:nil)
        }
        func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "bookcanvas" ? .allow : .cancel)
        }
    }
}
private final class MindMapResources: NSObject,WKURLSchemeHandler {
    func webView(_ webView: WKWebView,start task: WKURLSchemeTask) {
        let allowed = ["index.html":"text/html","canvas.js":"application/javascript","canvas.css":"text/css","vendor/MindElixir.js":"application/javascript","vendor/i18n.js":"application/javascript","vendor/MindElixir.css":"text/css"]
        guard let url = task.request.url, url.host == "local", let mime = allowed[String(url.path.dropFirst())] else { task.didFailWithError(CocoaError(.fileReadNoPermission)); return }
        do {
            let data = try Data(contentsOf:ReaderModel.resources.appendingPathComponent("MindMap").appendingPathComponent(String(url.path.dropFirst())))
            task.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView,stop task: WKURLSchemeTask) {}
}
