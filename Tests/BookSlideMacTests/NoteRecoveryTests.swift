import XCTest
import BookSlideCore
@testable import BookSlideMac

@MainActor
final class NoteRecoveryTests: XCTestCase {
    private func fixture(_ root: URL) -> (ReaderModel, UUID, ReaderAnnotation) {
        let reader = ReaderModel(directory:root,loadExternalSources:false), id = UUID()
        let item = ReaderAnnotation(id:UUID().uuidString.lowercased(),cfi:"epubcfi(/6/2!/4/2/1:0)",quote:"原文",chapter:"一",progress:0.1,note:"原想法")
        reader.books = [LibraryBook(id:id,title:"测试",author:"",filename:"",annotations:[item])]
        reader.currentID = id; reader.save()
        return (reader,id,item)
    }
    func testDeletionIsRecoverableAfterRestartAndCannotOverwriteANewNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (reader,bookID,item) = fixture(root)
        XCTAssertTrue(reader.removeAnnotationText(item.id,bookID:bookID))
        XCTAssertEqual(reader.currentAnnotations.first?.note,"")
        XCTAssertEqual(reader.currentAnnotations.first?.color,item.color)
        let removedID = try XCTUnwrap(reader.noteUndoID)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.removedNotes.count,1)
        var newer = item; newer.note = "刚写的新内容"
        XCTAssertTrue(reopened.saveAnnotation(newer,bookID:bookID))
        XCTAssertFalse(reopened.restoreRemovedNote(removedID))
        XCTAssertEqual(reopened.currentAnnotations.first?.note,newer.note)
        newer.note = ""; XCTAssertTrue(reopened.saveAnnotation(newer,bookID:bookID))
        XCTAssertTrue(reopened.restoreRemovedNote(removedID))
        XCTAssertEqual(reopened.currentAnnotations.first?.note,item.note)
        XCTAssertTrue(reopened.removedNotes.isEmpty)
        XCTAssertTrue(reopened.removeAnnotation(item.id,bookID:bookID))
        XCTAssertTrue(reopened.currentAnnotations.isEmpty)
        XCTAssertTrue(reopened.restoreRemovedNote(try XCTUnwrap(reopened.noteUndoID)))
        XCTAssertEqual(reopened.currentAnnotations.first?.note,item.note)
    }
    func testDraftRecoveryAndCommitDoNotResurrectFinishedDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (reader,bookID,item) = fixture(root)
        var draft = item; draft.note = "打到一半的内容"
        try reader.keepTextDraft(draft,bookID:bookID)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        reopened.loadNoteDrafts(bookID:bookID)
        XCTAssertEqual(reopened.textNoteDrafts.first?.annotation.note,draft.note)
        XCTAssertTrue(reopened.saveAnnotation(draft,bookID:bookID))
        XCTAssertEqual(reopened.noteDraftCount,0)
        XCTAssertTrue(try reopened.noteDraftStore.textDrafts(bookID:bookID).isEmpty)
        // A failed cleanup must not offer an older draft over the committed note.
        var stale = ReaderTextNoteDraft(bookID:bookID,annotation:draft)
        stale.updatedAt = Date.distantPast
        try reopened.noteDraftStore.save(stale)
        reopened.loadNoteDrafts(bookID:bookID)
        XCTAssertEqual(reopened.noteDraftCount,0)
    }
    func testFailedDeletionKeepsTheVisibleNoteAndDoesNotAdvertiseUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let (reader,bookID,item) = fixture(root)
        let moved = root.appendingPathExtension("saved")
        try FileManager.default.moveItem(at:root,to:moved)
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.moveItem(at:moved,to:root) }
        try Data("blocked directory".utf8).write(to:root)
        XCTAssertFalse(reader.removeAnnotation(item.id,bookID:bookID))
        XCTAssertEqual(reader.currentAnnotations,[item])
        XCTAssertTrue(reader.removedNotes.isEmpty)
        XCTAssertNil(reader.noteUndoID)
    }
}
