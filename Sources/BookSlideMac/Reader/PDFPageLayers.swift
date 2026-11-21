import PDFKit
import SwiftUI
#if os(iOS)
import PencilKit
#endif
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// PDFKit lays out and rotates these views with their original pages. Ink is
/// stored in unscaled crop-box coordinates, using the shared page-note store.
@MainActor final class PDFPageLayers: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    static let layoutKey = "pdf-crop-box-v1"
    private var views: [PDFPage: PDFInkPageView] = [:]
    private weak var view: PDFView?
    private var notesByPage: [String: [(noteID: UUID, part: ReaderInkPart)]] = [:]
    private var store: ReaderPageNoteStore?
    private let images = NSCache<NSUUID,ReaderImage>()
    private var liveCanvasID: UUID?
    #if os(iOS)
    weak var controller: ReaderInlineInkController?
    private(set) weak var editingPage: PDFPage?
    #endif

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NativeReadingView? {
        self.view = view
        let overlay = PDFInkPageView()
        views[page] = overlay
        redraw(page)
        return overlay
    }

    func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: NativeReadingView, for page: PDFPage) {
        #if os(iOS)
        if page == view.currentPage { attach(to:page) }
        #endif
    }

    func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: NativeReadingView, for page: PDFPage) {
        #if os(iOS)
        if editingPage == page, controller?.suspend() != false {
            controller?.canvas.removeFromSuperview()
            editingPage = nil
        }
        #endif
        if views[page] === overlayView { views.removeValue(forKey:page) }
    }

    func update(_ notes: [ReaderPageNote], store: ReaderPageNoteStore) {
        self.store = store
        notesByPage = Dictionary(grouping:notes.flatMap { note in
            note.inkParts.filter { $0.anchor.layoutKey == Self.layoutKey }.map { (note.id,$0) }
        },by:{ $0.1.anchor.locator })
        for page in views.keys { redraw(page) }
    }

    func setLiveCanvas(_ id: UUID?) {
        guard liveCanvasID != id else { return }
        liveCanvasID = id
        for page in views.keys { redraw(page) }
    }

    private func redraw(_ page: PDFPage) {
        guard let overlay = views[page], let document = page.document else { return }
        let index = document.index(for:page)
        guard index >= 0, index < document.pageCount else { return }
        let locator = PDFPageLocator.encode(index)
        let images = notesByPage[locator,default:[]].compactMap { _, part -> ReaderImage? in
            guard part.canvasID != liveCanvasID else { return nil }
            let key = part.assetID as NSUUID
            if let image = self.images.object(forKey:key) { return image }
            guard let store, let data = try? store.image(part.assetID,name:"ink.png"),
                  let image = ReaderImage(data:data) else { return nil }
            self.images.setObject(image,forKey:key,cost:data.count)
            return image
        }
        self.images.totalCostLimit = 16 * 1024 * 1024
        overlay.show(images)
    }

    #if os(iOS)
    func attach(to page: PDFPage?) {
        guard let controller else { return }
        guard let page, let layer = views[page] else { return }
        if editingPage == page, controller.canvas.superview === layer { return }
        guard controller.suspend() else { return }
        let canvas = controller.canvas
        canvas.removeFromSuperview()
        layer.addSubview(canvas)
        canvas.frame = layer.bounds
        canvas.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        editingPage = page
    }

    func setWritingEnabled(_ enabled: Bool) {
        guard let view, view.isInMarkupMode != enabled else { return }
        view.isInMarkupMode = enabled
    }
    #endif
}

private final class PDFInkPageView: NativeReadingView {
    private let layerView = CALayer()

    #if os(macOS)
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        layer?.addSublayer(layerView)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); resizeLayers() }
    #else
    override init(frame: CGRect) {
        super.init(frame:frame)
        isOpaque = false
        layer.addSublayer(layerView)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Transparent areas remain native PDF touch targets.
        let target = super.hitTest(point,with:event)
        return target === self ? nil : target
    }
    override func layoutSubviews() { super.layoutSubviews(); resizeLayers() }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ images: [ReaderImage]) {
        layerView.sublayers = images.compactMap { image in
            #if os(macOS)
            var bounds = CGRect(origin:.zero,size:image.size)
            guard let bitmap = image.cgImage(forProposedRect:&bounds,context:nil,hints:nil) else { return nil }
            #else
            guard let bitmap = image.cgImage else { return nil }
            #endif
            let layer = CALayer()
            layer.contents = bitmap
            layer.contentsGravity = .resize
            return layer
        }
        resizeLayers()
    }

    private func resizeLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerView.frame = bounds
        layerView.sublayers?.forEach { $0.frame = layerView.bounds }
        CATransaction.commit()
    }
}
