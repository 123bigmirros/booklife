import XCTest
@testable import BookSlideCore

final class LibraryIndexStoreTests: XCTestCase {
    func testCorruptOrMissingPrimaryRecoversLastReadableSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryIndexStore(directory:root)
        XCTAssertNil(try store.load([String].self))
        try store.save(["book and bookmark"])
        try store.save(["book and bookmark", "new book"])
        try Data("corrupted".utf8).write(to:root.appendingPathComponent("library.json"))
        let restored = try XCTUnwrap(store.load([String].self))
        XCTAssertTrue(restored.recovered)
        XCTAssertEqual(restored.value,["book and bookmark"])
        try store.save(restored.value)
        XCTAssertFalse(try XCTUnwrap(store.load([String].self)).recovered)
        try FileManager.default.removeItem(at:root.appendingPathComponent("library.json"))
        XCTAssertEqual(try store.load([String].self)?.value,["book and bookmark"])
    }
    func testUnreadablePrimaryWithoutBackupDoesNotBecomeAnEmptyLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = root.appendingPathComponent("library.json")
        try Data("corrupted".utf8).write(to:url)
        XCTAssertThrowsError(try LibraryIndexStore(directory:root).load([String].self))
        XCTAssertEqual(try String(contentsOf:url),"corrupted")
    }
}
