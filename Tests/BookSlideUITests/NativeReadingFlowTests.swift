import XCTest
import UIKit

final class PDFSelectionFlowTests: XCTestCase {
    func testOriginalPageSelectionPresentsOneMenuWithBookActions() {
        checkSelectionMenu(reflow:false)
    }

    func testReflowSelectionPresentsOneMenuWithBookActions() {
        checkSelectionMenu(reflow:true)
    }

    private func checkSelectionMenu(reflow: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        let pdf = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:612,height:792)).pdfData { context in
            context.beginPage()
            for y in stride(from:70,through:690,by:34) {
                ("Reading starts with a question about this page." as NSString).draw(at:CGPoint(x:55,y:y),
                    withAttributes:[.font:UIFont.systemFont(ofSize:20)])
            }
        }
        XCUIDevice.shared.orientation = .portrait
        app.launchEnvironment["BOOKSLIDE_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchEnvironment["BOOKSLIDE_UI_TEST_PDF"] = pdf.base64EncodedString()
        if reflow { app.launchEnvironment["BOOKSLIDE_UI_TEST_PDF_LAYOUT"] = "reflow" }
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["library-open-featured"]
        XCTAssertTrue(open.waitForExistence(timeout:15)); open.tap()
        let canvas = app.descendants(matching:.any).matching(identifier:reflow ? "pdf-reflow-text" : "pdf-reader").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:15))
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.32,dy:0.28)).press(forDuration:1.1)
        let discuss = app.menuItems["问 AI"]
        XCTAssertTrue(discuss.waitForExistence(timeout:6),app.debugDescription)
        XCTAssertTrue(app.menuItems["拷贝"].exists,app.debugDescription)
        XCTAssertEqual(app.menuItems.matching(NSPredicate(format:"label == %@", "翻译")).count,1,app.debugDescription)
        XCTAssertTrue(app.menuItems["写笔记"].isHittable,app.debugDescription)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"reader-native-selection-tools").firstMatch.exists)
        let image = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        image.name = reflow ? "PDF 文字重排选文菜单" : "PDF 原版选文菜单"
        image.lifetime = .keepAlways
        add(image)
        discuss.tap()
        XCTAssertTrue(app.textViews["讨论问题"].waitForExistence(timeout:8))
    }
}

final class NativeReadingFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["BOOKSLIDE_UI_TEST_LIBRARY"] = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let book = app.buttons["library-open-featured"]
        XCTAssertTrue(book.waitForExistence(timeout:15)); book.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:15))
        revealTools()
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func ready(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let condition = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            element.exists && element.isEnabled && element.isHittable
        },object:nil)
        let result = XCTWaiter.wait(for:[condition],timeout:timeout)
        if result != .completed {
            capture("未能操作的阅读控件")
            print("NATIVE_READER_FAILURE " + app.debugDescription)
        }
        XCTAssertEqual(result,.completed,"阅读控件应存在且可操作")
    }

    private func revealTools() {
        let menu = app.buttons["reader-menu"], reveal = app.buttons["reader-show-tools"]
        // Hidden SwiftUI controls can remain in XCTest's accessibility tree.
        // Use the visible page-position button to reveal them deliberately.
        let available = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            (menu.exists && menu.isEnabled) || (reveal.exists && reveal.isEnabled)
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[available],timeout:20),.completed)
        if reveal.exists && reveal.isEnabled { reveal.tap() }
        ready(menu,timeout:15)
    }

    private func openMenu() {
        revealTools(); app.buttons["reader-menu"].tap()
        ready(app.buttons["主题与排版"])
    }

    private func closePanel() {
        let close = app.buttons["reader-panel-close"]
        ready(close); close.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !close.exists },evaluatedWith:nil)],timeout:10)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    // Scene rotation and narrow-window rendering are covered by the hosted
    // GlassReaderTests and NotesExperienceTests, with actual viewport checks.
    func testRealFingerPageTurnsReverseAndSurviveBackgroundingAndRotation() {
        openMenu(); app.buttons["主题与排版"].tap()
        ready(app.buttons["翻页"]); app.buttons["翻页"].tap(); closePanel()
        let page = app.webViews.firstMatch, progress = app.buttons["reader-progress"]
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            wait(for:[expectation(for:NSPredicate { _,_ in
                let frame = self.app.windows.firstMatch.frame
                return (frame.width > frame.height) == (orientation == .landscapeLeft)
            },evaluatedWith:nil)],timeout:10)
            revealTools()
            let before = progress.label
            for _ in 0..<3 {
                page.swipeLeft()
                wait(for:[expectation(for:NSPredicate { _,_ in progress.exists && progress.label != before },evaluatedWith:nil)],timeout:10)
                let next = progress.label
                page.swipeRight()
                wait(for:[expectation(for:NSPredicate { _,_ in progress.exists && progress.label == before },evaluatedWith:nil)],timeout:10)
                XCTAssertNotEqual(next,before,"A real finger swipe must move the reading position exactly once")
            }
            XCUIDevice.shared.press(.home); app.activate()
            revealTools(); XCTAssertEqual(progress.label,before)
            capture("翻页-往返与后台恢复-\(orientation)")
        }
        openMenu(); app.buttons["主题与排版"].tap()
        ready(app.buttons["滚动"]); app.buttons["滚动"].tap(); closePanel()
        revealTools(); let before = progress.label
        page.swipeUp()
        wait(for:[expectation(for:NSPredicate { _,_ in progress.exists && progress.label != before },evaluatedWith:nil)],timeout:10)
        capture("滚动-真实手指跨页")
    }

    func testCornerControlsAppearanceInkAndProgress() {
        revealTools()
        let window = app.windows.firstMatch.frame
        let menu = app.buttons["reader-menu"], note = app.buttons["reader-add-section-note"]
        let ink = app.buttons["reader-ink-tools"], progress = app.buttons["reader-progress"]
        for button in [menu,note,ink,progress,app.buttons["reader-close-book"]] { ready(button) }
        XCTAssertLessThan(note.frame.maxX,progress.frame.minX)
        XCTAssertLessThan(progress.frame.maxX,menu.frame.minX)
        XCTAssertGreaterThan(menu.frame.midY,window.midY)
        XCTAssertEqual(progress.frame.midX,window.midX,accuracy:2)
        capture("原生阅读-页角工具")
        openMenu(); capture("原生阅读-阅读菜单")
        app.buttons["主题与排版"].tap()
        ready(app.buttons["夜间主题"]); capture("原生阅读-主题与排版"); app.buttons["夜间主题"].tap()
        closePanel(); capture("原生阅读-夜间")
        openMenu(); capture("原生阅读-夜间菜单"); app.buttons["主题与排版"].tap()
        ready(app.buttons["明亮主题"]); app.buttons["明亮主题"].tap()
        closePanel()
        revealTools(); app.buttons["reader-ink-tools"].tap()
        ready(app.buttons["reader-pencil-mode-pen"])
        app.buttons["reader-pencil-mode-pen"].tap()
        capture("原生阅读-按需手写工具")
        app.buttons["reader-pencil-mode-reading"].tap()
        app.buttons["收起 Pencil 工具"].tap()
        revealTools(); app.buttons["reader-progress"].tap()
        let slider = app.sliders["全书阅读进度"]
        ready(slider); slider.adjust(toNormalizedSliderPosition:0.55)
        revealTools()
        ready(app.buttons["reader-return-to-position"])
        app.buttons["reader-return-to-position"].tap()
        openMenu(); app.buttons["更多阅读选项"].tap()
        ready(app.buttons["阅读进度"]); app.buttons["阅读进度"].tap()
        ready(app.sliders["全书阅读进度"])
        ready(app.buttons["reader-panel-back"]); app.buttons["reader-panel-back"].tap()
        ready(app.buttons["主题与排版"]); closePanel()
        revealTools(); app.buttons["reader-close-book"].tap()
        XCTAssertTrue(app.navigationBars["书库"].waitForExistence(timeout:10) || app.buttons["library-open-featured"].exists)
    }

    func testMenuNoteAndGraphActionsOpenAfterDismissal() {
        openMenu(); app.buttons["随手记"].tap()
        let canvas = app.webViews["direct-graph-canvas"]
        let usesCanvas = canvas.waitForExistence(timeout:3)
        // Quick notes now focus the canvas's inline editor immediately.
        // Older native editor presentations still expose an explicit edit action.
        let editor = app.textViews[usesCanvas ? "节点文字" : "笔记内容"]
        if usesCanvas && !editor.waitForExistence(timeout:5) {
            let card = canvas.otherElements.matching(NSPredicate(format:"label BEGINSWITH %@", "展开的")).firstMatch; ready(card)
            card.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:32,dy:24)).press(forDuration:0.7)
            ready(app.buttons["编辑节点文字"]); app.buttons["编辑节点文字"].tap()
        }
        ready(editor); editor.typeText("A thought kept beside this page.\n")
        capture("原生阅读-菜单进入笔记")
        let close = app.buttons[usesCanvas ? "收起笔记，继续阅读" : "完成"]
        ready(close); close.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !close.exists },evaluatedWith:nil)],timeout:10)
        openMenu(); ready(app.buttons["全书脉络与笔记"]); app.buttons["全书脉络与笔记"].tap()
        ready(app.buttons[usesCanvas ? "查看整张结构图" : "添加笔记"])
        if usesCanvas {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","A thought kept beside this page.")).firstMatch.waitForExistence(timeout:10))
        } else {
            let search = app.textFields["reading-record-search"]
            ready(search); search.tap(); search.typeText("A thought")
            ready(editor)
            XCTAssertTrue((editor.value as? String)?.contains("A thought kept beside this page.") == true)
        }
        ready(close); close.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !close.exists },evaluatedWith:nil)],timeout:10)
        revealTools()
        XCTAssertTrue(app.buttons["reader-menu"].isHittable)
    }

    func testBookmarksAndSearchNavigateBackToTheReadingPage() {
        openMenu()
        app.buttons["添加书签"].tap()
        ready(app.buttons["移除书签"])
        app.buttons["目录与书签"].tap()
        ready(app.buttons["书签"]); app.buttons["书签"].tap()
        ready(app.buttons["移除当前位置的书签"])
        capture("原生阅读-已保存书签")
        closePanel()
        openMenu(); app.buttons["搜索书中内容"].tap()
        let field = app.textFields["输入词语或句子"]
        ready(field); field.tap(); field.typeText("阅读")
        let result = app.buttons.matching(identifier:"reader-search-result").firstMatch
        ready(result,timeout:15); capture("原生阅读-书中搜索")
        result.tap()
        revealTools()
        ready(app.buttons["reader-return-to-position"])
        app.buttons["reader-return-to-position"].tap()
        openMenu(); ready(app.buttons["移除书签"])
        app.buttons["移除书签"].tap(); ready(app.buttons["添加书签"])
        closePanel(); revealTools()
    }
}
