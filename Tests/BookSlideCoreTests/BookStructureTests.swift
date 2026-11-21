import XCTest
@testable import BookSlideCore

final class BookStructureTests: XCTestCase {
    private func entry(_ title: String, _ depth: Int, href: String = "") -> BookStructure.Entry {
        .init(title: title, href: href, depth: depth)
    }
    private var book: BookStructure {
        BookStructure(entries: [entry("上篇", 0), entry("第一章", 1), entry("概念", 2), entry("例子", 2),
                                entry("第二章", 1), entry("下篇", 0), entry("第一章", 1)])
    }
    func testRestoresParentsAndReadingOrderWithRepeatedTitlesAndDestinations() {
        let structure = book
        XCTAssertEqual(structure.roots, [0, 5])
        XCTAssertEqual(structure.nodes[0].children, [1, 4])
        XCTAssertEqual(structure.nodes[1].children, [2, 3])
        XCTAssertEqual(structure.nodes[0].descendantCount, 4)
        XCTAssertEqual(structure.ancestors(of: 3), [0, 1])
        XCTAssertEqual(Set(structure.nodes.map(\.id)).count, 7)
        XCTAssertEqual(structure.visible(collapsed: []), Array(0...6))
    }
    func testFoldsHideOnlyDescendantsAndKeepNestedFoldState() {
        XCTAssertEqual(book.visible(collapsed: [1]), [0, 1, 4, 5, 6])
        XCTAssertEqual(book.visible(collapsed: [0, 1]), [0, 5, 6])
        XCTAssertEqual(book.visible(collapsed: [0, 5]), [0, 5])
    }
    func testSearchKeepsAncestorsAcrossFoldsAndDuplicateHeadings() {
        XCTAssertEqual(book.visible(collapsed: [0, 1], query: "  例子\n"), [0, 1, 3])
        XCTAssertEqual(book.visible(collapsed: [], query: "第一章"), [0, 1, 5, 6])
        XCTAssertEqual(book.visible(collapsed: [], query: "missing"), [])
    }
    func testIrregularDepthsAttachToNearestAvailableParent() {
        let structure = BookStructure(entries: [entry("a", 3), entry("b", 9), entry("c", 5), entry("d", -2), entry("e", 0)])
        XCTAssertEqual(structure.roots, [0, 3, 4])
        XCTAssertEqual(structure.nodes[0].children, [1, 2])
        XCTAssertEqual(structure.nodes.map(\.depth), [0, 1, 1, 0, 0])
        XCTAssertEqual(structure.ancestors(of: 100), [])
    }
    func testUnevenBranchesNeverOverlapAndParentsAreCentered() {
        for collapsed: Set<Int> in [[], [0], [1], [0, 5]] {
            let ids = book.visible(collapsed: collapsed)
            let layout = book.layout(visible: ids)
            let positions = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
            for placement in layout.placements {
                XCTAssertGreaterThanOrEqual(placement.x, 0)
                XCTAssertGreaterThanOrEqual(placement.y, 0)
                XCTAssertLessThanOrEqual(placement.x + 220, layout.width)
                XCTAssertLessThanOrEqual(placement.y + 64, layout.height)
                let children = book.nodes[placement.id].children.compactMap { positions[$0] }
                if let first = children.first, let last = children.last { XCTAssertEqual(placement.y, (first.y + last.y) / 2) }
            }
            for level in Dictionary(grouping: layout.placements, by: \.x).values {
                let ordered = level.sorted { $0.y < $1.y }
                for pair in zip(ordered, ordered.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1.y - pair.0.y, 88) }
            }
        }
    }
    func testEmptyAndDeepNavigationProduceFiniteLayoutsWithoutRecursion() {
        let empty = BookStructure(entries: [])
        XCTAssertTrue(empty.layout(visible: []).placements.isEmpty)
        XCTAssertTrue(empty.layout(visible: []).rootY.isFinite)
        let deep = BookStructure(entries: (0..<2000).map { entry("\($0)", $0) })
        XCTAssertEqual(deep.nodes[0].descendantCount, 1999)
        XCTAssertEqual(deep.visible(collapsed: [0]), [0])
        let layout = deep.layout(visible: deep.visible(collapsed: []))
        XCTAssertEqual(layout.placements.count, 2000)
        XCTAssertTrue(layout.width.isFinite)
    }
}
