import SwiftUI
import UIKit

private enum ReaderPanel: String, Identifiable {
    case menu, progress, contents, appearance, search, remote, ipadRemote, sync
    var id: String { rawValue }
}

struct PhoneReadingView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var ipadReceiver: IPadReaderReceiver
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @ObservedObject private var relay = PhoneRelay.shared
    @State private var panel: ReaderPanel?
    @StateObject private var panelPresentation = ReaderPanelPresentation()
    @State private var returnPoint: (locator: String,chapter: String,position: String,viewport: ReaderViewport?)?
    @State private var progressAtCenter = false
    @State private var pendingMenuAction: (bookID: UUID,sessionID: UUID,action: ReaderMenuAction)?
    @State private var recoveringNotes = false
    @State private var showHint = false
    @State private var voiceOver = UIAccessibility.isVoiceOverRunning
    @State private var companionMounted = false
    @State private var companionExpanded = false
    @State private var companionVisible = false
    @State private var companionPanelReady = false
    @State private var companionPageReady = false
    @State private var companionInputReady = false
    @State private var companionPageSurface = UIView()
    @State private var companionGeneration = UUID()
    @State private var companionReturnPoint: (bookID: UUID,session: UUID,position: EnginePosition)?
    @State private var departingDiscussion: ReaderAnnotationDraft?
    @State private var departingEntity: ReaderAnnotationDraft?
    @State private var companionTask: Task<Void,Never>?
    @AppStorage("readerGesturesDiscovered") private var gesturesDiscovered = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var controls: Bool { reader.readingControlsVisible || reader.loading || voiceOver }
    private var chromeVisible: Bool { controls || panel != nil || recoveringNotes || reader.showProgressSettings || reader.inlineInkToolsVisible }
    private var ink: Color { reader.appearance.ink }
    private var companionRequested: Bool { isPad && (reader.showNoteGraph || reader.selectionDiscussion != nil || reader.selectionEntity != nil) }
    private var inkObscured: Bool {
        panel != nil || recoveringNotes || reader.showProgressSettings || companionMounted || reader.showNoteGraph ||
        reader.selectionDiscussion != nil || reader.selectionEntity != nil || reader.quickNoteDraft != nil || reader.pageNoteToView != nil
    }
    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= 900
            let notesWidth = min(480,geometry.size.width * 0.43)
            let pageHeight = max(230,geometry.size.height * 0.46)
            let fullCanvas = reader.knowledgeCanvasExpanded
            ZStack(alignment:.topLeading) {
                readingSurface
                    .frame(width:companionExpanded && sideBySide && !fullCanvas ? geometry.size.width-notesWidth-1 : geometry.size.width,
                           height:companionExpanded && !sideBySide && !fullCanvas ? pageHeight : nil)
                    .ignoresSafeArea(isPad && sideBySide ? .keyboard : [],edges:.bottom)
                if companionMounted {
                    readingCompanion
                        .frame(width:fullCanvas ? geometry.size.width : sideBySide ? notesWidth : geometry.size.width,
                               height:fullCanvas || sideBySide ? geometry.size.height : geometry.size.height-pageHeight-1)
                        .overlay(alignment:sideBySide ? .leading : .top) {
                            Rectangle().fill(ink.opacity(0.20))
                                .frame(width:sideBySide ? 1 : nil,height:sideBySide ? nil : 1)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        .opacity(reduceMotion && !companionVisible ? 0 : 1)
                        .offset(x:fullCanvas ? 0 : sideBySide ? geometry.size.width-notesWidth+(companionVisible || reduceMotion ? 0 : notesWidth) : 0,
                                y:fullCanvas || sideBySide ? 0 : pageHeight+1+(companionVisible || reduceMotion ? 0 : geometry.size.height-pageHeight))
                        .allowsHitTesting(companionVisible)
                        .accessibilityHidden(!companionVisible)
                }
            }.frame(width:geometry.size.width,height:geometry.size.height,alignment:.topLeading)
                // The EPUB clips its own viewport. Clipping this safe-area
                // container would cut scrolling text off above the home edge.
                .background(reader.appearance.background.ignoresSafeArea())
        }
        .statusBarHidden(true)
        .onAppear { updateCompanionPresentation() }
        .onChange(of:companionRequested) { _,_ in updateCompanionPresentation() }
        .onChange(of:reader.selectionDiscussion?.id) { _,_ in
            if let draft = reader.selectionDiscussion { departingDiscussion = draft }
        }
        .onChange(of:reader.selectionEntity?.id) { _,_ in
            if let draft = reader.selectionEntity { departingEntity = draft }
        }
        .onReceive(reader.$position) { position in
            // Reflow can publish a temporary chapter start. Only deliberate
            // reading beside the editor changes where closing it should return.
            guard companionRequested, companionInputReady,
                  let point = companionReturnPoint, let position, position.userDriven == true,
                  reader.currentID == point.bookID, reader.sessionID == point.session else { return }
            companionReturnPoint = (point.bookID,point.session,position)
        }
        .onDisappear {
            companionTask?.cancel()
            companionReturnPoint = nil
            (reader.webView.superview as? ReaderPencilHost)?.cancelCompanionTransition()
        }
    }
    private func updateCompanionPresentation() {
        companionTask?.cancel()
        let generation = UUID()
        companionGeneration = generation
        if companionRequested {
            if !companionMounted, let bookID = reader.currentID, let position = reader.position {
                companionReturnPoint = (bookID,reader.sessionID,position)
            }
            departingDiscussion = reader.selectionDiscussion
            departingEntity = reader.selectionEntity
            companionPanelReady = false; companionPageReady = false; companionInputReady = false
            let opening = !companionMounted
            let bookID = reader.currentID, session = reader.sessionID
            companionTask = Task { @MainActor in
                // Read the live page before changing its bounds. The last native
                // position can still precede a just-finished WebKit scroll.
                if opening {
                    let value = try? await reader.webView.callAsyncJavaScript("return await reader.captureReadingPosition()",arguments:[:],in:nil,contentWorld:.page)
                    guard !Task.isCancelled, companionGeneration == generation, companionRequested,
                          reader.currentID == bookID, reader.sessionID == session else { return }
                    if let value { reader.acceptPosition(value) }
                    if let bookID, let position = reader.position { companionReturnPoint = (bookID,session,position) }
                }
                guard !Task.isCancelled, companionGeneration == generation, companionRequested else { return }
                prepareCompanionPage(generation:generation)
                var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    companionMounted = true; companionExpanded = true
                    if opening { companionVisible = false }
                }
                // Commit the EPUB's final width once, then animate only the
                // panel's compositing properties, not WebKit's bounds.
                do { try await Task.sleep(for:.milliseconds(16)) } catch { return }
                guard companionRequested, !Task.isCancelled else { return }
                withAnimation(companionAnimation,completionCriteria:.logicallyComplete) {
                    companionVisible = true
                } completion: {
                    guard companionGeneration == generation, companionRequested, companionVisible else { return }
                    companionPanelReady = true
                    companionInputReady = companionPageReady
                }
            }
        } else if companionMounted {
            companionInputReady = false
            companionPanelReady = false; companionPageReady = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)
            prepareCompanionPage(generation:generation,restoring:true)
            var transaction = Transaction(animation:nil); transaction.disablesAnimations = true
            withTransaction(transaction) { companionExpanded = false }
            withAnimation(companionAnimation,completionCriteria:.logicallyComplete) { companionVisible = false } completion: {
                guard companionGeneration == generation, !companionRequested else { return }
                companionPanelReady = true
                finishCompanionDismissal(generation:generation)
            }
        }
    }
    private func finishCompanionDismissal(generation: UUID) {
        guard companionGeneration == generation, !companionRequested, companionPanelReady, companionPageReady else { return }
        companionMounted = false; departingDiscussion = nil; departingEntity = nil; companionReturnPoint = nil
        reader.knowledgeCanvasExpanded = false
    }
    private var companionAnimation: Animation {
        reduceMotion ? .easeOut(duration:0.12) : .timingCurve(
            ReaderCompanionMotion.first.x,ReaderCompanionMotion.first.y,
            ReaderCompanionMotion.second.x,ReaderCompanionMotion.second.y,duration:ReaderCompanionMotion.duration)
    }
    private func prepareCompanionPage(generation: UUID,restoring: Bool = false) {
        guard reader.supportsReflow, let host = reader.webView.superview as? ReaderPencilHost else {
            companionPageReady = true
            if companionRequested && companionPanelReady && companionVisible { companionInputReady = true }
            return
        }
        let checkpoint = companionReturnPoint
        host.prepareCompanionTransition(in:companionPageSurface,beforeReveal:{
            guard let point = checkpoint, companionGeneration == generation, companionRequested != restoring,
                  reader.currentID == point.bookID, reader.sessionID == point.session, !reader.loading, !reader.busy else { return }
            reader.busy = true
            defer { if reader.sessionID == point.session { reader.busy = false } }
            do {
                let value = try await reader.webView.callAsyncJavaScript("return await reader.restoreReadingPosition(locator,viewport)",arguments:[
                    "locator":point.position.locator,"viewport":try point.position.viewport.map { try reader.dictionary($0) } as Any? ?? NSNull()
                ],in:nil,contentWorld:.page)
                guard !Task.isCancelled, companionGeneration == generation,
                      reader.currentID == point.bookID, reader.sessionID == point.session else { return }
                if let value { reader.acceptPosition(value) }
            } catch { /* Keep the live renderer usable if a checkpoint cannot be restored. */ }
        }) {
            guard companionGeneration == generation else { return }
            companionPageReady = true
            if companionRequested && companionPanelReady && companionVisible { companionInputReady = true }
            if !companionRequested { finishCompanionDismissal(generation:generation) }
        }
    }
    private var readingCompanion: some View { readingNotes }
    private var readingNotes: some View {
        BookNotesWorkspace(reader:reader,readingCompanion:true,noteInputReady:companionInputReady,
                           closingDiscussion:companionRequested ? nil : departingDiscussion,
                           closingEntity:companionRequested ? nil : departingEntity) {
            reader.selectionDiscussion = nil; reader.selectionEntity = nil
            reader.showNoteGraph = false
            reader.annotationDraft = nil; reader.graphNoteID = nil
        }.preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
    }
    private var readingCanvas: some View {
        ZStack {
            reader.appearance.background.ignoresSafeArea()
            BookCanvas(reader:reader)
                .frame(maxWidth:.infinity)
                .padding(.vertical,reader.isScrolling ? 0 : isPad ? 8 : 14)
                .ignoresSafeArea(.container,edges:reader.isScrolling ? .vertical : [])
                .opacity(reader.loading ? 0 : 1)
                .accessibilityAction(named:Text("显示阅读工具")) { if isPad { present(.menu) } else { reader.readingControlsVisible = true } }
                .accessibilityAction(named:Text(reader.readingMode.nextLabel)) { turn(.next) }
                .accessibilityAction(named:Text(reader.readingMode.previousLabel)) { turn(.previous) }
                .accessibilityScrollAction { edge in
                    if edge == .trailing || edge == .bottom { turn(.next) }
                    else { turn(.previous) }
                }
            // Keep the native snapshot surface below SwiftUI controls. Even a
            // transparent UIView above the chrome can obscure its hit targets.
            ReaderCompanionPageSurface(view:companionPageSurface)
                .allowsHitTesting(false).accessibilityHidden(true)
            if reader.loading {
                VStack(spacing:22) {
                    if let book = reader.currentBook { BookJacket(reader:reader,book:book).frame(width:104) }
                    ProgressView().tint(ink.opacity(0.65)).accessibilityLabel("正在打开书籍")
                }
            }
            if !chromeVisible, !reader.loading, !companionMounted, let _ = reader.position {
                VStack {
                    Spacer()
                    Button { reader.readingControlsVisible = true } label: {
                        Text(reader.positionLabel)
                            .font(.system(size:11)).monospacedDigit().foregroundStyle(ink.opacity(0.55))
                            .padding(.horizontal,12).frame(minHeight:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(reader.positionLabel)，显示阅读工具")
                        .accessibilityIdentifier("reader-show-tools")
                }.padding(.bottom,8)
            }
            readingChrome
                .opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible).accessibilityHidden(!chromeVisible)
            if showHint && !controls && !isPad {
                VStack { Spacer(); Text(reader.isScrolling ? "上下滑动阅读 · 轻点显示工具" : "轻点显示工具 · 左右轻扫翻页")
                    .font(.caption).padding(.horizontal,16).padding(.vertical,10)
                    .background(.regularMaterial,in:Capsule()).padding(.bottom,44)
                }.allowsHitTesting(false).transition(.opacity)
            }
            if let message = reader.readingNotice {
                VStack { Spacer(); Text(message).font(.caption).padding(12).modifier(ReaderGlassSurface(shape:Capsule())).padding(.bottom,(chromeVisible ? 76 : 44)+(reader.inlineInkToolsVisible ? 132 : 0)) }
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment:.bottom) {
            if reader.inlineInkToolsVisible, !reader.loading, !reader.inlineInkSelectionActive, !reader.inlineInkMenuActive,
               panel == nil, !recoveringNotes, !reader.showProgressSettings,
               !reader.showNoteGraph, !companionMounted, reader.selectionDiscussion == nil, reader.quickNoteDraft == nil, reader.pageNoteToView == nil {
                ReaderInkToolbar(reader:reader).padding(.bottom,76)
            }
        }
        .overlay(alignment:.top) {
            if !reader.loading {
                VStack(spacing:0) {
                    if !isPad || controls { SharedProgressPrompt(reader:reader) }
                    if !isPad { ReaderNoteNotices(reader:reader) }
                }.padding(.top,controls ? 64 : 8)
            }
        }
        .foregroundStyle(ink)
        .tint(readingAccent)
        .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
        .animation(reduceMotion ? nil : .easeOut(duration:0.18),value:controls)
        .animation(reduceMotion ? nil : .easeOut(duration:0.18),value:chromeVisible)
    }
    private var entityModal: Binding<ReaderAnnotationDraft?> {
        Binding(get:{ isPad ? nil : reader.selectionEntity },set:{ if !isPad { reader.selectionEntity = $0 } })
    }
    private var readingSurface: some View {
        readingCanvas
        .sheet(item:modalPanel,onDismiss:finishMenuAction) { item in
            panelContent(item)
                .environment(\.readerPanelBack,item == .menu || progressAtCenter ? nil : { present(.menu) })
                .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
                .background(ReaderPopoverLifecycle(dismissed:finishMenuAction,presentation:panelPresentation))
        }
        .sheet(isPresented:$recoveringNotes) { ReaderNoteRecoveryView(reader:reader) }
        .sheet(item:entityModal) { draft in
            ReadingEntityFromSelection(reader:reader,draft:draft)
        }
        .onAppear {
            reader.webView.evaluateJavaScript("reader.setActive(true)",completionHandler:nil)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { reader.inlineInkObscured = false; UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of:inkObscured,initial:true) { _,shown in
            reader.inlineInkObscured = shown
            if shown { _ = reader.inlineInk?.suspend() }
        }
        .onChange(of:reader.inlineInkToolsVisible) { _,visible in
            if visible { reader.readingControlsVisible = true }
        }
        .onChange(of:reader.currentID) { _,_ in returnPoint = nil; panel = nil; pendingMenuAction = nil }
        .onChange(of:scenePhase) { _,phase in
            reader.webView.evaluateJavaScript("reader.setActive(\(phase == .active ? "true" : "false"))",completionHandler:nil)
            if phase != .active { _ = reader.inlineInk?.keepDraft(); _ = reader.inlineInk?.persist() }
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
        .onChange(of:reader.appearance) { _,_ in reader.updateAppearance() }
        .onChange(of:reader.readingControlsVisible) { _,visible in
            if visible { gesturesDiscovered = true; showHint = false }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in voiceOver = UIAccessibility.isVoiceOverRunning }
        .task(id:reader.loading) {
            guard !reader.loading, !gesturesDiscovered else { return }
            showHint = true
            try? await Task.sleep(for:.seconds(4))
            guard !Task.isCancelled else { return }
            showHint = false; gesturesDiscovered = true
        }
    }
    // One reading hierarchy on iPhone and iPad. Controls float over the page;
    // showing them never changes the EPUB viewport or its saved position.
    private var readingChrome: some View {
        VStack(spacing:0) {
            HStack(alignment:.top) {
                if let point = returnPoint {
                    Button(action:goBack) {
                        Label("回到刚才",systemImage:"arrow.uturn.backward")
                            .font(.system(size:12,weight:.medium)).padding(.horizontal,12).frame(minHeight:44)
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).modifier(ReaderGlassSurface(shape:Capsule()))
                        .disabled(reader.busy || reader.loading).accessibilityLabel("回到刚才，\(point.chapter)")
                        .accessibilityIdentifier("reader-return-to-position")
                }
                Spacer(minLength:0)
                Button { closeBook() } label: {
                    Image(systemName:"xmark").font(.system(size:16,weight:.medium))
                        .frame(width:44,height:44).contentShape(Circle())
                }.buttonStyle(.plain).modifier(ReaderGlassSurface(shape:Circle()))
                    .accessibilityLabel("关闭图书，返回书库").accessibilityIdentifier("reader-close-book")
            }
            Spacer(minLength:0)
            if !reader.loading && !reader.showNoteGraph && !companionMounted && reader.selectionDiscussion == nil && reader.selectionEntity == nil {
                readingDock
            }
        }.padding(.horizontal,isPad ? 24 : 20).padding(.top,8).padding(.bottom,12).foregroundStyle(ink)
    }
    private var readingDock: some View {
        HStack(spacing:0) {
            HStack(spacing:0) {
                if !reader.inlineInkSelectionActive && !reader.inlineInkMenuActive {
                    Button { reader.beginPageHandwriting() } label: {
                        Image(systemName:reader.inlineInkToolsVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                            .foregroundStyle(reader.inlineInkToolsVisible ? readingAccent : ink)
                            .font(.system(size:19,weight:.regular)).frame(width:44,height:44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(reader.inlineInkToolsVisible ? "收起画笔工具" : "显示画笔工具")
                        .accessibilityIdentifier("reader-ink-tools")
                }
                Button { reader.beginQuickNote() } label: {
                    Image(systemName:"square.and.pencil").font(.system(size:19,weight:.regular))
                        .frame(width:44,height:44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("添加本小节笔记")
                    .accessibilityIdentifier("reader-add-section-note")
            }.padding(.horizontal,4).modifier(ReaderGlassSurface(shape:Capsule()))
                .disabled(reader.loading || reader.busy)
                .frame(width:96,alignment:.leading)
            Spacer(minLength:0)
            readingProgressControl
            Spacer(minLength:0)
            Button { present(.menu) } label: {
                Image(systemName:"text.justify").font(.system(size:18,weight:.medium))
                    .frame(width:44,height:44).contentShape(Circle())
            }.buttonStyle(.plain).modifier(ReaderGlassSurface(shape:Circle()))
                .overlay(alignment:.topTrailing) {
                    if reader.recoverableNoteDraftCount > 0 || !reader.hiddenPageNoteIDs.isEmpty || reader.pendingProgress != nil {
                        Circle().fill(readingAccent).frame(width:6,height:6).padding(4).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("阅读菜单").accessibilityIdentifier("reader-menu")
                .disabled(reader.loading || reader.busy)
                .popover(isPresented:Binding(get:{ isPad && panel != nil && !progressAtCenter },set:{ if !$0 && !progressAtCenter { panel = nil } }),arrowEdge:.bottom) {
                    // Keep the controller mounted through dismissal so its
                    // lifecycle can finish a queued note or handwriting action.
                    glassPanel(panel ?? .menu)
                }
                .frame(width:96,alignment:.trailing)
        }
    }
    @ViewBuilder private var readingProgressControl: some View {
        if let position = reader.position {
            Button { present(.progress,atCenter:true) } label: {
                VStack(spacing:3) {
                    Text(reader.positionLabel).monospacedDigit()
                    if position.mode == .paged && isPad {
                        Text(position.pageCount > position.page ? "本章还剩 \(position.pageCount-position.page) 页" : "本章最后一页")
                    }
                }.font(.system(size:11)).foregroundStyle(ink.opacity(0.65))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width:isPad ? 120 : 72).frame(minHeight:44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(reader.busy || reader.loading)
                .accessibilityLabel("阅读进度，已读 \(Int(position.progress*100))%")
                .accessibilityIdentifier("reader-progress")
                .popover(isPresented:Binding(get:{ isPad && panel == .progress && progressAtCenter },set:{ if !$0 && progressAtCenter { panel = nil } }),arrowEdge:.bottom) {
                    glassPanel(.progress)
                }
        }
    }
    private func closeBook() {
        let bookID = reader.currentID, session = reader.sessionID
        Task { @MainActor in
            if let flush = reader.mindMapInputFlush, !(await flush.perform()) { return }
            guard reader.currentID == bookID, reader.sessionID == session else { return }
            reader.close()
        }
    }
    private func turn(_ direction: PageDirection) { Task { @MainActor in await reader.turnLocally(direction) } }
    private func present(_ item: ReaderPanel,atCenter: Bool = false) {
        guard !reader.loading, !reader.busy, reader.suspendInlineInkForNavigation() else { return }
        (reader.webView as? ReaderTextWebView)?.dismissAnnotationMenu()
        reader.webView.evaluateJavaScript("reader.dismissAnnotations()",completionHandler:nil)
        progressAtCenter = atCenter; panel = item
    }
    private var modalPanel: Binding<ReaderPanel?> {
        Binding(get:{ isPad ? nil : panel },set:{ panel = $0 })
    }
    private func glassPanel(_ item: ReaderPanel) -> some View {
        panelContent(item)
            .environment(\.readerGlassPanel,true)
            .environment(\.readerPanelBack,item == .menu || progressAtCenter ? nil : { present(.menu) })
            .frame(idealWidth:320,maxWidth:320)
            .frame(height:item == .progress ? 236 : item == .menu ? 332 : 560)
            .background(ReaderPopoverLifecycle(dismissed:finishMenuAction,presentation:panelPresentation))
            .modifier(ReaderPanelMaterial()).presentationCornerRadius(24).presentationCompactAdaptation(.sheet)
    }
    @ViewBuilder private func panelContent(_ item: ReaderPanel) -> some View {
        Group {
            switch item {
            case .menu: ReaderMenuPanel(reader:reader,navigate:menuNavigate,perform:queueMenuAction,close:{ panel = nil })
            case .progress: ReaderProgressPanel(reader:reader,seek:seek,close:{ panel = nil })
            case .appearance: ReaderAppearancePanel(reader:reader) { panel = nil }
            case .contents: ReaderNavigationPanel(reader:reader,navigate:jump,close:{ panel = nil })
            case .search: ReaderSearchPanel(reader:reader,navigate:jump,close:{ panel = nil })
            case .remote: PhoneRemoteView()
            case .ipadRemote: IPadRemoteSetup(receiver:ipadReceiver)
            case .sync: ProgressSyncView(reader:reader)
            }
        }.foregroundStyle(Color.primary).tint(readingAccent).preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
    }
    private func menuNavigate(_ destination: ReaderMenuDestination) {
        switch destination {
        case .contents: present(.contents)
        case .search: present(.search)
        case .appearance: present(.appearance)
        case .progress: present(.progress)
        case .watch: present(isPad ? .ipadRemote : .remote)
        case .sync: present(.sync)
        }
    }
    private func queueMenuAction(_ action: ReaderMenuAction) {
        guard pendingMenuAction == nil, let id = reader.currentID, reader.suspendInlineInkForNavigation() else { return }
        pendingMenuAction = (id,reader.sessionID,action)
        if panelPresentation.dismiss(completion:{ panel = nil; finishMenuAction() }) { return }
        panel = nil
    }
    private func finishMenuAction() {
        guard panel == nil, let pending = pendingMenuAction else { return }
        pendingMenuAction = nil
        guard reader.currentID == pending.bookID, reader.sessionID == pending.sessionID else { return }
        switch pending.action {
        case .note: reader.beginQuickNote()
        case .graph: reader.openNoteGraph()
        case .handwriting: reader.beginPageHandwriting()
        case .drafts: recoveringNotes = true
        case .originalPage:
            if let id = reader.hiddenPageNoteIDs.first, let note = reader.currentPageNotes.first(where: { $0.id == id }) { reader.pageNoteToView = note }
        }
    }
    private func seek(_ value: Double) {
        let previous = reader.position
        guard reader.seek(value) else { return }
        remember(previous); panel = nil
    }
    private func remember(_ position: EnginePosition?) {
        if let position {
            let label = position.mode == .paged ? "\(position.page)" : "\(Int(position.progress*100))%"
            returnPoint = (position.locator,position.chapter,label,position.viewport)
        }
    }
    private func jump(_ href: String) {
        let previous = reader.position
        guard reader.go(href,viewport:reader.currentBook?.bookmarks.first(where:{ $0.id == href })?.viewport) else { return }
        remember(previous)
        panel = nil; reader.readingControlsVisible = false
    }
    private func goBack() {
        guard let point = returnPoint, reader.go(point.locator,viewport:point.viewport) else { return }
        returnPoint = nil
    }
}
