import SwiftUI
import WebKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReaderAnnotationDraft: Identifiable {
    let bookID: UUID
    var annotation: ReaderAnnotation
    var translates = false
    var returnToGraph = false
    var id: String { annotation.id }
}

extension ReaderModel {
    var pageAnnotations: [ReaderAnnotation] {
        currentAnnotations.map { original in
            var value = original; value.discussion = nil; value.graphRelationDraft = nil; return value
        }
    }
    var currentAnnotations: [ReaderAnnotation] {
        (currentBook?.annotations ?? []).sorted {
            if $0.progress != $1.progress { return $0.progress < $1.progress }
            return $0.createdAt < $1.createdAt
        }
    }

    func receiveAnnotation(_ type: String, value: Any?) {
        guard let data = value as? [String:Any], let bookID = currentID, !loading,
              data["session"] as? String == annotationSessionID.uuidString,
              let id = data["id"] as? String, UUID(uuidString:id) != nil else { return }
        if type == "annotationRemove" { _ = removeAnnotation(id,bookID:bookID); return }
        guard let cfi = data["cfi"] as? String, cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")"), cfi.count <= 8192,
              let quote = data["quote"] as? String, !quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              quote.count <= 100_000, let rawColor = data["color"] as? String, let color = AnnotationColor(rawValue:rawColor),
              let chapter = data["chapter"] as? String, let progress = data["progress"] as? Double,
              progress.isFinite, (0...1).contains(progress) else { return }
        var selection = ReaderAnnotation(id:id,cfi:cfi,quote:quote,chapter:chapter,progress:progress,color:color)
        if let href = data["chapterHref"] as? String, href.count <= 8192 { selection.chapterHref = href }
        performSelectionAction(type, selection:selection, bookID:bookID, webContext:data)
    }

    func performSelectionAction(_ type: String, selection: ReaderAnnotation, bookID: UUID, webContext: [String:Any]? = nil) {
        guard currentID == bookID, !loading, let locator = selection.selectionLocator else { return }
        if type == "annotationRemove" { _ = removeAnnotation(selection.id,bookID:bookID); return }
        if type == "annotationTranslate" {
            #if os(iOS)
            guard suspendInlineInkForNavigation() else { return }
            #endif
            let returnToGraph = showNoteGraph
            selectionEntity = nil; showNoteGraph = false
            selectionDiscussion = ReaderAnnotationDraft(bookID:bookID,annotation:selection,translates:true,returnToGraph:returnToGraph)
            return
        }
        let reusesSelection = ["annotationPencilHighlight","annotationDiscuss","annotationEdit","annotationEntity","annotationPerson"].contains(type)
        let existing = currentAnnotations.first { $0.id == selection.id }
            ?? (type == "annotationDiscuss" ? currentAnnotations.first { $0.selectionLocator == locator && $0.discussion != nil } : nil)
            ?? (reusesSelection ? currentAnnotations.first { $0.selectionLocator == locator && $0.responseToID == nil } : nil)
            ?? (type == "annotationChange" ? nil : textNoteDrafts.first {
                $0.bookID == bookID && $0.annotation.selectionLocator == locator && !isNoteRemoved($0.id,bookID:bookID)
            }?.annotation)
        var item = existing ?? selection
        item.color = type == "annotationPencilHighlight" ? existing?.color ?? selection.color : selection.color
        item.chapterHref = selection.chapterHref ?? item.chapterHref
        if type == "annotationDiscuss" {
            #if os(iOS)
            guard suspendInlineInkForNavigation() else { return }
            #endif
            selectionEntity = nil
            showNoteGraph = false; annotationDraft = nil; graphNoteID = nil; discussionNoteID = nil
            selectionDiscussion = ReaderAnnotationDraft(bookID:bookID,annotation:noteForEditing(item,bookID:bookID))
        }
        else if webContext == nil && type == "annotationEntity" {
            #if os(iOS)
            guard suspendInlineInkForNavigation() else { return }
            #endif
            showNoteGraph = false; selectionDiscussion = nil
            selectionEntity = ReaderAnnotationDraft(bookID:bookID,annotation:noteForEditing(item,bookID:bookID))
        }
        else if ["annotationEdit","annotationEntity","annotationPerson"].contains(type) {
            selectionDiscussion = nil
            annotationDraft = ReaderAnnotationDraft(bookID:bookID,annotation:noteForEditing(item,bookID:bookID))
            discussionNoteID = nil
            openNoteGraph(noteID:annotationDraft?.id)
        }
        else if type == "annotationChange" { _ = saveAnnotation(item,bookID:bookID) }
        else if type == "annotationPencilHighlight" {
            // Re-selecting an existing mark must not overwrite its note or
            // discard an unfinished text draft just to display the options.
            guard existing != nil || saveAnnotation(item,bookID:bookID) else { return }
            #if os(iOS)
            guard let data = webContext,
                  let saved = currentAnnotations.first(where:{ $0.id == item.id }) ?? currentAnnotations.first(where:{ $0.cfi == item.cfi }),
                  let web = webView as? ReaderTextWebView,
                  var context = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(saved))) as? [String:Any],
                  let x = data["x"] as? Double, let y = data["y"] as? Double, x.isFinite, y.isFinite else { return }
            let session = annotationSessionID
            context["session"] = session.uuidString; context["existing"] = true
            web.callAsyncJavaScript("return reader.dismissAnnotationSelection(id,cfi,session)",arguments:["id":item.id,"cfi":item.cfi,"session":session.uuidString],in:nil,in:.page) { [weak self, weak web] result in
                guard let self, let web, self.currentID == bookID, self.annotationSessionID == session,
                      case .success(let cleared) = result, cleared as? Bool == true else { return }
                web.presentAnnotationMenu(context:context,x:x,y:y)
            }
            #endif
        }
    }

    @discardableResult func saveAnnotation(_ annotation: ReaderAnnotation, bookID: UUID) -> Bool {
        guard bookID == currentID, let index = books.firstIndex(where: { $0.id == bookID }) else { return false }
        var items = books[index].annotations ?? []
        var item = annotation; item.updatedAt = Date()
        if item.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { item.note = "" }
        if let existing = items.firstIndex(where: { $0.id == item.id }) ?? items.firstIndex(where: { item.selectionLocator != nil && $0.selectionLocator == item.selectionLocator && ($0.intent ?? .thought) == (item.intent ?? .thought) && $0.responseToID == item.responseToID }) {
            item.id = items[existing].id; item.createdAt = items[existing].createdAt
            items[existing] = item
        } else { items.append(item) }
        guard persistAnnotations(items,at:index,preferredColor:item.color.rawValue) else { return false }
        if let id = UUID(uuidString:annotation.id) { try? discardNoteDraft(bookID:bookID,id:id,ink:false) }
        UserDefaults.standard.set(item.color.rawValue,forKey:"readerAnnotationColor")
        return true
    }

    @discardableResult func removeAnnotation(_ id: String, bookID: UUID) -> Bool {
        guard bookID == currentID, let index = books.firstIndex(where: { $0.id == bookID }) else { return false }
        guard let item = books[index].annotations?.first(where: { $0.id == id }) else { return false }
        let removed = ReaderRemovedNote(annotation:item)
        guard persistAnnotations((books[index].annotations ?? []).filter { $0.id != id },at:index,removed:removed) else { return false }
        if let draftID = UUID(uuidString:id) { try? discardNoteDraft(bookID:bookID,id:draftID,ink:false) }
        return true
    }

    @discardableResult func removeAnnotationText(_ id: String, bookID: UUID) -> Bool {
        guard bookID == currentID, let index = books.firstIndex(where: { $0.id == bookID }),
              let item = books[index].annotations?.first(where: { $0.id == id }), !item.note.isEmpty else { return false }
        var items = books[index].annotations ?? []
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].note = ""; items[i].updatedAt = Date() }
        guard persistAnnotations(items,at:index,removed:ReaderRemovedNote(annotation:item,noteOnly:true)) else { return false }
        if let draftID = UUID(uuidString:id) { try? discardNoteDraft(bookID:bookID,id:draftID,ink:false) }
        return true
    }

    private func persistAnnotations(_ items: [ReaderAnnotation], at index: Int, preferredColor: String? = nil, removed: ReaderRemovedNote? = nil) -> Bool {
        // Commit before updating the UI, so a failed disk write keeps the editor open.
        guard commitReadingGraph(bookID:books[index].id,refresh:false,{ graph in
            graph.replaceAnnotations(items)
            if let removed { graph.removals.append(removed) }
        }) else { return false }
        if let removed { noteUndoID = removed.id }
        refreshAnnotations(preferredColor:preferredColor)
        return true
    }

    func refreshAnnotations(preferredColor: String? = nil) {
        if let nativeBookReader {
            nativeBookReader.setAnnotations(currentAnnotations)
            return
        }
        guard supportsReflow else { return }
        do {
            let session = annotationSessionID.uuidString
            let values = try JSONSerialization.jsonObject(with:JSONEncoder().encode(pageAnnotations))
            webView.callAsyncJavaScript("reader.setAnnotations(items,session,color)",arguments:["items":values,"session":session,"color":preferredColor as Any? ?? NSNull()],in:nil,in:.page) { [weak self] result in
                if case .failure = result, self?.annotationSessionID.uuidString == session {
                    self?.error = "笔记已保存，标记显示未能刷新。请重新打开图书。"
                }
            }
        } catch { self.error = "笔记已保存，标记显示未能刷新。请重新打开图书。" }
    }
}

extension AnnotationColor {
    var swatch: Color {
        switch self {
        case .yellow: return Color(red:0.96,green:0.83,blue:0.37)
        case .green: return Color(red:0.55,green:0.81,blue:0.53)
        case .blue: return Color(red:0.52,green:0.74,blue:0.91)
        case .pink: return Color(red:0.94,green:0.64,blue:0.72)
        case .purple: return Color(red:0.76,green:0.64,blue:0.87)
        case .underline: return Color(red:0.85,green:0.45,blue:0.36)
        }
    }
}

struct ReaderAnnotationColors: View {
    @Binding var selection: AnnotationColor
    var body: some View {
        HStack(spacing:6) {
            ForEach(AnnotationColor.allCases) { color in
                Button { selection = color } label: {
                    ZStack {
                        if color == .underline {
                            Text("U").font(.system(size:22,design:.serif)).underline(color:color.swatch)
                        } else { Circle().fill(color.swatch).frame(width:28,height:28) }
                        if selection == color && color != .underline {
                            Image(systemName:"checkmark").font(.system(size:12,weight:.semibold)).foregroundStyle(.black.opacity(0.7))
                        }
                    }.frame(width:40,height:40)
                        .overlay(Circle().strokeBorder(selection == color ? Color.primary.opacity(0.45) : .clear,lineWidth:1.5))
                }.buttonStyle(.plain).accessibilityLabel(color.title)
                    .accessibilityAddTraits(selection == color ? .isSelected : [])
            }
        }
    }
}

struct ReaderNoteEditor: View {
    @ObservedObject var reader: ReaderModel
    let draft: ReaderAnnotationDraft
    @Environment(\.dismiss) private var dismiss
    @State private var annotation: ReaderAnnotation
    @State private var baseline: ReaderAnnotation
    @Environment(\.colorScheme) private var colorScheme
    @State private var saveError: String?
    @State private var recovered: Bool
    @State private var draftSaved = false
    @State private var saveStatus = "自动保存"
    @State private var finished = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    init(reader: ReaderModel, draft: ReaderAnnotationDraft) {
        self.reader = reader; self.draft = draft
        let saved = reader.textNoteDrafts.first { $0.bookID == draft.bookID && $0.id == draft.annotation.id }
            ?? reader.textNoteDrafts.first { $0.bookID == draft.bookID && draft.annotation.selectionLocator != nil && $0.annotation.selectionLocator == draft.annotation.selectionLocator && ($0.annotation.intent ?? .thought) == (draft.annotation.intent ?? .thought) && $0.annotation.responseToID == draft.annotation.responseToID }
        let value = reader.noteForEditing(draft.annotation,bookID:draft.bookID)
        _baseline = State(initialValue:value)
        _annotation = State(initialValue:value)
        _recovered = State(initialValue:saved != nil)
    }
    var body: some View {
        Group {
        #if os(iOS)
        mobileEditor
        #else
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Button("完成") { if keepDraft() { finished = true; dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("编辑笔记").font(.headline)
                Spacer()
                Text(saveStatus).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
            VStack(alignment:.leading,spacing:14) {
            if !annotation.quote.isEmpty { ScrollView {
                Text(annotation.quote).font(.callout).lineSpacing(4)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.leading,14)
                    .overlay(alignment:.leading) { RoundedRectangle(cornerRadius:2).fill(annotation.color.swatch).frame(width:3) }
            }.frame(maxHeight:100) }
            Text(annotation.chapter).font(.caption).foregroundStyle(.secondary)
            if recovered { Text("已恢复上次未完成的内容").font(.caption).foregroundStyle(.secondary) }
            TextField("名称（可选）",text:Binding(get:{ annotation.title ?? "" },set:{ annotation.title = $0 })).modifier(ReadingFieldSurface())
            Text("这条笔记就是图中的一个节点。").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment:.topLeading) {
                if annotation.note.isEmpty { Text("写下你的想法…").foregroundStyle(.secondary).padding(.horizontal,7).padding(.vertical,9).allowsHitTesting(false) }
                TextEditor(text:$annotation.note).font(.body).scrollContentBackground(.hidden)
                    .focused($focused).accessibilityLabel("笔记内容")
                    .frame(minHeight:150)
            }
            VStack(alignment:.leading,spacing:12) {
                VStack(alignment:.leading,spacing:18) {
                    connections
                    Button("在脉络中继续整理") { saveAndClose(openGraph:true) }.disabled(!canSave)
                }.padding(.top,12)
            }
            if let saveError { saveFailure(saveError) }
            }
            }
            HStack {
                Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if reader.currentAnnotations.contains(where: { $0.id == annotation.id && !$0.note.isEmpty }) {
                    Button("删除笔记",role:.destructive) {
                        if reader.removeAnnotationText(annotation.id,bookID:draft.bookID) { finished = true; dismiss() }
                        else { saveError = reader.error }
                    }.help("删除文字笔记，保留高亮标记")
                }
            }
        }.padding(24)
        #endif
        }
        #if os(macOS)
        .frame(width:520,height:680)
        #else
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        #endif
        .interactiveDismissDisabled((annotation != baseline || recovered) && !draftSaved && !finished)
        .task { focused = true }
        .task(id:annotation) {
            draftSaved = false
            if annotation != baseline || recovered { saveStatus = "正在保存…" }
            do { try await Task.sleep(for:.milliseconds(350)) } catch { return }
            if !Task.isCancelled { keepDraft() }
        }
        .onChange(of:scenePhase) { phase in if phase != .active { keepDraft() } }
        .onDisappear { if !finished { keepDraft() } }
    }
    private var canSave: Bool {
        !annotation.quote.isEmpty || !annotation.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !(annotation.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    private var connections: some View {
        VStack(alignment:.leading,spacing:18) {
            Divider()
            ReaderNoteConnections(reader:reader,item:$annotation,palette:.init(dark:colorScheme == .dark),through:reader.noteVisibilityProgress)
            ReaderRelatedNotes(reader:reader,item:annotation,through:reader.noteVisibilityProgress) { note in
                guard keepDraft() else { return }
                reader.pendingGraphNote = (draft.bookID,note.id)
                finished = true; dismiss()
            }
        }
    }
    #if os(iOS)
    private var mobileEditor: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Button("关闭") { if keepDraft() { finished = true; dismiss() } }.frame(minHeight:44)
                Spacer()
                Text("编辑笔记").font(.headline)
                Spacer()
                Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("note-save-status")
            }
            ScrollView {
            VStack(alignment:.leading,spacing:18) {
            if !annotation.quote.isEmpty {
                ScrollView {
                    Text(annotation.quote).font(.system(.body,design:.serif)).lineSpacing(5)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.leading,14)
                        .overlay(alignment:.leading) { RoundedRectangle(cornerRadius:2).fill(annotation.color.swatch).frame(width:3) }
                }.frame(maxHeight:110).padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
            }
            HStack {
                Label(annotation.chapter,systemImage:"book").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                }
            TextField("名称（可选）",text:Binding(get:{ annotation.title ?? "" },set:{ annotation.title = $0 })).modifier(ReadingFieldSurface())
            Text("这条笔记就是图中的一个节点。").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment:.topLeading) {
                if annotation.note.isEmpty {
                    Text("写下此刻的想法…")
                        .foregroundStyle(.secondary).padding(.horizontal,17).padding(.top,20).allowsHitTesting(false)
                }
                TextEditor(text:$annotation.note).font(.body).scrollContentBackground(.hidden).padding(12)
                    .focused($focused).accessibilityLabel("笔记内容")
            }.frame(minHeight:180,idealHeight:220,maxHeight:320).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18))
            if !annotation.quote.isEmpty { ReaderAnnotationColors(selection:$annotation.color).frame(maxWidth:.infinity) }
            VStack(alignment:.leading,spacing:12) {
                VStack(alignment:.leading,spacing:18) {
                    connections
                    Button("在脉络中继续整理") { saveAndClose(openGraph:true) }.disabled(!canSave)
                }.padding(.top,12)
            }
            if let saveError { saveFailure(saveError) }
            if reader.currentAnnotations.contains(where: { $0.id == annotation.id && !$0.note.isEmpty }) {
                Menu {
                    Button("删除文字，保留高亮",role:.destructive) {
                        if reader.removeAnnotationText(annotation.id,bookID:draft.bookID) { finished = true; dismiss() }
                        else { saveError = reader.error }
                    }
                } label: { Label("管理这条笔记",systemImage:"ellipsis.circle").font(.caption).frame(minHeight:44) }
            }
            }
            }.scrollDismissesKeyboard(.interactively)
        }.padding(24).background(Color(uiColor:.systemGroupedBackground)).tint(readingAccent)
    }
    #endif
    private func saveFailure(_ message: String) -> some View {
        HStack {
            Text(message).font(.caption).foregroundStyle(.red)
            Spacer(minLength:8)
            Button("重试") { keepDraft() }.frame(minWidth:44,minHeight:44).accessibilityLabel("重试自动保存")
        }
    }
    private func saveAndClose(openGraph: Bool = false) {
        guard keepDraft() else { return }
        if openGraph { reader.pendingGraphNote = (draft.bookID,annotation.id) }
        finished = true; dismiss()
    }
    @discardableResult private func keepDraft() -> Bool {
        guard !finished else { return true }
        guard !reader.isNoteRemoved(annotation.id,bookID:draft.bookID) else { return true }
        if annotation == baseline && !recovered && reader.books.first(where:{ $0.id == draft.bookID })?.annotations?.contains(where:{ $0.id == annotation.id }) == true {
            return true
        }
        if reader.autosaveGraphAnnotation(annotation,bookID:draft.bookID,relation:annotation.graphRelationDraft) {
            baseline = annotation; recovered = false; draftSaved = true; saveError = nil; saveStatus = "已自动保存"; return true
        }
        let message = reader.error ?? "笔记暂时未能保存。"
        do {
            try reader.keepTextDraft(annotation,bookID:draft.bookID); draftSaved = true; saveStatus = "已保留草稿"
            saveError = "自动保存未完成，内容已保留为本机草稿。\(message)"; return true
        } catch { draftSaved = false; saveError = "自动保存失败，请保留当前页面并重试：\(error.localizedDescription)"; return false }
    }
}

/// Shared by the Mac sidebar and the iPhone/iPad navigation sheet.
struct ReaderAnnotationsList: View {
    @ObservedObject var reader: ReaderModel
    var navigate: (String) -> Void
    @State private var filter = ""
    @State private var notesOnly = false
    @State private var draft: ReaderAnnotationDraft?
    @State private var pageNotesTab = false
    @State private var recovery = false
    private var items: [ReaderAnnotation] {
        reader.currentAnnotations.filter {
            (!notesOnly || !$0.note.isEmpty) && (filter.isEmpty || $0.quote.localizedCaseInsensitiveContains(filter) || $0.note.localizedCaseInsensitiveContains(filter) || $0.chapter.localizedCaseInsensitiveContains(filter))
        }
    }
    private var emptyInstructions: String {
        #if os(macOS)
        return "选中文字后点击右键，选择颜色或添加笔记。\n点按高亮文字可以再次编辑。"
        #else
        return "选中文字，选择颜色或添加笔记。\n点按高亮文字可以再次编辑。"
        #endif
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("笔记类型",selection:$pageNotesTab) {
                Text("文字标记").tag(false)
                Text("书页手写\(reader.currentPageNotes.isEmpty ? "" : " (\(reader.currentPageNotes.count))")").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if reader.noteDraftCount > 0 || !reader.removedNotes.isEmpty {
                Button { recovery = true } label: {
                    Label("草稿 \(reader.noteDraftCount) · 最近删除 \(reader.removedNotes.count)",systemImage:"clock.arrow.circlepath")
                        .font(.callout).frame(minHeight:32)
                }.buttonStyle(.plain)
            }
            if pageNotesTab {
                ReaderPageNotesList(reader:reader,navigate:navigate)
            } else {
                TextField("搜索高亮与笔记",text:$filter).textFieldStyle(.roundedBorder).accessibilityLabel("搜索高亮与笔记")
                Toggle("只看文字笔记",isOn:$notesOnly).font(.callout)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        if items.isEmpty {
                            VStack(alignment:.leading,spacing:8) {
                                Image(systemName:"highlighter").font(.title2)
                                Text(reader.currentAnnotations.isEmpty ? "留下阅读时的想法" : "没有匹配的笔记").font(.headline)
                                Text(reader.currentAnnotations.isEmpty ? emptyInstructions : "试试其他关键词，或关闭筛选。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.padding(.vertical,24)
                        }
                        ForEach(items) { item in
                            VStack(alignment:.leading,spacing:10) {
                                HStack(alignment:.firstTextBaseline) {
                                    Text(item.chapter).lineLimit(1)
                                    Spacer(minLength:4)
                                    Text("\(Int(item.progress*100))%").monospacedDigit()
                                    Menu {
                                        Button(item.note.isEmpty ? "添加笔记" : "编辑笔记") { edit(item) }
                                        ForEach(AnnotationColor.allCases) { color in
                                            Button(color.title) {
                                                if let id = reader.currentID { var changed = item; changed.color = color; reader.saveAnnotation(changed,bookID:id) }
                                            }
                                        }
                                        Button("移除高亮与笔记",role:.destructive) { if let id = reader.currentID { reader.removeAnnotation(item.id,bookID:id) } }
                                    } label: { Image(systemName:"ellipsis").frame(width:30,height:30) }
                                        .accessibilityLabel("标记选项")
                                }.font(.caption).foregroundStyle(.secondary)
                                Button { navigate(item.readingLocator) } label: {
                                    Text(item.quote).font(.callout).lineLimit(5).multilineTextAlignment(.leading)
                                        .frame(maxWidth:.infinity,alignment:.leading).padding(.leading,12)
                                        .overlay(alignment:.leading) { RoundedRectangle(cornerRadius:2).fill(item.color.swatch).frame(width:3) }
                                }.buttonStyle(.plain).accessibilityLabel("\(item.color.title)标记，\(item.quote)").accessibilityHint("回到原文")
                                if !item.note.isEmpty {
                                    Button { edit(item) } label: {
                                        Label { Text(item.note).lineLimit(4).multilineTextAlignment(.leading) } icon: { Image(systemName:"note.text") }
                                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                                    }.buttonStyle(.plain).accessibilityHint("编辑笔记")
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
        }.sheet(item:$draft,onDismiss:reader.finishQuickNotePresentation) { ReaderNoteEditor(reader:reader,draft:$0) }
        .sheet(isPresented:$recovery) { ReaderNoteRecoveryView(reader:reader) }
    }
    private func edit(_ annotation: ReaderAnnotation) {
        if let bookID = reader.currentID { draft = ReaderAnnotationDraft(bookID:bookID,annotation:annotation) }
    }
}

#if os(macOS)
/// Observe clicks without intercepting WebKit's drag selection or context menu.
final class ReaderAnnotationInput {
    private weak var reader: ReaderModel?
    private weak var view: WKWebView?
    private var monitor: Any?
    private var start: (NSPoint,TimeInterval)?
    init(reader: ReaderModel) { self.reader = reader }
    func attach(to view: WKWebView) {
        detach(); self.view = view
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp,.keyDown]) { [weak self] event in
            guard let self, let view = self.view, event.window === view.window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { view.evaluateJavaScript("reader.dismissAnnotations()",completionHandler:nil) }
                return event
            }
            let point = view.convert(event.locationInWindow,from:nil)
            guard view.bounds.contains(point) else { self.start = nil; return event }
            if event.type == .leftMouseDown { self.start = (point,event.timestamp); return event }
            guard let start = self.start, event.timestamp-start.1 < 0.5,
                  hypot(point.x-start.0.x,point.y-start.0.y) < 5 else { self.start = nil; return event }
            self.start = nil
            let y = view.isFlipped ? point.y : view.bounds.height-point.y
            let session = self.reader?.annotationSessionID
            DispatchQueue.main.asyncAfter(deadline:.now()+0.04) { [weak self,weak view] in
                guard self?.reader?.annotationSessionID == session, self?.reader?.currentID != nil else { return }
                view?.callAsyncJavaScript("reader.annotationTap(x,y)",arguments:["x":point.x,"y":y],in:nil,in:.page,completionHandler:nil)
            }
            return event
        }
    }
    func detach() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; view = nil; start = nil }
    deinit { detach() }
}
#endif

extension ReaderModel {
    func performNativeSelectionAction(_ action: String, selection: ReaderAnnotation, bookID: UUID, color: AnnotationColor? = nil) {
        guard currentID == bookID, !loading else { return }
        var item = selection
        if let color { item.color = color }
        clearNativeSelection()
        performSelectionAction(action,selection:item,bookID:bookID)
    }

    #if os(iOS)
    func nativeSelectionMenu(for selection: ReaderAnnotation) -> [UIMenuElement] {
        guard let bookID = currentID, !loading else { return [] }
        let session = sessionID
        let existing = currentAnnotations.contains { $0.id == selection.id }
        return ReaderSelectionMenu.actions(existingColor:existing ? selection.color : nil,hasNote:!selection.note.isEmpty,includeEntity:true) {
            [weak self] action,color in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID == session else { return }
                self.performNativeSelectionAction(action,selection:selection,bookID:bookID,color:color)
            }
        }
    }
    #endif
}

#if os(macOS)
struct ReaderNativeSelectionTools: View {
    @ObservedObject var reader: ReaderModel
    let selection: ReaderAnnotation
    let bookID: UUID

    private func perform(_ action: String, color: AnnotationColor? = nil) {
        reader.performNativeSelectionAction(action,selection:selection,bookID:bookID,color:color)
    }

    var body: some View {
        ViewThatFits {
            HStack(spacing:12) {
                colors
                Button(selection.note.isEmpty ? "写笔记" : "编辑笔记",systemImage:"note.text") { perform("annotationEdit") }
                Button("添加节点",systemImage:"plus.circle") { perform("annotationEntity") }
                Button("问 AI",systemImage:"bubble.left.and.bubble.right") { perform("annotationDiscuss") }
                Button("翻译",systemImage:"translate") { perform("annotationTranslate") }
                more
            }
            HStack(spacing:12) {
                colors
                Menu("选文操作",systemImage:"ellipsis.circle") {
                    Button(selection.note.isEmpty ? "写笔记" : "编辑笔记",systemImage:"note.text") { perform("annotationEdit") }
                    Button("添加节点",systemImage:"plus.circle") { perform("annotationEntity") }
                    Button("问 AI",systemImage:"bubble.left.and.bubble.right") { perform("annotationDiscuss") }
                    Button("翻译",systemImage:"translate") { perform("annotationTranslate") }
                    secondary
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal,12).padding(.vertical,9)
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
        .padding(6)
        .accessibilityIdentifier("reader-native-selection-tools")
    }

    private var colors: some View {
        Menu("高亮",systemImage:"highlighter") {
            ForEach(AnnotationColor.allCases) { color in
                Button(color.title) { perform("annotationChange",color:color) }
            }
        }
    }

    private var more: some View { Menu("更多",systemImage:"ellipsis.circle") { secondary }.labelStyle(.iconOnly) }

    @ViewBuilder private var secondary: some View {
        Button("拷贝",systemImage:"doc.on.doc") {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.quote,forType:.string)
            #else
            UIPasteboard.general.string = selection.quote
            #endif
            reader.clearNativeSelection()
        }
        if reader.currentAnnotations.contains(where:{ $0.id == selection.id }) {
            Button("移除标记",systemImage:"trash",role:.destructive) { perform("annotationRemove") }
        }
        Button("收起选文工具",systemImage:"xmark") { reader.clearNativeSelection() }
    }
}
#endif
