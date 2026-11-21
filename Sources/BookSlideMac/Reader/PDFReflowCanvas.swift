import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// An alternate presentation of the same PDF page and text offsets. Text
/// settings and selection actions are shared with the main reading workspace.
struct PDFReflowCanvas: View {
    @ObservedObject var reader: ReaderModel
    let pdf: PDFBookReader

    var body: some View {
        VStack(spacing:0) {
            if pdf.currentPageText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                VStack(spacing:16) {
                    Text("此页是图像")
                    Button("识别扫描文字",systemImage:"text.viewfinder") { reader.recognizePDFText() }
                        .disabled(reader.pdfTextRecognitionRunning)
                    if reader.pdfTextRecognitionRunning { ProgressView() }
                    Button("查看原页") { reader.setPDFTextLayout(false) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                reflowText.id(reader.position?.page)
            }
            #if os(iOS)
            HStack {
                Button("上一页",systemImage:"chevron.left") {
                    Task { await reader.turnLocally(.previous) }
                }.disabled(reader.position?.canGoPrevious != true || reader.busy)
                Spacer()
                Button(reader.positionLabel) { reader.readingControlsVisible.toggle() }
                    .accessibilityLabel("显示阅读工具")
                Spacer()
                Button("下一页",systemImage:"chevron.right") {
                    Task { await reader.turnLocally(.next) }
                }.disabled(reader.position?.canGoNext != true || reader.busy)
            }.padding(.horizontal,18).frame(minHeight:44)
            #endif
        }
        .background(reader.appearance.background)
    }

    private var reflowText: PDFReflowText {
        let text = formattedPage(), inset = CGFloat(max(8,reader.appearance.margin))
        let generation = reader.nativeSelectionGeneration, target = reader.pdfTextTarget
        #if os(iOS)
        return PDFReflowText(text:text,inset:inset,generation:generation,target:target,selectionChanged:publishSelection,selectionMenu:selectionMenu)
        #else
        return PDFReflowText(text:text,inset:inset,generation:generation,target:target,selectionChanged:publishSelection)
        #endif
    }

    private func publishSelection(_ range: NSRange) {
        guard reader.isPDFTextLayout else { return }
        reader.nativeSelection = pdf.annotation(at:range)
        #if os(iOS)
        reader.inlineInkSelectionActive = reader.nativeSelection != nil
        #endif
    }

    #if os(iOS)
    private func selectionMenu(_ range: NSRange) -> [UIMenuElement] {
        guard reader.isPDFTextLayout, let selection = pdf.annotation(at:range) else { return [] }
        return reader.nativeSelectionMenu(for:selection)
    }
    #endif

    private func formattedPage() -> NSAttributedString {
        let appearance = reader.appearance
        let size = CGFloat(appearance.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(appearance.lineHeight)
        let name = ["pingfang":"PingFangSC-Regular","serif":"SongtiSC-Regular"][appearance.font]
        #if os(macOS)
        let font = name.flatMap { NSFont(name:$0,size:size) } ?? .systemFont(ofSize:size)
        let ink = NSColor(appearance.ink)
        #else
        let font = name.flatMap { UIFont(name:$0,size:size) } ?? .systemFont(ofSize:size)
        let ink = UIColor(appearance.ink)
        #endif
        // Preserve UTF-16 offsets while allowing the text system to wrap the
        // imported lines to the viewport. Blank lines still split paragraphs.
        let text = pdf.currentPageText.replacingOccurrences(of:#"(?<![\r\n])\n(?![\r\n])"#,
                                                            with:" ",options:.regularExpression)
        let result = NSMutableAttributedString(string:text,attributes:[
            .font:font,.foregroundColor:ink,.paragraphStyle:paragraph
        ])
        let index = (reader.position?.page ?? 1) - 1
        for item in reader.currentAnnotations where item.responseToID == nil {
            guard let locator = item.selectionLocator, let ranges = PDFTextLocator.decode(locator) else { continue }
            for span in ranges where span.page == index && NSMaxRange(span.range) <= result.length {
                if item.color == .underline {
                    result.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:span.range)
                } else {
                    #if os(macOS)
                    let color = NSColor(item.color.swatch).withAlphaComponent(0.5)
                    #else
                    let color = UIColor(item.color.swatch).withAlphaComponent(0.5)
                    #endif
                    result.addAttribute(.backgroundColor,value:color,range:span.range)
                }
            }
        }
        return result
    }
}

struct PDFLayoutControls: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        if reader.pdfBookReader != nil {
            VStack(spacing:10) {
                Picker("PDF 版式",selection:Binding(get:{ reader.isPDFTextLayout },set:{ reader.setPDFTextLayout($0) })) {
                    Text("原版页面").tag(false)
                    Text("文字重排").tag(true)
                }.pickerStyle(.segmented)
                if reader.pdfTextRecognitionRunning {
                    ProgressView("正在识别扫描文字…")
                } else {
                    Button("识别扫描文字",systemImage:"text.viewfinder") { reader.recognizePDFText() }
                }
            }
        }
    }
}

#if os(macOS)
private struct PDFReflowText: NSViewRepresentable {
    let text: NSAttributedString
    let inset: CGFloat
    let generation: UUID
    let target: NSRange?
    let selectionChanged: (NSRange) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PDFReflowText
        var generation: UUID?
        var updating = false
        init(_ parent: PDFReflowText) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selectionChanged(view.selectedRange())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width:30,height:30)
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("pdf-reflow-text")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        view.textContainerInset = NSSize(width:inset,height:24)
        if view.textStorage?.isEqual(to:text) != true { view.textStorage?.setAttributedString(text) }
        if coordinator.generation != generation {
            coordinator.generation = generation
            view.setSelectedRange(NSRange(location:0,length:0))
            if let target, NSMaxRange(target) <= text.length { view.scrollRangeToVisible(target) }
        }
    }
}
#else
private struct PDFReflowText: UIViewRepresentable {
    let text: NSAttributedString
    let inset: CGFloat
    let generation: UUID
    let target: NSRange?
    let selectionChanged: (NSRange) -> Void
    let selectionMenu: (NSRange) -> [UIMenuElement]

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PDFReflowText
        var generation: UUID?
        var updating = false
        init(_ parent: PDFReflowText) { self.parent = parent }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            parent.selectionChanged(view.selectedRange)
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let bookActions = parent.selectionMenu(range)
            guard !bookActions.isEmpty else { return nil }
            let group = UIMenu(title:"",options:.displayInline,children:bookActions)
            return UIMenu(children:[group] + ReaderSelectionMenu.systemActions(suggestedActions))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.textContainerInset = UIEdgeInsets(top:30,left:22,bottom:22,right:22)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "pdf-reflow-text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        view.textContainerInset = UIEdgeInsets(top:24,left:inset,bottom:24,right:inset)
        if !view.attributedText.isEqual(to:text) { view.attributedText = text }
        if coordinator.generation != generation {
            coordinator.generation = generation
            view.selectedRange = NSRange(location:0,length:0)
            if let target, NSMaxRange(target) <= text.length { view.scrollRangeToVisible(target) }
        }
    }
}
#endif
