import PDFKit
import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

#if os(macOS)
typealias NativeReadingView = NSView
#else
typealias NativeReadingView = UIView
#endif

/// The reader supplies the contents, search results and opaque locations.
@MainActor protocol NativeBookReader: AnyObject {
    var view: NativeReadingView { get }
    var chapters: [ChapterItem] { get }
    var onPositionChange: ((EnginePosition) -> Void)? { get set }
    func open(at locator: String) -> EnginePosition
    func go(to locator: String, userDriven: Bool) -> EnginePosition?
    func turn(_ direction: PageDirection) -> EnginePosition?
    func scroll(_ direction: PageDirection, lines: Double) -> EnginePosition?
    func seek(_ progress: Double) -> EnginePosition?
    func search(_ query: String) async throws -> [ChapterItem]
    func excerpt(at locator: String) -> String
    func precedingText(at locator: String) -> String
    func applyAppearance(_ appearance: ReaderAppearance) -> EnginePosition
    func setAnnotations(_ annotations: [ReaderAnnotation])
    func clearSelection()
}

@MainActor final class PDFBookReader: NSObject, NativeBookReader, @preconcurrency PDFViewDelegate {
    private let document: PDFDocument
    private let data: Data
    private let pdfView = PageRestoringPDFView()
    let pageLayers = PDFPageLayers()
    #if os(iOS)
    private var inkSpans: (PDFPage, [ReaderInkTextSpan])?
    var selectionMenu: ((ReaderAnnotation) -> [UIMenuElement])?
    private lazy var markMenu = UIEditMenuInteraction(delegate:self)
    private var tappedMark: (id:UUID, record:ReaderAnnotation)?
    #endif
    private var pageIndex = 0
    private var observers: [NSObjectProtocol] = []
    private var selectionRecords: [ReaderAnnotation] = []
    private var marks: [(page: PDFPage, mark: PDFAnnotation, record: ReaderAnnotation)] = []
    private var readingMode: ReadingMode = .paged
    private var suppressPageReports = false
    var onSelectionChange: ((ReaderAnnotation?) -> Void)?
    var onToggleControls: (() -> Void)?
    var view: NativeReadingView { pdfView }
    let chapters: [ChapterItem]
    private let sectionStarts: [Int]
    var onPositionChange: ((EnginePosition) -> Void)?

    init(data: Data) throws {
        self.data = data
        document = try BookImportFile.pdfDocument(data)
        let outline = Self.outline(of: document)
        sectionStarts = Array(Set(outline.map(\.index))).sorted()
        chapters = outline.isEmpty ? (0..<document.pageCount).map { index in
            let href = PDFPageLocator.encode(index)
            return ChapterItem(id: href, href: href, title: "第 \(index + 1) 页", depth: 0)
        } : outline.map(\.item)
        super.init()
        pdfView.delegate = self
        pdfView.pageOverlayViewProvider = pageLayers
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.document = document
        pdfView.accessibilityIdentifierForReading()
        observers = [
            NotificationCenter.default.addObserver(forName:.PDFViewPageChanged,object:pdfView,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisiblePageChanged() }
            },
            NotificationCenter.default.addObserver(forName:.PDFViewSelectionChanged,object:pdfView,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onSelectionChange?(self?.selectedAnnotation()) }
            }
        ]
        #if os(macOS)
        let tap = NSClickGestureRecognizer(target:self,action:#selector(tapped(_:)))
        #else
        pdfView.selectionMenu = { [weak self] in
            guard let self, let selection = self.selectedAnnotation() else { return [] }
            return self.selectionMenu?(selection) ?? []
        }
        pdfView.addInteraction(markMenu)
        let tap = UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        #endif
        pdfView.addGestureRecognizer(tap)
    }

    nonisolated static func metadata(_ data: Data) throws -> (title: String?, author: String?, cover: Data?) {
        let document = try BookImportFile.pdfDocument(data)
        let attributes = document.documentAttributes
        func text(_ key: PDFDocumentAttribute) -> String? {
            let value = (attributes?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let thumbnail = document.page(at: 0)?.thumbnail(of: CGSize(width: 220, height: 320), for: .cropBox)
        #if os(macOS)
        let cover = thumbnail?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        #else
        let cover = thumbnail?.jpegData(compressionQuality: 0.75)
        #endif
        return (text(.titleAttribute), text(.authorAttribute), cover)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // Keep external links under explicit app control. Internal PDF destinations
    // are handled by PDFKit and reported as ordinary page changes.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    func open(at locator: String) -> EnginePosition {
        let index = PDFPageLocator.index(locator, pageCount: document.pageCount) ?? 0
        return move(to: index, userDriven: false) ?? position(userDriven: false)
    }

    func go(to locator: String, userDriven: Bool) -> EnginePosition? {
        if let selection = textSelection(at:locator), let page = selection.pages.first {
            let index = document.index(for:page)
            guard let position = move(to:index,userDriven:userDriven) else { return nil }
            pdfView.show(page,rect:selection.bounds(for:page))
            return position
        }
        guard let index = PDFPageLocator.index(locator,pageCount:document.pageCount) else { return nil }
        return move(to:index,userDriven:userDriven)
    }

    func turn(_ direction: PageDirection) -> EnginePosition? {
        move(to: pageIndex + (direction == .next ? 1 : -1), userDriven: true)
    }

    func scroll(_ direction: PageDirection, lines: Double) -> EnginePosition? {
        guard readingMode == .scroll, lines.isFinite, lines > 0 else { return nil }
        let amount = CGFloat(lines) * 22 * (direction == .next ? 1 : -1)
        suppressPageReports = true
        defer { suppressPageReports = false }
        #if os(macOS)
        guard let documentView = pdfView.documentView, let scroll = documentView.enclosingScrollView else { return nil }
        let clip = scroll.contentView
        let proposed = CGPoint(x:clip.bounds.minX,y:clip.bounds.minY + (documentView.isFlipped ? amount : -amount))
        let target = clip.constrainBoundsRect(CGRect(origin:proposed,size:clip.bounds.size)).origin
        guard abs(target.y - clip.bounds.minY) > 0.01 else { return nil }
        clip.scroll(to:target)
        scroll.reflectScrolledClipView(clip)
        #else
        guard let scroll = innerScrollView else { return nil }
        let first = -scroll.adjustedContentInset.top
        let last = max(first,scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let target = min(last,max(first,scroll.contentOffset.y + amount))
        guard abs(target - scroll.contentOffset.y) > 0.01 else { return nil }
        scroll.setContentOffset(CGPoint(x:scroll.contentOffset.x,y:target),animated:false)
        #endif
        if let page = pdfView.currentPage {
            let index = document.index(for:page)
            if (0..<document.pageCount).contains(index) { pageIndex = index }
        }
        #if os(iOS)
        pageLayers.attach(to:pdfView.currentPage)
        #endif
        return position(userDriven:true)
    }

    #if os(iOS)
    private var innerScrollView: UIScrollView? {
        var parent = pdfView.documentView
        while let view = parent, view !== pdfView {
            if let scroll = view as? UIScrollView { return scroll }
            parent = view.superview
        }
        return nil
    }
    #endif

    func seek(_ progress: Double) -> EnginePosition? {
        move(to: Int((progress * Double(document.pageCount - 1)).rounded()), userDriven: true)
    }

    func clearSelection() {
        #if os(iOS)
        tappedMark = nil
        markMenu.dismissMenu()
        #endif
        pdfView.clearSelection()
        onSelectionChange?(nil)
    }

    func applyAppearance(_ appearance: ReaderAppearance) -> EnginePosition {
        let changedMode = readingMode != appearance.mode
        readingMode = appearance.mode
        #if os(macOS)
        pdfView.backgroundColor = NSColor(appearance.background)
        #else
        pdfView.backgroundColor = UIColor(appearance.background)
        #endif
        pdfView.pageTheme = appearance.theme
        suppressPageReports = true
        defer { suppressPageReports = false }
        #if os(macOS)
        let margin = CGFloat(appearance.sideInset)
        pdfView.pageBreakMargins = NSEdgeInsets(top:margin,left:margin,bottom:margin,right:margin)
        #else
        let margin = CGFloat(appearance.margin / 4)
        pdfView.pageBreakMargins = UIEdgeInsets(top:margin,left:margin,bottom:margin,right:margin)
        #endif
        if changedMode || pdfView.displayMode != (readingMode == .scroll ? .singlePageContinuous : .singlePage) {
            pdfView.displayDirection = readingMode == .scroll ? .vertical : .horizontal
            #if os(iOS)
            if pdfView.isUsingPageViewController != (readingMode == .paged) {
                pdfView.usePageViewController(readingMode == .paged,withViewOptions:nil)
            }
            #endif
            pdfView.displayMode = readingMode == .scroll ? .singlePageContinuous : .singlePage
            if let page = document.page(at:pageIndex) { pdfView.show(page) }
        }
        return position(userDriven:false)
    }

    func zoom(by factor: CGFloat) {
        let scale = pdfView.scaleFactor * factor
        pdfView.scaleFactor = min(pdfView.maxScaleFactor,max(pdfView.minScaleFactor,scale))
    }

    private func move(to index: Int, userDriven: Bool) -> EnginePosition? {
        guard (0..<document.pageCount).contains(index), let page = document.page(at: index) else { return nil }
        clearSelection()
        pageIndex = index
        pdfView.show(page)
        #if os(iOS)
        pageLayers.attach(to:page)
        #endif
        return position(userDriven: userDriven)
    }

    private func onVisiblePageChanged() {
        guard !suppressPageReports, !pdfView.isRestoringPage, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index), index != pageIndex else { return }
        pageIndex = index
        #if os(iOS)
        pageLayers.attach(to:page)
        #endif
        onPositionChange?(position(userDriven: true))
    }

    func position(userDriven: Bool, at index: Int? = nil) -> EnginePosition {
        let pageIndex = index ?? self.pageIndex
        let locator = PDFPageLocator.encode(pageIndex)
        let count = document.pageCount
        let chapterHref = sectionStarts.last(where: { $0 <= pageIndex }).map(PDFPageLocator.encode) ?? locator
        let offset: Double?
        #if os(macOS)
        offset = readingMode == .scroll ? pdfView.documentView?.enclosingScrollView.map { Double($0.contentView.bounds.minY) } : nil
        #else
        offset = readingMode == .scroll ? innerScrollView.map { Double($0.contentOffset.y) } : nil
        #endif
        return EnginePosition(chapterHref: chapterHref, viewportOffset:offset,
                              anchor: ContentAnchor(href: locator, quote: "", fraction: 0),
                              userDriven: userDriven, mode: readingMode, locator: locator,
                              chapter: "第 \(pageIndex + 1) 页", page: pageIndex + 1, pageCount: count,
                              progress: count == 1 ? 1 : Double(pageIndex) / Double(count - 1),
                              canGoNext: pageIndex + 1 < count, canGoPrevious: pageIndex > 0)
    }

    func excerpt(at locator: String) -> String {
        if let selection = textSelection(at:locator) { return String((selection.string ?? "").prefix(1800)) }
        guard let index = PDFPageLocator.index(locator,pageCount:document.pageCount) else { return "" }
        return String((document.page(at:index)?.string ?? "").prefix(1800))
    }

    func precedingText(at locator: String) -> String {
        let range = PDFTextLocator.decode(locator)?.first
        guard let index = range?.page ?? PDFPageLocator.index(locator,pageCount:document.pageCount),
              index < document.pageCount else { return "" }
        let page = (document.page(at:index)?.string ?? "") as NSString
        let end = min(page.length,range?.range.location ?? 0)
        let length = min(3000,end)
        let samePage = page.substring(with:NSRange(location:end-length,length:length))
        guard index > 0, length < 3000 else { return samePage }
        let previous = document.page(at:index-1)?.string ?? ""
        return [String(previous.suffix(3000-length)),samePage].filter { !$0.isEmpty }.joined(separator:"\n")
    }

    func readingDiscussionExcerpts(through locator: String,from start: String,until end: String) -> [String] {
        let pageCount = document.pageCount
        guard let current = PDFPageLocator.index(locator,pageCount:pageCount) else { return [] }
        let first = start.isEmpty ? 0 : PDFPageLocator.index(start,pageCount:pageCount) ?? pageCount
        let next = end.isEmpty ? pageCount : PDFPageLocator.index(end,pageCount:pageCount) ?? first
        let last = min(current,next-1)
        guard last >= first else { return [] }
        let count = min(4,last-first+1)
        return (0..<count).compactMap { offset in
            let index = first + (count == 1 ? 0 : offset*(last-first)/(count-1))
            let text = (document.page(at:index)?.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(1400))
        }
    }

    func textSpans(_ selection: PDFSelection) -> [PDFTextLocator.Span] {
        selection.pages.flatMap { page in
            let index = document.index(for:page)
            return (0..<selection.numberOfTextRanges(on:page)).map {
                PDFTextLocator.Span(page:index,range:selection.range(at:$0,on:page))
            }
        }
    }

    private func textSelection(at locator: String) -> PDFSelection? {
        guard let spans = PDFTextLocator.decode(locator) else { return nil }
        let ranges = spans.compactMap { span -> PDFSelection? in
            guard span.page < document.pageCount, let page = document.page(at:span.page),
                  NSMaxRange(span.range) <= page.numberOfCharacters else { return nil }
            return page.selection(for:span.range)
        }
        guard ranges.count == spans.count, let result = ranges.first else { return nil }
        result.add(Array(ranges.dropFirst()))
        return result
    }

    var currentPageText: String {
        document.page(at:pageIndex)?.string ?? ""
    }

    func annotation(at range: NSRange) -> ReaderAnnotation? {
        guard let page = document.page(at:pageIndex), range.location >= 0, range.length > 0,
              range.length <= page.numberOfCharacters,
              range.location <= page.numberOfCharacters - range.length,
              let selection = page.selection(for:range) else { return nil }
        return annotation(for:selection)
    }

    func selectedAnnotation() -> ReaderAnnotation? {
        pdfView.currentSelection.flatMap(annotation(for:))
    }

    private func annotation(for selection: PDFSelection) -> ReaderAnnotation? {
        guard let quote = selection.string?.trimmingCharacters(in:.whitespacesAndNewlines),
              !quote.isEmpty, quote.count <= 100_000 else { return nil }
        let spans = textSpans(selection)
        guard let first = spans.first, first.page < document.pageCount,
              let locator = PDFTextLocator.encode(spans) else { return nil }
        if let saved = selectionRecords.first(where:{ $0.selectionLocator == locator && $0.responseToID == nil }) { return saved }
        let p = position(userDriven:false,at:first.page)
        let preferred = UserDefaults.standard.string(forKey:"readerAnnotationColor").flatMap(AnnotationColor.init(rawValue:)) ?? .yellow
        var note = ReaderAnnotation(cfi:"",quote:quote,chapter:p.chapter,progress:p.progress,color:preferred)
        note.sourceLocator = locator
        note.chapterHref = p.chapterHref
        return note
    }

    func setAnnotations(_ annotations: [ReaderAnnotation]) {
        selectionRecords = annotations
        marks.forEach { $0.page.removeAnnotation($0.mark) }
        marks.removeAll()
        var rendered = Set<String>()
        for record in annotations where record.responseToID == nil {
            guard let locator = record.selectionLocator, rendered.insert(locator).inserted,
                  let selection = textSelection(at:locator) else { continue }
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for:page)
                    guard !bounds.isEmpty else { continue }
                    let mark = PDFAnnotation(bounds:bounds,forType:record.color == .underline ? .underline : .highlight,withProperties:nil)
                    #if os(macOS)
                    mark.color = NSColor(record.color.swatch).withAlphaComponent(record.color == .underline ? 1 : 0.55)
                    #else
                    mark.color = UIColor(record.color.swatch).withAlphaComponent(record.color == .underline ? 1 : 0.55)
                    #endif
                    page.addAnnotation(mark)
                    marks.append((page,mark,record))
                }
            }
        }
    }

    #if os(macOS)
    @objc private func tapped(_ tap: NSClickGestureRecognizer) { handleTap(tap.location(in:pdfView)) }
    #else
    @objc private func tapped(_ tap: UITapGestureRecognizer) { handleTap(tap.location(in:pdfView)) }
    #endif

    private func handleTap(_ point: CGPoint) {
        guard selectedAnnotation() == nil, !pdfView.isInMarkupMode else { return }
        if let page = pdfView.page(for:point,nearest:false) {
            let pdfPoint = pdfView.convert(point,to:page)
            if let item = marks.last(where:{ $0.page == page && $0.mark.bounds.contains(pdfPoint) }) {
                onSelectionChange?(item.record)
                #if os(iOS)
                let id = UUID()
                tappedMark = (id,item.record)
                markMenu.presentEditMenu(with:UIEditMenuConfiguration(identifier:id.uuidString as NSString,sourcePoint:point))
                #endif
                return
            }
        }
        onSelectionChange?(nil)
        onToggleControls?()
    }

    func search(_ query: String) async throws -> [ChapterItem] {
        // Use a separate PDFDocument so page extraction never touches the
        // document being displayed. Return one result per matching page.
        let work = Task.detached(priority: .userInitiated) { [data] in
            let document = try BookImportFile.pdfDocument(data)
            let needle = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            var matches: [ChapterItem] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let pageText = document.page(at: index)?.string else { continue }
                let text = pageText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard let match = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                let start = text.index(match.lowerBound, offsetBy: -34, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(match.upperBound, offsetBy: 58, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = String(text[start..<end].prefix(180))
                let locator = PDFPageLocator.encode(index)
                matches.append(ChapterItem(id: locator, href: locator, title: "第 \(index + 1) 页 · \(snippet)", depth: 0))
                if matches.count == 80 { break }
            }
            return matches
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    #if os(iOS)
    func attachInk(_ controller: ReaderInlineInkController) {
        pageLayers.controller = controller
        pdfView.addInteraction(controller.pencilInteraction)
        pageLayers.attach(to:pdfView.currentPage)
    }

    func detachInk(_ controller: ReaderInlineInkController) {
        pdfView.removeInteraction(controller.pencilInteraction)
        pageLayers.setWritingEnabled(false)
        controller.canvas.removeFromSuperview()
        pageLayers.controller = nil
    }

    func inkContext(_ notes: [ReaderPageNote]) -> LivePageInkContext? {
        guard let page = pdfView.currentPage, pageLayers.editingPage == page else { return nil }
        let crop = page.pageRef?.getBoxRect(.cropBox) ?? page.bounds(for:.cropBox)
        guard crop.width.isFinite, crop.height.isFinite,
              (1...4096).contains(crop.width), (1...4096).contains(crop.height) else { return nil }
        let index = document.index(for:page)
        guard (0..<document.pageCount).contains(index) else { return nil }
        let p = position(userDriven:false,at:index)
        var anchor = ReaderPageAnchor(locator:p.locator,chapter:p.chapter,progress:p.progress,referenceX:0,referenceY:0,
                                      viewportWidth:crop.width,viewportHeight:crop.height,layoutKey:PDFPageLayers.layoutKey)
        anchor.chapterHref = p.chapterHref
        if inkSpans?.0 != page {
            let wholePage = page.selection(for:NSRange(location:0,length:page.numberOfCharacters))
            let spans = wholePage?.selectionsByLine().prefix(1200).compactMap { line -> ReaderInkTextSpan? in
                guard let text = line.string, !text.isEmpty, let first = textSpans(line).first,
                      let locator = PDFTextLocator.encode(textSpans(line)) else { return nil }
                let box = line.bounds(for:page)
                let rect = CGRect(x:box.minX-crop.minX,y:crop.maxY-box.maxY,width:box.width,height:box.height)
                guard !rect.isEmpty else { return nil }
                return ReaderInkTextSpan(id:locator,block:p.locator,offset:first.range.location,text:text,boxes:[.init(rect)])
            } ?? []
            inkSpans = (page,spans)
        }
        anchor.textSpans = inkSpans?.1
        let placements = notes.filter {
            $0.anchor.locator == p.locator && $0.anchor.layoutKey == anchor.layoutKey
                && $0.anchor.viewportWidth == anchor.viewportWidth && $0.anchor.viewportHeight == anchor.viewportHeight
        }.map { LivePageInkContext.Placement(id:$0.id,x:0,y:0) }
        return LivePageInkContext(anchor:anchor,placements:placements,token:p.locator)
    }

    func inkSnapshot() throws -> UIImage {
        guard let page = pageLayers.editingPage, let reference = page.pageRef else {
            throw ReaderError.message("未能读取当前 PDF 页面")
        }
        let crop = reference.getBoxRect(.cropBox)
        guard (1...4096).contains(crop.width), (1...4096).contains(crop.height) else {
            throw ReaderError.message("页面尺寸超出书写范围")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2,1600 / max(crop.width,crop.height))
        format.opaque = true
        return UIGraphicsImageRenderer(size:crop.size,format:format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin:.zero,size:crop.size))
            context.translateBy(x:-crop.minX,y:crop.maxY)
            context.scaleBy(x:1,y:-1)
            context.drawPDFPage(reference)
        }
    }
    #endif

    private static func outline(of document: PDFDocument) -> [(index: Int, item: ChapterItem)] {
        var entries: [(index: Int, item: ChapterItem)] = []
        var visited = 0
        func visit(_ node: PDFOutline, depth: Int) {
            guard depth <= 32, visited < 2_000 else { return }
            visited += 1
            if let page = node.destination?.page, let label = node.label, !label.isEmpty {
                let index = document.index(for: page)
                if (0..<document.pageCount).contains(index) {
                    let href = PDFPageLocator.encode(index)
                    entries.append((index, ChapterItem(id: "outline-\(entries.count)", href: href, title: label, depth: max(0, depth))))
                }
            }
            for childIndex in 0..<min(node.numberOfChildren, 2_000) {
                guard visited < 2_000, depth < 32 else { break }
                if let child = node.child(at: childIndex) { visit(child, depth: depth + 1) }
            }
        }
        if let root = document.outlineRoot { visit(root, depth: -1) }
        return entries
    }
}

#if os(iOS)
extension PDFBookReader: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let mark = tappedMark, configuration.identifier as? String == mark.id.uuidString,
              let actions = selectionMenu?(mark.record), !actions.isEmpty else { return nil }
        let copy = UIAction(title:"拷贝",image:UIImage(systemName:"doc.on.doc")) { _ in
            UIPasteboard.general.string = mark.record.quote
        }
        return UIMenu(children:actions + [copy])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: UIEditMenuInteractionAnimating) {
        guard let mark = tappedMark, configuration.identifier as? String == mark.id.uuidString else { return }
        tappedMark = nil
        onSelectionChange?(selectedAnnotation())
    }
}
#endif

/// PDFKit can report page one before the view has its first real layout.
private final class PageRestoringPDFView: PDFView {
    var pageTheme = "light" {
        didSet {
            guard pageTheme != oldValue else { return }
            #if os(macOS)
            documentView?.needsDisplay = true
            #else
            documentView?.setNeedsDisplay()
            #endif
            layoutDocumentView()
        }
    }

    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page,to:context)
        guard pageTheme != "light" else { return }
        // PDFKit clips its tiled drawing context to the page. Apply the paper
        // tint in the same context so it affects the page, not the live ink.
        context.saveGState()
        defer { context.restoreGState() }
        let clip = context.boundingBoxOfClipPath
        guard !clip.isNull, !clip.isInfinite else { return }
        if pageTheme == "night" {
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray:1,alpha:1))
        } else {
            context.setBlendMode(.multiply)
            context.setFillColor(CGColor(red:0.96,green:0.87,blue:0.73,alpha:0.36))
        }
        context.fill(clip)
    }

    private var pendingPage: PDFPage?
    private var pendingRect: CGRect?
    private var applyingPage = false
    var isRestoringPage: Bool { pendingPage != nil || applyingPage }

    func show(_ page: PDFPage, rect: CGRect? = nil) {
        pendingPage = page
        pendingRect = rect
        applyPendingPage()
    }

    private func applyPendingPage() {
        guard !applyingPage, let page = pendingPage, window != nil, !bounds.isEmpty else { return }
        applyingPage = true
        pendingPage = nil
        if let rect = pendingRect, !rect.isEmpty { go(to:rect,on:page) }
        else { go(to:page) }
        pendingRect = nil
        applyingPage = false
    }

    #if os(macOS)
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func layout() { super.layout(); applyPendingPage() }
    func accessibilityIdentifierForReading() { setAccessibilityIdentifier("pdf-reader") }
    #else
    var selectionMenu: (() -> [UIMenuElement])?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with:builder)
        guard builder.system == .context, currentSelection != nil, let selectionMenu else { return }
        ReaderSelectionMenu.install(UIDeferredMenuElement.uncached { complete in complete(selectionMenu()) },in:builder)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
    override func layoutSubviews() { super.layoutSubviews(); applyPendingPage() }
    func accessibilityIdentifierForReading() { accessibilityIdentifier = "pdf-reader" }
    #endif
}

#if os(macOS)
struct NativeBookCanvas: NSViewRepresentable {
    let view: NSView
    let reader: ReaderModel
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
#else
struct NativeBookCanvas: UIViewRepresentable {
    let view: UIView
    let reader: ReaderModel

    @MainActor final class Coordinator {
        let pdf: PDFBookReader?
        let ink: ReaderInlineInkController?
        init(reader: ReaderModel) {
            pdf = reader.pdfBookReader
            ink = pdf.map { ReaderInlineInkController(reader:reader,pdf:$0) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(reader:reader) }

    func makeUIView(context: Context) -> UIView {
        if let pdf = context.coordinator.pdf, let ink = context.coordinator.ink {
            reader.inlineInk = ink
            pdf.attachInk(ink)
            ink.start()
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.ink?.updateTools() }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if let pdf = coordinator.pdf, let ink = coordinator.ink {
            ink.stop()
            pdf.detachInk(ink)
        }
    }
}
#endif
