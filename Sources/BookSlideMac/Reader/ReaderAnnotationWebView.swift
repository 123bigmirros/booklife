#if os(macOS)
import AppKit
import WebKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Extend WebKit's native context menu with book annotations and AI actions.
final class ReaderAnnotationWebView: WKWebView {
    var annotationContext: [String:Any]?
    var onAnnotationAction: ((String,[String:Any]) -> Void)?

    private final class Context {
        var value: [String:Any]?
        init(_ value: [String:Any]?) { self.value = value }
    }
    private var menuActions: [MenuAction] = []

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu,with:event)
        guard !menu.items.contains(where: { $0.identifier?.rawValue == "BookSlideAnnotationPalette" }) else { return }
        // WebKit supplies Copy only for a text selection. A cached highlighted
        // range also allows editing an existing annotation without reselecting.
        let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" || $0.action == #selector(NSText.copy(_:)) }
        guard annotationContext != nil || hasSelection else { return }
        let context = Context(annotationContext)
        addAnnotationItems(to:menu,context:context)
        // Refresh on every opening, including a right click immediately after
        // dragging. Actions keep this snapshot even if selection later clears.
        callAsyncJavaScript("return reader.annotationContext()",arguments:[:],in:nil,in:.page) { result in
            if case .success(let value) = result, let value = value as? [String:Any] { context.value = value }
        }
    }

    func presentAnnotationMenu(context: [String:Any], x: Double, y: Double) {
        let menu = NSMenu()
        addAnnotationItems(to:menu,context:Context(context))
        menu.addItem(.separator())
        addAction(to:menu,title:"拷贝",symbol:"doc.on.doc") {
            guard let quote = context["quote"] as? String else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(quote,forType:.string)
        }
        let point = NSPoint(x:x,y:isFlipped ? y : bounds.height-y)
        menu.popUp(positioning:nil,at:point,in:self)
    }

    private func addAnnotationItems(to menu: NSMenu, context: Context) {
        menuActions = []
        let paletteItem = NSMenuItem(title:"高亮颜色",action:nil,keyEquivalent:"")
        paletteItem.identifier = .init("BookSlideAnnotationPalette")
        let palette = AnnotationMenuPalette(selected:context.value?["existing"] as? Bool == true ? context.value?["color"] as? String : nil)
        palette.choose = { [weak self,weak menu] color in
            menu?.cancelTracking()
            self?.performAnnotation("annotationChange",context:context,color:color)
        }
        paletteItem.view = palette
        menu.insertItem(paletteItem,at:0)
        menu.insertItem(.separator(),at:1)
        let note = context.value?["note"] as? String ?? ""
        addAction(to:menu,title:note.isEmpty ? "写笔记" : "编辑笔记",symbol:"note.text",at:2) { [weak self] in
            self?.performAnnotation("annotationEdit",context:context)
        }
        addAction(to:menu,title:"问 AI",symbol:"bubble.left.and.bubble.right",at:3) { [weak self] in
            self?.performAnnotation("annotationDiscuss",context:context)
        }
        // Replace WebKit's translation command with the book-aware AI action.
        if let translate = menu.items.first(where:{
            $0.identifier?.rawValue == "WKMenuItemIdentifierTranslate" || ["翻译","翻譯","Translate"].contains($0.title)
        }) {
            menu.removeItem(translate)
        }
        addAction(to:menu,title:"翻译",symbol:"translate",at:4) { [weak self] in
            self?.performAnnotation("annotationTranslate",context:context)
        }
        var separatorIndex = 5
        if context.value?["existing"] as? Bool == true {
            addAction(to:menu,title:"移除标记",symbol:"trash",at:5) { [weak self] in
                self?.performAnnotation("annotationRemove",context:context)
            }
            separatorIndex += 1
        }
        if menu.items.count > separatorIndex { menu.insertItem(.separator(),at:separatorIndex) }
    }

    private func performAnnotation(_ type: String, context: Context, color: AnnotationColor? = nil) {
        guard var value = context.value else { return }
        if let color { value["color"] = color.rawValue }
        evaluateJavaScript("reader.dismissAnnotations()",completionHandler:nil)
        // Present note sheets after the system has finished closing its menu.
        DispatchQueue.main.async { [weak self] in self?.onAnnotationAction?(type,value) }
    }

    private func addAction(to menu: NSMenu, title: String, symbol: String, at index: Int? = nil, action: @escaping () -> Void) {
        let target = MenuAction(action)
        menuActions.append(target)
        let item = NSMenuItem(title:title,action:#selector(MenuAction.invoke(_:)),keyEquivalent:"")
        item.target = target
        item.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
        if let index { menu.insertItem(item,at:index) } else { menu.addItem(item) }
    }
    private final class MenuAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: Any?) { action() }
    }
}

private final class AnnotationMenuPalette: NSView {
    var choose: ((AnnotationColor) -> Void)?
    init(selected: String?) {
        super.init(frame:NSRect(x:0,y:0,width:240,height:34))
        for (index,color) in AnnotationColor.allCases.enumerated() {
            let button = NSButton(frame:NSRect(x:8+index*38,y:2,width:34,height:30))
            button.title = ""; button.isBordered = false; button.imagePosition = .imageOnly
            button.image = Self.image(color,selected:selected == color.rawValue)
            button.target = self; button.action = #selector(picked(_:)); button.tag = index
            button.toolTip = color.title; button.setAccessibilityLabel(color.title)
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func picked(_ sender: NSButton) { choose?(AnnotationColor.allCases[sender.tag]) }
    private static func image(_ color: AnnotationColor, selected: Bool) -> NSImage {
        NSImage(size:NSSize(width:24,height:24),flipped:false) { _ in
            if color == .underline {
                let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor,.underlineStyle:NSUnderlineStyle.single.rawValue]
                NSAttributedString(string:"U",attributes:attributes).draw(at:NSPoint(x:7,y:4))
            } else {
                let rgb: (Double,Double,Double)
                switch color {
                case .yellow: rgb = (0.97,0.82,0.18)
                case .green: rgb = (0.56,0.84,0.49)
                case .blue: rgb = (0.53,0.70,0.98)
                case .pink: rgb = (0.98,0.57,0.72)
                case .purple: rgb = (0.76,0.63,0.97)
                case .underline: rgb = (0,0,0)
                }
                NSColor(red:rgb.0,green:rgb.1,blue:rgb.2,alpha:1).setFill()
                NSBezierPath(ovalIn:NSRect(x:5,y:5,width:14,height:14)).fill()
            }
            if selected {
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                let ring = NSBezierPath(ovalIn:NSRect(x:1.5,y:1.5,width:21,height:21)); ring.lineWidth = 1; ring.stroke()
            }
            return true
        }
    }
}
#endif
