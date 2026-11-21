import UIKit
import WebKit

@MainActor
enum ReaderSelectionMenu {
    static func actions(existingColor: AnnotationColor?, hasNote: Bool, includeEntity: Bool = false,
                        perform: @escaping (String,AnnotationColor?) -> Void) -> [UIMenuElement] {
        let discuss = UIAction(title:"问 AI",image:UIImage(systemName:"bubble.left.and.bubble.right")) { _ in
            perform("annotationDiscuss",nil)
        }
        let translate = UIAction(title:"翻译",image:UIImage(systemName:"translate")) { _ in
            perform("annotationTranslate",nil)
        }
        let colors = AnnotationColor.allCases.map { color in
            UIAction(title:color.title,image:swatch(color),state:existingColor == color ? .on : .off) { _ in
                perform("annotationChange",color)
            }
        }
        let palette = UIMenu(title:"高亮",image:UIImage(systemName:"highlighter"),options:.displayAsPalette,children:colors)
        let note = UIAction(title:hasNote ? "编辑笔记" : "写笔记",image:UIImage(systemName:"note.text")) { _ in
            perform("annotationEdit",nil)
        }
        var editing: [UIMenuElement] = [palette,note]
        if includeEntity {
            editing.append(UIAction(title:"添加节点",image:UIImage(systemName:"plus.circle")) { _ in
                perform("annotationEntity",nil)
            })
        }
        if existingColor != nil {
            editing.append(UIAction(title:"移除标记",image:UIImage(systemName:"trash"),attributes:.destructive) { _ in
                perform("annotationRemove",nil)
            })
        }
        if includeEntity && UIDevice.current.userInterfaceIdiom != .pad {
            return [discuss,translate,UIMenu(title:"标记与笔记",image:UIImage(systemName:"highlighter"),children:editing)]
        }
        return [discuss,translate] + editing
    }

    static func systemActions(_ actions: [UIMenuElement]) -> [UIMenuElement] {
        actions.compactMap { element in
            let identifier = (element as? UIAction)?.identifier.rawValue ?? (element as? UIMenu)?.identifier.rawValue ?? ""
            let selector = (element as? UICommand).map { NSStringFromSelector($0.action) } ?? ""
            if identifier.localizedCaseInsensitiveContains("translate") || selector.localizedCaseInsensitiveContains("translate")
                || ["Translate","翻译","翻譯"].contains(element.title) { return nil }
            guard let menu = element as? UIMenu else { return element }
            let children = systemActions(menu.children)
            return children.isEmpty && !menu.children.isEmpty ? nil : menu.replacingChildren(children)
        }
    }

    static func install(_ actions: UIMenuElement, in builder: UIMenuBuilder) {
        let identifier = UIMenu.Identifier("BookSlideAnnotations")
        guard builder.menu(for:identifier) == nil else { return }
        builder.replaceChildren(ofMenu:.root,from:systemActions)
        let menu = UIMenu(title:"",identifier:identifier,options:.displayInline,children:[actions])
        if builder.menu(for:.standardEdit) != nil { builder.insertSibling(menu,afterMenu:.standardEdit) }
        else { builder.insertChild(menu,atStartOfMenu:.root) }
    }

    private static func swatch(_ color: AnnotationColor) -> UIImage? {
        if color == .underline { return UIImage(systemName:"underline") }
        return UIGraphicsImageRenderer(size:CGSize(width:24,height:24)).image { _ in
            UIColor(color.swatch).setFill()
            UIBezierPath(ovalIn:CGRect(x:3,y:3,width:18,height:18)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Add book actions to WebKit's edit menu instead of presenting an HTML panel
/// underneath it. Resolve the current range when UIKit builds each menu: the
/// selection message may arrive after the user has already released a handle.
@MainActor
final class ReaderTextWebView: WKWebView, @preconcurrency UIEditMenuInteractionDelegate {
    private(set) var pencilReadingEnabled = false
    func setPencilReadingEnabled(_ enabled: Bool) {
        guard pencilReadingEnabled != enabled else { return }
        pencilReadingEnabled = enabled
        var types = [NSNumber(value:UITouch.TouchType.direct.rawValue),NSNumber(value:UITouch.TouchType.indirectPointer.rawValue)]
        if enabled { types.append(NSNumber(value:UITouch.TouchType.pencil.rawValue)) }
        scrollView.panGestureRecognizer.allowedTouchTypes = types
    }
    var onAnnotationAction: ((String,[String:Any]) -> Void)?
    var onAnnotationMenuVisibilityChange: ((Bool) -> Void)?
    private var tappedAnnotation: [String:Any]?
    private var annotationMenuID: UUID?
    private lazy var annotationMenu = UIEditMenuInteraction(delegate:self)
    private var menuAttached = false

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with:builder)
        guard builder.system == .context else { return }
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            self.callAsyncJavaScript("return reader.annotationContext()",arguments:[:],in:nil,in:.page) { [weak self] result in
                guard let self, case .success(let value) = result, let context = value as? [String:Any] else { completion([]); return }
                completion(self.annotationMenuElements(context:context))
            }
        }
        ReaderSelectionMenu.install(deferred,in:builder)
    }

    func annotationMenuElements(context: [String:Any]) -> [UIMenuElement] {
        guard context["cfi"] as? String != nil, context["session"] as? String != nil else { return [] }
        let color = (context["color"] as? String).flatMap(AnnotationColor.init(rawValue:))
        return ReaderSelectionMenu.actions(existingColor:context["existing"] as? Bool == true ? color : nil,
                                           hasNote:!(context["note"] as? String ?? "").isEmpty) { [weak self] action, color in
            var value = context
            if let color { value["color"] = color.rawValue }
            self?.performAnnotation(action,context:value)
        }
    }

    func performAnnotation(_ type: String,context: [String:Any]) {
        annotationMenu.dismissMenu()
        clearAnnotationSelection(context)
        // Keep the selected CFI snapshot while UIKit closes the menu.
        DispatchQueue.main.async { [weak self] in self?.onAnnotationAction?(type,context) }
    }

    func presentAnnotationMenu(context: [String:Any],x: Double,y: Double) {
        if !menuAttached { addInteraction(annotationMenu); menuAttached = true }
        tappedAnnotation = context
        let menuID = UUID(); annotationMenuID = menuID
        onAnnotationMenuVisibilityChange?(true)
        annotationMenu.presentEditMenu(with:UIEditMenuConfiguration(identifier:menuID.uuidString as NSString,sourcePoint:CGPoint(x:x,y:y)))
    }
    func dismissAnnotationMenu() {
        guard let context = tappedAnnotation else { return }
        tappedAnnotation = nil; annotationMenuID = nil
        onAnnotationMenuVisibilityChange?(false)
        annotationMenu.dismissMenu()
        clearAnnotationSelection(context)
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,menuFor configuration: UIEditMenuConfiguration,suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let context = tappedAnnotation else { return nil }
        let copy = UIAction(title:"拷贝",image:UIImage(systemName:"doc.on.doc")) { _ in
            UIPasteboard.general.string = context["quote"] as? String
        }
        return UIMenu(children:annotationMenuElements(context:context) + [copy])
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,willDismissMenuFor configuration: UIEditMenuConfiguration,animator: UIEditMenuInteractionAnimating) {
        guard let context = tappedAnnotation, let menuID = annotationMenuID,
              configuration.identifier as? String == menuID.uuidString else { return }
        tappedAnnotation = nil; annotationMenuID = nil
        onAnnotationMenuVisibilityChange?(false)
        clearAnnotationSelection(context)
    }
    private func clearAnnotationSelection(_ context: [String:Any]) {
        guard let id = context["id"] as? String, let cfi = context["cfi"] as? String,
              let session = context["session"] as? String else { return }
        callAsyncJavaScript("return reader.dismissAnnotationSelection(id,cfi,session)",arguments:["id":id,"cfi":cfi,"session":session],in:nil,in:.page,completionHandler:nil)
    }
}

/// Receive input outside the EPUB's script-disabled frame. Keep WebKit's own
/// selection recognizers active; a transparent SwiftUI overlay would block them.
enum ReaderPageGesture {
    static func tap(at point: CGPoint,width: CGFloat,scrolling: Bool,isPad: Bool) -> PageDirection? {
        guard !scrolling, !isPad else { return nil }
        let edge = min(72,width*0.18)
        return point.x < edge ? .previous : point.x > width-edge ? .next : nil
    }
    static func swipe(translation: CGPoint,width: CGFloat,elapsed: TimeInterval,scrolling: Bool,isPad: Bool) -> PageDirection? {
        guard !scrolling, elapsed < 0.8 else { return nil }
        if isPad {
            // Selection drags, vertical gestures and resting a hand near the
            // page edge must not be interpreted as a page-turn command.
            guard abs(translation.x) >= max(64,width*0.08), abs(translation.x) > abs(translation.y)*1.4 else { return nil }
            return translation.x < 0 ? .next : .previous
        }
        let delta = abs(translation.x) > abs(translation.y) ? translation.x : translation.y
        guard abs(delta) > 45 else { return nil }
        return delta < 0 ? .next : .previous
    }
}

@MainActor
final class ReaderTouchInput: NSObject, UIGestureRecognizerDelegate {
    private let reader: ReaderModel
    private weak var view: WKWebView?
    private var recognizers: [UIGestureRecognizer] = []
    private var start = CGPoint.zero
    private var startedAt = 0.0
    private var selectionTask: Task<Void,Never>?
    private var selectionGeneration = UUID()
    private struct PencilSelectionSample {
        let point: CGPoint
        let phase: String
        let session: UUID
    }
    private var pendingSelection: [PencilSelectionSample] = []
    init(reader: ReaderModel) { self.reader = reader }

    func attach(to view: WKWebView) {
        detach(); self.view = view
        let tap = UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target:self,action:#selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail:doubleTap)
        let pan = UIPanGestureRecognizer(target:self,action:#selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let select = UILongPressGestureRecognizer(target:self,action:#selector(pencilSelected(_:)))
        select.minimumPressDuration = 0.22; select.allowableMovement = 18
        select.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.pencil.rawValue)]
        tap.require(toFail:select); pan.require(toFail:select)
        view.scrollView.panGestureRecognizer.require(toFail:select)
        recognizers = [tap,doubleTap,pan,select]
        for gesture in recognizers {
            if gesture !== select { gesture.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue),NSNumber(value:UITouch.TouchType.indirectPointer.rawValue),NSNumber(value:UITouch.TouchType.pencil.rawValue)] }
            gesture.delegate = self
            gesture.cancelsTouchesInView = gesture === select
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            view.addGestureRecognizer(gesture)
        }
    }
    func detach() {
        selectionTask?.cancel(); selectionTask = nil
        selectionGeneration = UUID()
        pendingSelection.removeAll()
        for gesture in recognizers { view?.removeGestureRecognizer(gesture) }
        recognizers.removeAll(); view = nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !reader.loading, !reader.handwritingActive,
              touch.type != .pencil || reader.inlineInkTool == .reading, !UIAccessibility.isVoiceOverRunning else { return false }
        // UITouch is available here, unlike during the initial hit test. Flush
        // ink before a finger can move the live text underneath the canvas.
        guard reader.inlineInk?.suspend() != false else { return false }
        if gestureRecognizer is UIPanGestureRecognizer {
            start = touch.location(in:view); startedAt = touch.timestamp
        }
        return true
    }
    @objc private func pencilSelected(_ gesture: UILongPressGestureRecognizer) {
        guard reader.inlineInkTool == .reading, let view else { return }
        let phase: String
        switch gesture.state { case .began: phase = "begin"; case .changed: phase = "extend"; case .ended: phase = "end"; case .cancelled: phase = "cancel"; default: return }
        enqueuePencilSelection(at:gesture.location(in:view),phase:phase)
    }
    func enqueuePencilSelection(at point: CGPoint, phase: String) {
        guard reader.inlineInkTool == .reading else { return }
        let sample = PencilSelectionSample(point:point,phase:phase,session:reader.sessionID)
        // Keep the latest location, rather than replaying a growing trail of
        // old points after the Pencil has already moved or lifted.
        if phase == "extend", let last = pendingSelection.last, last.phase == "extend", last.session == sample.session {
            pendingSelection[pendingSelection.count-1] = sample
        } else { pendingSelection.append(sample) }
        guard selectionTask == nil else { return }
        let generation = selectionGeneration
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if selectionGeneration == generation { selectionTask = nil } }
            while !pendingSelection.isEmpty, !Task.isCancelled, selectionGeneration == generation {
                let next = pendingSelection.removeFirst()
                guard next.session == reader.sessionID, reader.inlineInkTool == .reading else { pendingSelection.removeAll(); return }
                _ = try? await reader.webView.callAsyncJavaScript("return reader.pencilSelect(x,y,phase)",arguments:["x":next.point.x,"y":next.point.y,"phase":next.phase],in:nil,contentWorld:.page)
            }
        }
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) { /* WebKit selects the word. */ }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let view else { return }
        let point = gesture.location(in:view)
        perform(point:point,direction:ReaderPageGesture.tap(at:point,width:view.bounds.width,scrolling:reader.isScrolling,isPad:UIDevice.current.userInterfaceIdiom == .pad),checkAnnotation:true)
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began, reader.isScrolling {
            // Script-disabled EPUB frames do not deliver their DOM touch events
            // to the host. Tell it about native scrolling before relocation can
            // mistake the new viewport for a late reflow and restore old text.
            view?.evaluateJavaScript("reader.beginReadingInput()",completionHandler:nil)
        }
        guard gesture.state == .ended else { return }
        let distance = gesture.translation(in:view)
        guard let direction = ReaderPageGesture.swipe(translation:distance,width:view?.bounds.width ?? 0,
            elapsed:ProcessInfo.processInfo.systemUptime-startedAt,scrolling:reader.isScrolling,isPad:UIDevice.current.userInterfaceIdiom == .pad) else { return }
        perform(point:start,direction:direction)
    }
    private func perform(point: CGPoint, direction: PageDirection?, checkAnnotation: Bool = false) {
        let session = reader.sessionID
        Task { @MainActor [weak self] in
            guard let self, !reader.loading, !reader.busy else { return }
            if checkAnnotation {
                let handled = try? await reader.webView.callAsyncJavaScript("return reader.annotationTap(x,y)",arguments:["x":point.x,"y":point.y],in:nil,contentWorld:.page)
                guard session == reader.sessionID else { return }
                if handled as? Bool == true { return }
            }
            // Query from the trusted host, without enabling scripts in the book.
            let allowed = try? await reader.webView.callAsyncJavaScript(
                "return reader.allowsReadingGesture(x,y)",
                arguments:["x":point.x,"y":point.y],in:nil,contentWorld:.page)
            guard allowed as? Bool == true, session == reader.sessionID else { return }
            if let direction { await reader.turnLocally(direction) }
            else { reader.readingControlsVisible.toggle() }
        }
    }
}
