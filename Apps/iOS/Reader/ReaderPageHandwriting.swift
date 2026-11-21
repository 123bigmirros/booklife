import SwiftUI
import UIKit
import WebKit
import PencilKit
import CryptoKit

enum ReaderInkTool: String, CaseIterable {
    case pen, marker, eraser, lasso, reading
    var title: String {
        switch self { case .pen: return "笔"; case .marker: return "荧光笔"; case .eraser: return "橡皮擦"; case .lasso: return "套索"; case .reading: return "阅读" }
    }
    var symbol: String {
        switch self { case .pen: return "pencil.tip"; case .marker: return "highlighter"; case .eraser: return "eraser"; case .lasso: return "lasso"; case .reading: return "hand.draw" }
    }
}

enum ReaderPencilGestureSource { case tap, squeeze }

enum ReaderInkColor: String, CaseIterable {
    case ink, red, blue, green, yellow
    var title: String {
        switch self { case .ink: return "正文色"; case .red: return "红色"; case .blue: return "蓝色"; case .green: return "绿色"; case .yellow: return "黄色" }
    }
    func color(appearance: ReaderAppearance) -> Color {
        switch self {
        case .ink: return appearance.ink
        case .red: return Color(red:0.84,green:0.22,blue:0.23)
        case .blue: return Color(red:0.18,green:0.43,blue:0.78)
        case .green: return Color(red:0.22,green:0.56,blue:0.36)
        case .yellow: return Color(red:0.94,green:0.71,blue:0.17)
        }
    }
}

private struct ReaderInkStyle: Equatable {
    let tool: ReaderInkTool
    let color: ReaderInkColor
    let width: CGFloat
    init(_ reader: ReaderModel) {
        tool = reader.inlineInkTool; color = reader.inlineInkColor; width = reader.inlineInkWidth
    }
    init(tool: ReaderInkTool,color: ReaderInkColor,width: CGFloat) {
        self.tool = tool; self.color = color; self.width = width
    }
}

struct ReaderPageHandwritingDraft: Identifiable {
    let bookID: UUID
    let note: ReaderPageNote
    let page: UIImage
    let drawing: PKDrawing
    var recovered = false
    var id: UUID { note.id }
}

struct LivePageInkContext: Decodable {
    struct Placement: Decodable { let id: UUID; let x: Double; let y: Double }
    let anchor: ReaderPageAnchor
    let placements: [Placement]
    let token: String
}

/// A stable overlay above the EPUB and below the companion. Only temporary
/// paper snapshots live here; it never owns book content or handles touches.
struct ReaderCompanionPageSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView {
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ uiView: UIView,context: Context) {}
}

enum ReaderCompanionMotion {
    static let duration = 0.42
    static let first = CGPoint(x:0.32,y:0)
    static let second = CGPoint(x:0.20,y:1)
}

/// The EPUB and PencilKit share one viewport. Only Pencil touches go to the
/// canvas; finger input continues into WebKit, including selection and links.
final class ReaderPencilHost: UIView {
    let reader: ReaderModel
    let ink: ReaderInlineInkController
    private var companionCover: UIView?
    private var companionCoverID = UUID()
    private var companionCoverFinishing = false
    private var companionGeometryReady = false
    private var companionContentReady = false
    private var companionSnapshot: UIView?
    private var companionAnimator: UIViewPropertyAnimator?
    private var companionRevealAnimator: UIViewPropertyAnimator?
    private var companionDestination: CGRect?
    private var companionNeedsTextHandoff = false
    private var companionBeforeReveal: (() async -> Void)?
    private var companionWebAlpha: CGFloat?
    private var companionInkAlpha: CGFloat?
    private var companionInitialInset: CGFloat = 0
    private var companionCompletion: (() -> Void)?
    private var companionInteractionBeforeCover: Bool?
    private var companionSettleTask: Task<Void,Never>?
    private var companionDeadlineTask: Task<Void,Never>?
    init(reader: ReaderModel) {
        self.reader = reader; ink = ReaderInlineInkController(reader:reader)
        super.init(frame:.zero)
        clipsToBounds = true
        addSubview(reader.webView); addSubview(ink.canvas)
        // hitTest runs before UIKit populates UIEvent.allTouches. Observe
        // drawing on the common ancestor so PencilKit sees the real UITouch
        // even when WebKit is the initial hit view. Keep PencilKit's own
        // recognizer and delegate; drawingPolicy filters Pencil vs fingers.
        addGestureRecognizer(ink.canvas.drawingGestureRecognizer)
        ink.canvas.drawingGestureRecognizer.isEnabled = false
        reader.webView.scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value:UITouch.TouchType.direct.rawValue),
            NSNumber(value:UITouch.TouchType.indirectPointer.rawValue)
        ]
        reader.webView.scrollView.panGestureRecognizer.require(toFail:ink.canvas.drawingGestureRecognizer)
        addInteraction(ink.pencilInteraction)
        reader.inlineInk = ink
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearCompanionCover(); ink.stop() } else { ink.start() }
    }
    /// Move the visible paper while WebKit lays out once beneath an opaque
    /// cover. A reversal continues from the presentation layer, not a new page.
    func prepareCompanionTransition(in surface: UIView,beforeReveal: (() async -> Void)? = nil,completion: @escaping () -> Void) {
        let retainedCover = companionCover?.superview === surface && !companionCoverFinishing ? companionCover : nil
        let retainedPage = retainedCover == nil ? nil : companionSnapshot
        if retainedCover != nil { freezeCompanionMotion() }
        clearCompanionCover()
        guard window != nil, surface.window === window, bounds.width > 0, bounds.height > 0, !reader.loading,
              let page = retainedPage ?? snapshotView(afterScreenUpdates:false) else { completion(); return }
        let cover = retainedCover ?? UIView(frame:convert(bounds,to:surface))
        cover.backgroundColor = UIColor(reader.appearance.background)
        cover.clipsToBounds = true
        if retainedCover == nil {
            page.frame = bounds; page.autoresizingMask = []
            cover.addSubview(page)
        }
        cover.accessibilityElementsHidden = true
        cover.isUserInteractionEnabled = false
        surface.addSubview(cover); companionCover = cover; companionSnapshot = page
        companionInitialInset = companionTextInset(width:page.bounds.width)
        companionCompletion = completion; companionBeforeReveal = beforeReveal
        companionInteractionBeforeCover = isUserInteractionEnabled; isUserInteractionEnabled = false
        let token = companionCoverID, session = reader.annotationSessionID
        // A same-size request (or a rapid reversal) still needs a completion.
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.companionCoverID else { return }
            self.settleCompanionCover()
        }
        companionDeadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(1500)) } catch { return }
            guard let self, token == self.companionCoverID, session == self.reader.annotationSessionID else { return }
            // The deadline may finish the visual movement, but must still run
            // the position restore before uncovering a slowly reflowing page.
            self.companionGeometryReady = true; self.companionContentReady = true
            self.finishCompanionCover(token:token,session:session)
        }
    }
    func cancelCompanionTransition() { clearCompanionCover() }
    private func companionTextInset(width: CGFloat) -> CGFloat {
        let appearance = reader.appearance
        guard appearance.mode == .scroll, appearance.margin > 0 else { return 0 }
        let measure = min(1040,max(960,appearance.fontSize*48))
        return max(0,(width-CGFloat(measure))/2)
    }
    private func freezeCompanionMotion() {
        let frame = companionCover?.layer.presentation()?.frame
        let transform = companionSnapshot?.layer.presentation()?.affineTransform()
        let opacity = companionSnapshot?.layer.presentation()?.opacity
        if companionAnimator?.state == .active { companionAnimator?.stopAnimation(true) }; companionAnimator = nil
        companionCover?.layer.removeAllAnimations(); companionSnapshot?.layer.removeAllAnimations()
        if let frame { companionCover?.frame = frame }
        if let transform { companionSnapshot?.transform = transform }
        if let opacity { companionSnapshot?.alpha = CGFloat(opacity) }
    }
    private func settleCompanionCover() {
        guard let cover = companionCover, let surface = cover.superview, !companionCoverFinishing else { return }
        let destination = convert(bounds,to:surface)
        guard companionDestination != destination else { return }
        freezeCompanionMotion()
        companionDestination = destination
        companionNeedsTextHandoff = abs((companionSnapshot?.bounds.width ?? bounds.width)-bounds.width) > 1 || reader.appearance.mode == .paged
        companionSettleTask?.cancel()
        let token = companionCoverID, session = reader.annotationSessionID
        companionGeometryReady = false; companionContentReady = false
        let translation = companionTextInset(width:bounds.width)-companionInitialInset
        let motion = {
            cover.frame = destination
            self.companionSnapshot?.transform = CGAffineTransform(translationX:translation,y:0)
            self.companionSnapshot?.alpha = 1
        }
        let arrived = { [weak self] in
            guard let self, token == self.companionCoverID else { return }
            self.companionGeometryReady = true
            self.finishCompanionCover(token:token,session:session)
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(motion); arrived()
        } else {
            let animator = UIViewPropertyAnimator(duration:ReaderCompanionMotion.duration,timingParameters:UICubicTimingParameters(
                controlPoint1:ReaderCompanionMotion.first,controlPoint2:ReaderCompanionMotion.second))
            companionAnimator = animator
            animator.addAnimations(motion)
            animator.addCompletion { _ in arrived() }
            animator.startAnimation()
        }
        companionSettleTask = Task { @MainActor [weak self, weak web = reader.webView] in
            do { try await Task.sleep(for:.milliseconds(24)) } catch { return }
            guard let web, !Task.isCancelled else { return }
            _ = try? await web.callAsyncJavaScript("await window.reader?.settledPosition?.(); return true;",arguments:[:],in:nil,contentWorld:.page)
            guard let self, !Task.isCancelled, token == self.companionCoverID else { return }
            self.companionContentReady = true
            self.finishCompanionCover(token:token,session:session)
        }
    }
    private func finishCompanionCover(token: UUID,session: UUID) {
        guard token == companionCoverID, !companionCoverFinishing, companionCover != nil else { return }
        guard session == reader.annotationSessionID, window != nil else { clearCompanionCover(); return }
        guard companionGeometryReady && companionContentReady else { return }
        companionCoverFinishing = true
        companionSettleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Restore the passage in both directions while the opaque paper
            // still covers the renderer, before any new text becomes visible.
            await self.companionBeforeReveal?()
            guard !Task.isCancelled, token == self.companionCoverID, session == self.reader.annotationSessionID else { return }
            self.revealCompanionPage(token:token)
        }
    }
    private func revealCompanionPage(token: UUID) {
        guard token == companionCoverID, let cover = companionCover else { return }
        if !companionNeedsTextHandoff {
            // A height-only change keeps the same lines. Reveal them directly
            // rather than making the whole page flash on portrait open/close.
            completeCompanionTransition(token:token)
            return
        }
        // Hand off through opaque paper only after the destination is ready.
        // Two different line layouts must never be visible at the same time.
        let animator = UIViewPropertyAnimator(duration:UIAccessibility.isReduceMotionEnabled ? 0 : 0.06,curve:.easeOut) {
            self.companionSnapshot?.alpha = 0
        }
        companionRevealAnimator = animator
        animator.addCompletion { [weak self, weak cover] _ in
            guard let self, let cover, token == self.companionCoverID else { return }
            self.showCompanionContent(token:token,cover:cover)
        }
        animator.startAnimation()
    }
    private func showCompanionContent(token: UUID,cover: UIView) {
        companionWebAlpha = reader.webView.alpha; companionInkAlpha = ink.canvas.alpha
        reader.webView.alpha = 0; ink.canvas.alpha = 0
        cover.removeFromSuperview(); companionCover = nil; companionSnapshot = nil
        let animator = UIViewPropertyAnimator(duration:UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.14,curve:.easeOut) {
            self.reader.webView.alpha = self.companionWebAlpha ?? 1
            self.ink.canvas.alpha = self.companionInkAlpha ?? 1
        }
        companionRevealAnimator = animator
        animator.addCompletion { [weak self] _ in self?.completeCompanionTransition(token:token) }
        animator.startAnimation()
    }
    private func completeCompanionTransition(token: UUID) {
        guard token == companionCoverID else { return }
        let completed = companionCompletion
        clearCompanionCover()
        completed?()
    }
    private func clearCompanionCover() {
        companionCoverID = UUID(); companionCoverFinishing = false
        companionGeometryReady = false; companionContentReady = false; companionDestination = nil
        companionNeedsTextHandoff = false
        companionSettleTask?.cancel(); companionDeadlineTask?.cancel()
        if companionAnimator?.state == .active { companionAnimator?.stopAnimation(true) }; companionAnimator = nil
        if companionRevealAnimator?.state == .active { companionRevealAnimator?.stopAnimation(true) }; companionRevealAnimator = nil
        companionCover?.layer.removeAllAnimations(); companionCover?.removeFromSuperview(); companionCover = nil
        companionSnapshot = nil; companionCompletion = nil; companionBeforeReveal = nil
        if let alpha = companionWebAlpha { reader.webView.layer.removeAllAnimations(); reader.webView.alpha = alpha; companionWebAlpha = nil }
        if let alpha = companionInkAlpha { ink.canvas.layer.removeAllAnimations(); ink.canvas.alpha = alpha; companionInkAlpha = nil }
        if let enabled = companionInteractionBeforeCover { isUserInteractionEnabled = enabled; companionInteractionBeforeCover = nil }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = reader.webView.frame.size != bounds.size
        if resized { _ = ink.suspend() }
        reader.webView.frame = bounds; ink.canvas.frame = bounds
        if resized { settleCompanionCover() }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, bounds.contains(point) else { return nil }
        let pencil = event?.allTouches?.contains { $0.type == .pencil } == true
        if reader.inlineInkTool != .reading && (pencil || (UIDevice.current.userInterfaceIdiom != .pad && reader.inlineInkToolsVisible)) {
            guard ink.ready else { return self }
            return ink.canvas.hitTest(convert(point,to:ink.canvas),with:event)
        }
        // Hit testing may run repeatedly before the new UITouch exists.
        // Finger navigation saves ink in ReaderTouchInput.shouldReceive.
        if ink.isDrawing { return self }
        return reader.webView.hitTest(convert(point,to:reader.webView),with:event)
    }
}

@MainActor
final class ReaderInlineInkController: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let canvas = PKCanvasView()
    let pencilInteraction = UIPencilInteraction()
    private weak var reader: ReaderModel?
    private weak var pdf: PDFBookReader?
    private var polling: Task<Void,Never>?
    private var draftWork: Task<Void,Never>?
    private var generation = UUID()
    private var stableToken: String?
    private var activeToken: String?
    private var offset = CGPoint.zero
    private var savedDrawing = Data()
    private var recovered = false
    private var pageData: Data?
    private var appliedTool: (tool: ReaderInkTool,color: UIColor,width: CGFloat)?
    private var currentStyle: ReaderInkStyle?
    private var previousStyle: ReaderInkStyle?
    private var lastNonEraserStyle: ReaderInkStyle?
    private var lastWritingStyle: ReaderInkStyle?
    private var pendingPencilAction: (action: UIPencilPreferredAction, source: ReaderPencilGestureSource)?
    private(set) var draft: ReaderPageHandwritingDraft?
    private(set) var isDrawing = false
    var ready: Bool { draft != nil && !canvas.isHidden }
    init(reader: ReaderModel, pdf: PDFBookReader? = nil) {
        self.reader = reader
        self.pdf = pdf
        super.init()
        pencilInteraction.delegate = self
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.isScrollEnabled = false; canvas.bounces = false
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        updateTools()
        canvas.delegate = self; canvas.isHidden = true
        canvas.accessibilityLabel = "正文上的 Pencil 笔迹"
    }
    func start() {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(for:.milliseconds(150)) } catch { break }
            }
        }
    }
    func stop() {
        pendingPencilAction = nil
        if isDrawing {
            _ = keepDraft(); isDrawing = false
            reader?.handwritingActive = false
            setHandwriting(false)
        }
        _ = suspend()
        polling?.cancel(); polling = nil
    }
    func updateTools() {
        guard let reader, !isDrawing else { return }
        if reader.inlineInkTool == .reading, draft != nil, !suspend() {
            // A failed save keeps the original drawing mode and editable ink.
            reader.inlineInkTool = currentStyle?.tool ?? .pen
            return
        }
        if let pdf {
            pdf.pageLayers.setWritingEnabled(reader.inlineInkTool != .reading && ready)
        } else {
            (reader.webView as? ReaderTextWebView)?.setPencilReadingEnabled(reader.inlineInkTool == .reading)
        }
        // Tools never take first responder away from WebKit's text selection.
        let style = ReaderInkStyle(reader)
        if let currentStyle, currentStyle.tool != style.tool { previousStyle = currentStyle }
        currentStyle = style
        if style.tool != .eraser { lastNonEraserStyle = style }
        if style.tool != .eraser && style.tool != .reading { lastWritingStyle = style }
        let color = UIColor(reader.inlineInkColor.color(appearance:reader.appearance))
        if let appliedTool, appliedTool.tool == reader.inlineInkTool,
           appliedTool.color.isEqual(color), appliedTool.width == reader.inlineInkWidth {
            updateUndoState(); return
        }
        appliedTool = (reader.inlineInkTool,color,reader.inlineInkWidth)
        switch reader.inlineInkTool {
        case .pen: canvas.tool = PKInkingTool(.pen,color:color,width:reader.inlineInkWidth)
        case .marker: canvas.tool = PKInkingTool(.marker,color:color,width:reader.inlineInkWidth * 5)
        case .eraser: canvas.tool = PKEraserTool(.vector)
        case .lasso: canvas.tool = PKLassoTool()
        case .reading:
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.isHidden = true
        }
        updateUndoState()
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        performPencilAction(UIPencilInteraction.preferredTapAction)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,didReceiveTap tap: UIPencilInteraction.Tap) {
        performPencilAction(UIPencilInteraction.preferredTapAction)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        handlePencilSqueeze(squeeze.phase,action:UIPencilInteraction.preferredSqueezeAction)
    }
    @available(iOS 17.5, *)
    func handlePencilSqueeze(_ phase: UIPencilInteraction.Phase,action: UIPencilPreferredAction) {
        // A squeeze has began/changed/ended phases. Act once on release.
        if phase == .ended { performPencilAction(action,from:.squeeze) }
    }
    func performPencilAction(_ action: UIPencilPreferredAction, from source: ReaderPencilGestureSource = .tap) {
        guard action != .ignore, let reader, canvas.window != nil,
              reader.currentID != nil, !reader.loading, !reader.busy,
              !reader.inlineInkObscured, !reader.showNoteGraph, reader.selectionDiscussion == nil, reader.quickNoteDraft == nil,
              reader.pageNoteToView == nil, !reader.inlineInkSelectionActive, !reader.inlineInkMenuActive else { return }
        if #available(iOS 17.5, *), action == .runSystemShortcut { return }
        if isDrawing { pendingPencilAction = (action,source); return }
        updateTools() // Remember settings changed through the visible toolbar.
        if source == .squeeze {
            let next = reader.inlineInkTool == .reading
                ? writingStyle(reader)
                : ReaderInkStyle(tool:.reading,color:reader.inlineInkColor,width:reader.inlineInkWidth)
            apply(next,reader:reader)
            return
        }
        switch action {
        case .switchEraser:
            let next = reader.inlineInkTool == .reading ? writingStyle(reader) : reader.inlineInkTool == .eraser
                ? lastNonEraserStyle ?? ReaderInkStyle(tool:.pen,color:reader.inlineInkColor,width:reader.inlineInkWidth)
                : ReaderInkStyle(tool:.eraser,color:reader.inlineInkColor,width:reader.inlineInkWidth)
            apply(next,reader:reader)
        case .switchPrevious:
            if let previousStyle { apply(previousStyle,reader:reader) }
        case .showColorPalette, .showInkAttributes:
            reader.inlineInkToolsVisible.toggle()
        default:
            if #available(iOS 17.5, *), action == .showContextualPalette { reader.inlineInkToolsVisible.toggle() }
        }
    }
    private func writingStyle(_ reader: ReaderModel) -> ReaderInkStyle {
        lastWritingStyle ?? ReaderInkStyle(tool:.pen,color:reader.inlineInkColor,width:reader.inlineInkWidth)
    }
    private func apply(_ style: ReaderInkStyle,reader: ReaderModel) {
        if style.tool == .reading, !suspend() { return }
        reader.inlineInkTool = style.tool; reader.inlineInkColor = style.color; reader.inlineInkWidth = style.width
        updateTools()
        reader.showReadingNotice(style.tool == .reading ? "阅读 · 再侧捏恢复书写" : style.tool.title)
    }
    private func updateUndoState() {
        guard let reader else { return }
        let canUndo = canvas.undoManager?.canUndo == true, canRedo = canvas.undoManager?.canRedo == true
        if reader.inlineInkCanUndo != canUndo { reader.inlineInkCanUndo = canUndo }
        if reader.inlineInkCanRedo != canRedo { reader.inlineInkCanRedo = canRedo }
    }
    private func candidates(_ reader: ReaderModel) -> [ReaderPageNote] {
        var notes = reader.pageInkCanvases
        for saved in reader.inkNoteDrafts {
            notes.removeAll { $0.id == saved.id }; notes.append(saved.note)
        }
        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func context(_ notes: [ReaderPageNote], reader: ReaderModel) async throws -> LivePageInkContext? {
        if let pdf { return pdf.inkContext(notes) }
        let values = try JSONSerialization.jsonObject(with:JSONEncoder().encode(notes))
        guard let value = try await reader.webView.callAsyncJavaScript("return reader.livePageInkContext(notes)",
            arguments:["notes":values],in:nil,contentWorld:.page), !(value is NSNull) else { return nil }
        return try JSONDecoder().decode(LivePageInkContext.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func poll() async {
        guard let reader, !isDrawing, canvas.window != nil else { return }
        guard !reader.isPDFTextLayout, reader.inlineInkTool != .reading, (UIDevice.current.userInterfaceIdiom == .pad || reader.inlineInkToolsVisible), reader.currentID != nil,
              !reader.loading, !reader.busy, !reader.showNoteGraph, reader.selectionDiscussion == nil, reader.selectionEntity == nil, reader.quickNoteDraft == nil,
              !reader.inlineInkObscured, !reader.inlineInkMenuActive, reader.pageNoteToView == nil,
              !reader.handwritingActive, pdf == nil || !reader.inlineInkSelectionActive else { _ = suspend(); return }
        let session = reader.sessionID, mine = generation, notes = candidates(reader)
        do {
            guard let context = try await context(notes,reader:reader) else { _ = suspend(); return }
            guard session == reader.sessionID, mine == generation else { return }
            if context.token == activeToken, ready { return }
            if ready { guard suspend() else { return } }
            guard context.token == stableToken else { stableToken = context.token; return }
            let preparation = generation
            guard let bookID = reader.currentID else { return }
            let viewport = CGRect(x:0,y:0,width:context.anchor.viewportWidth,height:context.anchor.viewportHeight)
            let placement = context.placements.filter { placement in
                guard let note = notes.first(where:{ $0.id == placement.id }) else { return false }
                let union = CGRect(x:placement.x,y:placement.y,width:note.anchor.viewportWidth,height:note.anchor.viewportHeight).union(viewport)
                return union.width <= viewport.width*3 && union.height <= viewport.height*3
            }.min {
                abs($0.x)+abs($0.y) < abs($1.x)+abs($1.y)
            }
            var draft: ReaderPageHandwritingDraft
            let offset: CGPoint
            if let placement, let note = notes.first(where:{ $0.id == placement.id }) {
                guard let loaded = reader.pageHandwritingDraft(for:note) else { return }
                let original = CGRect(x:placement.x,y:placement.y,width:note.anchor.viewportWidth,height:note.anchor.viewportHeight)
                let union = original.union(viewport)
                if union.size != original.size {
                    // A scroll may expose fresh text beyond the original page.
                    // Expand its coordinate space so new strokes are never cropped.
                    let currentPage = try await snapshot(reader:reader)
                    var expanded = loaded.note
                    let shift = CGPoint(x:original.minX-union.minX,y:original.minY-union.minY)
                    expanded.anchor.referenceX += shift.x; expanded.anchor.referenceY += shift.y
                    expanded.anchor.viewportWidth = union.width; expanded.anchor.viewportHeight = union.height
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let paper = UIGraphicsImageRenderer(size:union.size,format:format).image { _ in
                        loaded.page.draw(in:CGRect(origin:shift,size:original.size))
                        currentPage.draw(in:CGRect(x:-union.minX,y:-union.minY,width:viewport.width,height:viewport.height))
                    }
                    draft = ReaderPageHandwritingDraft(bookID:bookID,note:expanded,page:paper,
                        drawing:loaded.drawing.transformed(using:CGAffineTransform(translationX:shift.x,y:shift.y)),recovered:loaded.recovered)
                    offset = union.origin
                } else {
                    draft = loaded; offset = original.origin
                }
            } else {
                // Snapshots are retained for export and reflow recovery only.
                // The reader continues to display the live EPUB under the canvas.
                let image = try await snapshot(reader:reader)
                draft = ReaderPageHandwritingDraft(bookID:bookID,note:ReaderPageNote(assetID:UUID(),anchor:context.anchor),page:image,drawing:PKDrawing())
                offset = .zero
            }
            let translated=(context.anchor.textSpans ?? []).map { span -> ReaderInkTextSpan in
                var span=span;span.boxes=span.boxes.map { .init($0.rect.offsetBy(dx:-offset.x,dy:-offset.y)) };return span
            }
            var anchored=draft.note
            let visibleIDs=Set(translated.map(\.id))
            anchored.anchor.textSpans=(anchored.anchor.textSpans ?? []).filter { !visibleIDs.contains($0.id) }+translated
            draft = .init(bookID:draft.bookID,note:anchored,page:draft.page,drawing:draft.drawing,recovered:draft.recovered)
            guard preparation == generation, session == reader.sessionID,
                  !reader.busy, !reader.loading, !reader.showNoteGraph, reader.selectionDiscussion == nil, reader.selectionEntity == nil,
                  !reader.inlineInkObscured, reader.inlineInkTool != .reading,
                  let after = try await self.context(notes,reader:reader), after.token == context.token else { return }
            self.draft = draft; self.offset = offset; recovered = draft.recovered
            pageData = draft.page.pngData()
            savedDrawing = draft.drawing.dataRepresentation()
            canvas.drawing = draft.drawing.transformed(using:CGAffineTransform(translationX:offset.x,y:offset.y))
            canvas.undoManager?.removeAllActions()
            activeToken = context.token
            if let pdf { pdf.pageLayers.setLiveCanvas(draft.id) }
            else {
                _ = try await reader.webView.callAsyncJavaScript("reader.setInlinePageInk(id)",arguments:["id":draft.id.uuidString],in:nil,contentWorld:.page)
            }
            guard preparation == generation, session == reader.sessionID else { return }
            canvas.isHidden = false
            canvas.drawingGestureRecognizer.isEnabled = true
            updateTools()
        } catch {
            // Loading/reflow can invalidate a range. Retry against a stable page.
            stableToken = nil
        }
    }
    private func snapshot(reader: ReaderModel) async throws -> UIImage {
        if let pdf { return try pdf.inkSnapshot() }
        _ = try await reader.webView.callAsyncJavaScript("reader.setPageInkSnapshot(true)",arguments:[:],in:nil,contentWorld:.page)
        do {
            let image = try await reader.webView.takeSnapshot(configuration:nil)
            _ = try await reader.webView.callAsyncJavaScript("reader.setPageInkSnapshot(false)",arguments:[:],in:nil,contentWorld:.page)
            return image
        } catch {
            _ = try? await reader.webView.callAsyncJavaScript("reader.setPageInkSnapshot(false)",arguments:[:],in:nil,contentWorld:.page)
            throw error
        }
    }
    private var originalDrawing: PKDrawing {
        canvas.drawing.transformed(using:CGAffineTransform(translationX:-offset.x,y:-offset.y))
    }
    @discardableResult func keepDraft() -> Bool {
        guard let reader, let draft, draft.bookID == reader.currentID else { return true }
        let drawing = originalDrawing
        guard recovered || drawing.dataRepresentation() != savedDrawing else { return true }
        do {
            guard let page = pageData else { throw ReaderError.message("原页暂时无法保存") }
            try reader.keepInkDraft(ReaderInkNoteDraft(bookID:draft.bookID,note:draft.note,page:page,drawing:drawing.dataRepresentation()))
            return true
        } catch { reader.inlineInkStatus = "笔迹尚未保存：\(error.localizedDescription)"; return false }
    }
    @discardableResult func persist() -> Bool {
        guard let reader, let draft, draft.bookID == reader.currentID else { return true }
        let drawing = originalDrawing, data = drawing.dataRepresentation()
        guard recovered || data != savedDrawing else { return true }
        // Keep an editable recovery copy before rendering/exporting the images.
        guard keepDraft() else { return false }
        let latest = draft.note
        do {
            let export = PagePencilCanvasController(drawing:drawing,size:CGSize(width:draft.note.anchor.viewportWidth,height:draft.note.anchor.viewportHeight),color:.black)
            guard reader.savePageNote(latest,files:try export.files(page:draft.page),bookID:draft.bookID) else {
                reader.inlineInkStatus = "笔迹保存失败，草稿已保留"; return false
            }
        } catch { reader.inlineInkStatus = "笔迹保存失败，草稿已保留"; return false }
        savedDrawing = data; recovered = false
        reader.inlineInkStatus = "笔迹已保存"
        return true
    }
    /// Called synchronously before any finger gesture or programmatic navigation.
    @discardableResult func suspend() -> Bool {
        guard !isDrawing else { return false }
        guard persist() else { return false }
        generation = UUID(); stableToken = nil; activeToken = nil
        guard draft != nil else { return true }
        draftWork?.cancel(); draftWork = nil
        draft = nil; pageData = nil; canvas.isHidden = true
        canvas.drawingGestureRecognizer.isEnabled = false
        updateTools()
        if let pdf { pdf.pageLayers.setLiveCanvas(nil) }
        else { reader?.webView.evaluateJavaScript("reader.setInlinePageInk(null)",completionHandler:nil) }
        return true
    }
    private func setHandwriting(_ active: Bool) {
        if pdf == nil {
            reader?.webView.evaluateJavaScript("reader.setPageHandwriting(\(active),false)",completionHandler:nil)
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard ready, let reader else { return }
        isDrawing = true; reader.handwritingActive = true
        reader.inlineInkStatus = nil
        setHandwriting(true)
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isDrawing = false
        reader?.handwritingActive = false
        setHandwriting(false)
        draftWork?.cancel(); draftWork = nil
        _ = keepDraft(); scheduleSave()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateTools()
            if let action = self.pendingPencilAction {
                self.pendingPencilAction = nil
                self.performPencilAction(action.action,from:action.source)
            }
        }
        reader?.onReadingChanged?()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard ready else { return }
        updateUndoState()
        if reader?.inlineInkStatus != "正在保存笔迹…" { reader?.inlineInkStatus = "正在保存笔迹…" }
        scheduleSave()
    }
    func undo() { canvas.undoManager?.undo(); canvasViewDrawingDidChange(canvas); updateUndoState() }
    func redo() { canvas.undoManager?.redo(); canvasViewDrawingDidChange(canvas); updateUndoState() }
    private func scheduleSave() {
        draftWork?.cancel()
        draftWork = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(800)) } catch { return }
            guard let self else { return }
            if self.isDrawing { _ = self.keepDraft() } else { _ = self.persist() }
        }
    }
}

extension ReaderModel {
    @MainActor func selectInkTool(_ tool: ReaderInkTool) {
        guard !handwritingActive else { return }
        if tool == .reading, inlineInk?.suspend() == false { return }
        inlineInkTool = tool
        inlineInk?.updateTools()
        showReadingNotice(tool == .reading ? "Pencil 可滑动阅读，长按拖选文字" : tool.title)
    }
    @MainActor func beginPageHandwriting() {
        if isPDFTextLayout {
            setPDFTextLayout(false)
            guard !isPDFTextLayout else { return }
            inlineInkToolsVisible = true
            selectInkTool(.pen)
            return
        }
        inlineInkToolsVisible.toggle()
        inlineInk?.updateTools()
    }
    @MainActor func resumePageHandwriting(_ note: ReaderPageNote) {
        guard !busy, !loading, inlineInk?.suspend() != false else { return }
        if isPDFTextLayout { setPDFTextLayout(false) }
        inlineInkToolsVisible = true
        selectInkTool(.pen)
        showNoteGraph = false; selectionDiscussion = nil; pageNoteToView = nil
        go(note.inkParts.first?.sources.first?.id ?? note.anchor.locator)
        readingControlsVisible = false
    }
    func pageHandwritingDraft(for note: ReaderPageNote) -> ReaderPageHandwritingDraft? {
        guard let bookID=currentID else { return nil }
        let canvasID=note.parts?.first?.canvasID ?? note.id
        if let saved=inkNoteDrafts.first(where:{ $0.id==canvasID }) { return inkHandwritingDraft(for:saved) }
        let canvas=pageInkCanvases.first(where:{ $0.id==canvasID }) ?? note
        do { return try loadInkCanvas(canvas,bookID:bookID) }
        catch { self.error="原笔迹无法读取，已保留批注：\(error.localizedDescription)";return nil }
    }
    func inkHandwritingDraft(for saved: ReaderInkNoteDraft) -> ReaderPageHandwritingDraft? {
        guard currentID == saved.bookID else { return nil }
        do {
            guard let page = UIImage(data:saved.page) else { throw ReaderError.message("草稿原页无法读取") }
            return ReaderPageHandwritingDraft(bookID:saved.bookID,note:saved.note,page:page,drawing:try PKDrawing(data:saved.drawing),recovered:true)
        } catch { self.error = "手写草稿暂时无法读取，原文件已保留：\(error.localizedDescription)"; return nil }
    }
}

@MainActor
final class PagePencilCanvasController: NSObject, ObservableObject, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    let picker = PKToolPicker()
    let size: CGSize
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasInk = false
    @Published var drawingRevision = 0
    init(drawing: PKDrawing, size: CGSize, color: UIColor) {
        self.size = size
        super.init()
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.isScrollEnabled = false; canvas.bounces = false
        canvas.contentSize = size; canvas.drawing = drawing
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        canvas.tool = PKInkingTool(.pen,color:color,width:3)
        picker.selectedTool = canvas.tool
        canvas.delegate = self
        canvas.accessibilityLabel = "书页手写画布"
        hasInk = !drawing.strokes.isEmpty
    }
    func attach() {
        picker.addObserver(canvas)
        picker.setVisible(true,forFirstResponder:canvas)
        canvas.becomeFirstResponder()
    }
    func detach() {
        picker.setVisible(false,forFirstResponder:canvas)
        picker.removeObserver(canvas); canvas.resignFirstResponder()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private func refresh() {
        canUndo = canvas.undoManager?.canUndo == true; canRedo = canvas.undoManager?.canRedo == true
        hasInk = !canvas.drawing.strokes.isEmpty
        drawingRevision += 1
    }
    func undo() { canvas.undoManager?.undo(); refresh() }
    func redo() { canvas.undoManager?.redo(); refresh() }
    func files(page: UIImage) throws -> ReaderPageNoteFiles {
        let rect = CGRect(origin:.zero,size:size)
        let scale = min(2,2048/max(size.width,size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let ink = canvas.drawing.image(from:rect,scale:scale)
        let renderer = UIGraphicsImageRenderer(size:size,format:format)
        let background = renderer.image { _ in page.draw(in:rect) }
        let preview = renderer.image { _ in page.draw(in:rect); ink.draw(in:rect) }
        guard let pageData = background.pngData(), let inkData = ink.pngData(), let previewData = preview.pngData() else {
            throw ReaderError.message("笔迹图像未能生成")
        }
        return ReaderPageNoteFiles(drawing:canvas.drawing.dataRepresentation(),page:pageData,ink:inkData,preview:previewData)
    }
}



// The live Pencil canvas is reconstructed from its active parts. Removing a
// graph node therefore removes just its ink; restoring it restores the same
// editable strokes from immutable assets, including after another save.
extension ReaderModel {
    var pageInkCanvases: [ReaderPageNote] {
        let parts=currentPageNotes.flatMap(\.inkParts)
        return Dictionary(grouping:parts,by:\.canvasID).map { canvas,parts in
            let first=parts[0]
            var anchor=first.anchor
            anchor.referenceX=parts.map { $0.anchor.referenceX }.max() ?? anchor.referenceX
            anchor.referenceY=parts.map { $0.anchor.referenceY }.max() ?? anchor.referenceY
            anchor.viewportWidth=parts.map { $0.anchor.viewportWidth+anchor.referenceX-$0.anchor.referenceX }.max() ?? anchor.viewportWidth
            anchor.viewportHeight=parts.map { $0.anchor.viewportHeight+anchor.referenceY-$0.anchor.referenceY }.max() ?? anchor.viewportHeight
            var spans: [String:ReaderInkTextSpan]=[:]
            for part in parts { for original in part.sources {
                var span=original
                span.boxes=span.boxes.map { .init($0.rect.offsetBy(dx:anchor.referenceX-part.anchor.referenceX,dy:anchor.referenceY-part.anchor.referenceY)) }
                spans[span.id]=span
            } }
            anchor.textSpans=spans.values.sorted { $0.block==$1.block ? $0.offset<$1.offset : ($0.boxes.first?.y ?? 0)<($1.boxes.first?.y ?? 0) }
            var note=ReaderPageNote(id:canvas,assetID:first.assetID,anchor:anchor)
            note.parts=parts;note.updatedAt=currentPageNotes.filter { $0.inkParts.contains { $0.canvasID==canvas } }.map(\.updatedAt).max() ?? note.updatedAt
            return note
        }.sorted { $0.anchor.progress<$1.anchor.progress }
    }
    private func inkStrokeKeys(_ drawing: PKDrawing) -> [String] {
        var counts: [String:Int]=[:]
        return drawing.strokes.map { stroke in
            var data=Data()
            func append(_ value: Double) { var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) } }
            append(stroke.path.creationDate.timeIntervalSince1970)
            for point in stroke.path { append(point.location.x);append(point.location.y);append(point.timeOffset) }
            let base=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            let ordinal=counts[base,default:0];counts[base]=ordinal+1
            return base+"/"+String(ordinal)
        }
    }
    func saveGroupedPageInk(_ canvas: ReaderPageNote,files: ReaderPageNoteFiles,bookID: UUID) -> Bool {
        guard bookID==currentID else { return false }
        do {
            let drawing=try PKDrawing(data:files.drawing)
            guard let page=UIImage(data:files.page), drawing.strokes.count<=20000 else { throw ReaderError.message("书页笔迹无效，草稿仍保留") }
            let keys=inkStrokeKeys(drawing), active=currentPageNotes
            let liveParts=Set(active.flatMap(\.inkParts).map(\.id)), keySet=Set(keys)
            let recovered=(currentBook?.graph.nodes ?? []).compactMap { node -> ReaderPageNote? in
                guard node.deletedAt != nil, case .ink(var note)=node.content else { return nil }
                let parts=note.inkParts.filter { !liveParts.contains($0.id) }
                guard parts.contains(where:{ $0.canvasID==canvas.id && !keySet.isDisjoint(with:$0.strokeIDs) }) else { return nil }
                note.parts=parts
                note.entityIDs=currentBook?.graph.edges.filter { $0.deletedAt==nil && $0.id.source==node.id && $0.id.kind == .mentions }.compactMap { UUID(uuidString:$0.id.target.owner) }
                return note
            }
            let previous=active+recovered
            let descriptors=zip(keys,drawing.strokes).map { ReaderInkGrouping.Stroke(id:$0.0,bounds:$0.1.renderBounds) }
            let plan=ReaderInkGrouping.plan(descriptors,canvasID:canvas.id,anchor:canvas.anchor,previous:previous)
            let indices=Dictionary(uniqueKeysWithValues:keys.enumerated().map { ($0.element,$0.offset) })
            let oldParts=Dictionary(previous.flatMap(\.inkParts).map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
            var replacement: [UUID:[ReaderInkPart]]=[:]
            var partAnchor=canvas.anchor;partAnchor.textSpans=nil
            for units in plan {
                let owner=units.compactMap(\.owner).first ?? units[0].id
                for unit in units {
                    let selected=PKDrawing(strokes:unit.strokes.compactMap { indices[$0].map { drawing.strokes[$0] } })
                    let old=oldParts[unit.id]
                    let asset: UUID
                    if let old, old.anchor==partAnchor, let loaded=try? pageNoteStore.load(old.assetID), loaded.drawing==selected.dataRepresentation() { asset=old.assetID }
                    else {
                        let export=PagePencilCanvasController(drawing:selected,size:CGSize(width:partAnchor.viewportWidth,height:partAnchor.viewportHeight),color:.black)
                        asset=try pageNoteStore.save(export.files(page:page))
                    }
                    let annotated=unit.sources.flatMap(\.boxes).reduce(unit.bounds) { $0.union($1.rect) }
                    let bounds=annotated.insetBy(dx:-10,dy:-10).intersection(CGRect(x:0,y:0,width:partAnchor.viewportWidth,height:partAnchor.viewportHeight))
                    var part=ReaderInkPart(id:unit.id,canvasID:canvas.id,assetID:asset,anchor:partAnchor,bounds:.init(bounds),strokeIDs:unit.strokes,sources:unit.sources,title:old?.title)
                    part.text=old?.text;part.entityIDs=old?.entityIDs
                    replacement[owner,default:[]].append(part)
                }
            }
            var notes: [ReaderPageNote]=[], removed: [ReaderPageNote]=[]
            let oldIDs=Set(previous.map(\.id))
            for original in previous {
                let retained=original.inkParts.filter { $0.canvasID != canvas.id }
                let parts=retained+(replacement[original.id] ?? [])
                if parts.isEmpty { removed.append(original);continue }
                var note=original;note.parts=parts;note.anchor=parts[0].anchor;note.assetID=parts[0].assetID
                if note != original || original.inkParts.contains(where:{ $0.canvasID==canvas.id }) { note.updatedAt=Date() }
                notes.append(note)
            }
            for (owner,parts) in replacement where !oldIDs.contains(owner) {
                var note=ReaderPageNote(id:owner,assetID:parts[0].assetID,anchor:parts[0].anchor)
                note.parts=parts;notes.append(note)
            }
            guard commitReadingGraph(bookID:bookID,{ graph in
                graph.replacePageNotes(notes)
                let live=Set(notes.map(\.id));graph.removals.removeAll { $0.pageNote.map { live.contains($0.id) } ?? false }
                for note in removed where !graph.removals.contains(where:{ $0.pageNote?.id==note.id }) { graph.removals.append(.init(pageNote:note)) }
            }) else { return false }
            try? discardNoteDraft(bookID:bookID,id:canvas.id,ink:true)
            return true
        } catch { self.error="书页笔迹未能保存：\(error.localizedDescription)";return false }
    }
    private func loadInkCanvas(_ note: ReaderPageNote,bookID: UUID) throws -> ReaderPageHandwritingDraft {
        let parts=note.inkParts
        let size=CGSize(width:note.anchor.viewportWidth,height:note.anchor.viewportHeight)
        guard size.width>0,size.height>0,size.width<=12000,size.height<=12000 else { throw ReaderError.message("书页尺寸无效") }
        var strokes: [PKStroke]=[], pages: [(UIImage,CGRect)]=[]
        var assets=Set<UUID>()
        for part in parts where assets.insert(part.assetID).inserted {
            let files=try pageNoteStore.load(part.assetID), drawing=try PKDrawing(data:files.drawing)
            guard let page=UIImage(data:files.page) else { throw ReaderError.message("原页图像无法读取") }
            let shift=CGAffineTransform(translationX:note.anchor.referenceX-part.anchor.referenceX,y:note.anchor.referenceY-part.anchor.referenceY)
            strokes += drawing.transformed(using:shift).strokes
            pages.append((page,CGRect(x:shift.tx,y:shift.ty,width:part.anchor.viewportWidth,height:part.anchor.viewportHeight)))
        }
        let format=UIGraphicsImageRendererFormat();format.scale=min(1,2048/max(size.width,size.height))
        let page=UIGraphicsImageRenderer(size:size,format:format).image { _ in for (image,rect) in pages { image.draw(in:rect) } }
        return .init(bookID:bookID,note:note,page:page,drawing:PKDrawing(strokes:strokes))
    }
}
