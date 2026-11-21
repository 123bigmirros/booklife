import XCTest
import Darwin
@testable import BookSlideTerminal

final class TerminalAppearanceTests: XCTestCase {
    override func setUp() { setlocale(LC_ALL,"en_US.UTF-8") }
    func testLongChineseChapterNeverHidesProgress() {
        for columns in [22,30,46,76,100,156] {
            let text = TerminalTypography.joined(String(repeating:"很长的章节名称",count:20),right:"42% · 滚动",columns:columns)
            XCTAssertEqual(TextLayout.width(TerminalTypography.abbreviated(text,columns:columns)),columns)
            XCTAssertTrue(text.hasSuffix("42% · 滚动"))
            XCTAssertTrue(text.contains("…"))
        }
    }
    func testTruncationPreservesGraphemesAndRejectsTerminalEscapes() {
        XCTAssertEqual(TerminalTypography.abbreviated("  ›  章节     ",columns:24),"  ›  章节     ")
        let text = "中文 e\u{301} 阅读\u{1B}[2J"
        for columns in 1...20 {
            let value = TerminalTypography.abbreviated(text,columns:columns)
            XCTAssertLessThanOrEqual(TextLayout.width(value),columns)
            XCTAssertFalse(value.contains("\u{1B}"))
            XCTAssertFalse(value.hasPrefix("\u{301}"))
        }
    }
    func testAllWidthsKeepMarginsWithoutHidingSelectionAtEdges() {
        for columns in [24,32,80,120,180] {
            for style in TerminalWidth.allCases {
                XCTAssertLessThanOrEqual(style.columns(in:columns),columns-2)
            }
        }
        for count in [1,3,40] {
            for capacity in [2,5,16] {
                for selection in 0..<count {
                    let start = TerminalTypography.windowStart(selection:selection,count:count,capacity:capacity)
                    XCTAssertTrue((start..<min(count,start+capacity)).contains(selection))
                }
            }
        }
    }
}
