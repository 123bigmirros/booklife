import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

#if os(iOS)
/// The graph and its inspector are the single home for chapters and notes.
struct ReaderNotesScene: View {
    @ObservedObject var reader: ReaderModel
    var body: some View {
        Group {
            if reader.currentID != nil {
                BookNotesWorkspace(reader:reader) { reader.showNoteGraph = false }
                    .id(reader.currentID)
            }
        }
        .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
        .alert("无法完成操作",isPresented:Binding(get:{ reader.error != nil },set:{ if !$0 { reader.error = nil } })) {
            Button("好") { reader.error = nil }
        } message: { Text(reader.error ?? "") }
        .onDisappear { reader.annotationDraft = nil; reader.graphNoteID = nil }
    }
}
#endif

struct BookStructureSheet: View {
    @ObservedObject var reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        BookNotesWorkspace(reader:reader) { dismiss() }
            .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
            #if os(macOS)
            .frame(minWidth:1000,idealWidth:1400,minHeight:680,idealHeight:940)
            #endif
            .onDisappear { reader.annotationDraft = nil; reader.graphNoteID = nil }
    }
}
