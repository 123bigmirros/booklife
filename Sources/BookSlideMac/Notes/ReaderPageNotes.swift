import SwiftUI
import WebKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

extension ReaderModel {
    var pageNoteStore: ReaderPageNoteStore { ReaderPageNoteStore(libraryDirectory:directory) }
    var currentPageNotes: [ReaderPageNote] { (currentBook?.pageNotes ?? []).sorted { $0.anchor.progress < $1.anchor.progress } }
    func pageNoteImage(_ note: ReaderPageNote) -> ReaderImage? {
        if let part=note.parts?.first { return pageInkPartImage(part) }
        return (try? pageNoteStore.image(note.assetID,name:"preview.png")).flatMap { ReaderImage(data:$0) }
    }
    func pageInkPartImage(_ part: ReaderInkPart) -> ReaderImage? {
        let a=part.anchor,b=part.bounds
        guard a.viewportWidth>0,a.viewportHeight>0 else { return nil }
        let rect=ReaderInkRect(x:b.x/a.viewportWidth,y:b.y/a.viewportHeight,width:b.width/a.viewportWidth,height:b.height/a.viewportHeight)
        return (try? pageNoteStore.croppedPreview(part.assetID,rect:rect)).flatMap { ReaderImage(data:$0) }
    }
    @discardableResult func savePageNote(_ note: ReaderPageNote, files: ReaderPageNoteFiles, bookID: UUID) -> Bool {
        #if os(iOS)
        return saveGroupedPageInk(note,files:files,bookID:bookID)
        #else
        guard bookID == currentID, let index = books.firstIndex(where: { $0.id == bookID }) else { return false }
        do {
            var changed = note
            changed.assetID = try pageNoteStore.save(files); changed.updatedAt = Date()
            var notes = books[index].graph.pageNotes
            if let existing = notes.firstIndex(where: { $0.id == changed.id }) { notes[existing] = changed }
            else { notes.append(changed) }
            guard commitReadingGraph(bookID:bookID,{ $0.replacePageNotes(notes) }) else { return false }
            try? discardNoteDraft(bookID:bookID,id:note.id,ink:true)
            return true
        } catch { self.error = "书页笔迹未能保存：\(error.localizedDescription)"; return false }
        #endif
    }
    @discardableResult func removePageNote(_ id: UUID) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == currentID }) else { return false }
        guard let note = books[index].pageNotes?.first(where: { $0.id == id }) else { return false }
        let removed = ReaderRemovedNote(pageNote:note)
        let notes = books[index].graph.pageNotes.filter { $0.id != id }
        guard commitReadingGraph(bookID:books[index].id,{ $0.replacePageNotes(notes); $0.removals.append(removed) }) else { return false }
        noteUndoID = removed.id
        if let bookID = currentID { try? discardNoteDraft(bookID:bookID,id:id,ink:true) }
        return true
    }
    func refreshPageNotes() {
        if let pdfBookReader {
            pdfBookReader.pageLayers.update(currentPageNotes,store:pageNoteStore)
            return
        }
        guard supportsReflow else { return }
        guard let values = try? JSONSerialization.jsonObject(with:JSONEncoder().encode(currentPageNotes)) else { return }
        let session = annotationSessionID.uuidString
        webView.callAsyncJavaScript("reader.setPageNotes(notes,session)",arguments:["notes":values,"session":session],in:nil,in:.page) { [weak self] result in
            if case .failure = result, self?.annotationSessionID.uuidString == session {
                self?.error = "书页笔迹已保存，显示未能刷新，请重新打开图书。"
            }
        }
    }
}

struct ReaderPageNoteDetail: View {
    @ObservedObject var reader: ReaderModel
    let note: ReaderPageNote
    var navigate: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    private var latest: ReaderPageNote { reader.currentPageNotes.first { $0.id == note.id } ?? note }
    var body: some View {
        VStack(spacing:16) {
            HStack {
                Text("书页手写").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            Text(note.anchor.chapter).font(.subheadline).foregroundStyle(.secondary)
            ScrollView([.vertical,.horizontal]) {
                VStack(spacing:20) {
                    ForEach(latest.inkParts) { part in
                        VStack(alignment:.leading,spacing:8) {
                            if latest.inkParts.count>1 { Text(part.anchor.chapter).font(.caption).foregroundStyle(.secondary) }
                            if let data=try? reader.pageNoteStore.image(part.assetID,name:"preview.png"),let image=ReaderImage(data:data) {
                                #if os(macOS)
                                Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:800)
                                #else
                                Image(uiImage:image).resizable().scaledToFit().frame(maxWidth:800)
                                #endif
                            } else { Text("原页暂时无法读取，批注记录仍保留。").padding() }
                            if latest.inkParts.count>1 {
                                Button("回到这处原文") {
                                    let locator=part.sources.first?.id ?? part.anchor.locator
                                    if let navigate { navigate(locator) } else { reader.go(locator) };dismiss()
                                }
                            }
                        }
                    }
                }
            }
            Text("保留书写时的原页。调整字号或窗口后，也能在这里查看笔迹。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("回到原文") { if let navigate { navigate(note.anchor.locator) } else { reader.go(note.anchor.locator) }; dismiss() }
                Spacer()
                #if os(iOS)
                Button("回原文书写",systemImage:"pencil.tip") { reader.resumePageHandwriting(latest); dismiss() }
                #endif
            }
        }.padding(20)
        .onChange(of:reader.currentPageNotes.map(\.id)) { ids in if !ids.contains(note.id) { dismiss() } }
        #if os(macOS)
        .frame(minWidth:620,idealWidth:820,minHeight:520,idealHeight:780)
        #endif
    }
}

struct ReaderPageNotesList: View {
    @ObservedObject var reader: ReaderModel
    let navigate: (String) -> Void
    @State private var query = ""
    @State private var selected: ReaderPageNote?
    private var items: [ReaderPageNote] {
        reader.currentPageNotes.filter { query.isEmpty || $0.anchor.chapter.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            TextField("搜索手写批注的章节",text:$query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:18) {
                    if items.isEmpty {
                        Label(reader.currentPageNotes.isEmpty ? "还没有书页手写" : "没有匹配的书页手写",systemImage:"pencil.tip.crop.circle").font(.headline).padding(.top,20)
                        Text(reader.currentPageNotes.isEmpty ? "在 iPad 阅读工具中选择铅笔，即可在书页上写字、圈画。手写只保存在书写的设备上，暂不同步到其他设备。" : "试试其他章节名称，或清空搜索。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(items) { note in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text(note.anchor.chapter).font(.caption).lineLimit(1)
                                Spacer()
                                Text("\(Int(note.anchor.progress*100))%").font(.caption).foregroundStyle(.secondary)
                                Menu {
                                    Button("查看原页") { selected = note }
                                    Button("回到原文") { navigate(note.anchor.locator) }
                                    Button("移除书页批注",role:.destructive) { reader.removePageNote(note.id) }
                                } label: { Image(systemName:"ellipsis").frame(width:30,height:30) }.accessibilityLabel("书页批注选项")
                            }
                            Button { selected = note } label: {
                                if let image = reader.pageNoteImage(note) {
                                    #if os(macOS)
                                    Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:.infinity).frame(maxHeight:240)
                                    #else
                                    Image(uiImage:image).resizable().scaledToFit().frame(maxWidth:.infinity).frame(maxHeight:280)
                                    #endif
                                } else { Label("查看书写时的原页",systemImage:"doc.richtext").frame(maxWidth:.infinity,minHeight:80) }
                            }.buttonStyle(.plain).accessibilityLabel("查看\(note.anchor.chapter)的书页手写")
                            Divider()
                        }
                    }
                }
            }
        }.sheet(item:$selected) { ReaderPageNoteDetail(reader:reader,note:$0,navigate:navigate) }
    }
}
