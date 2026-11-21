import XCTest
import UIKit

final class NotesFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["BOOKSLIDE_UI_TEST_LIBRARY"] = UUID().uuidString
        if name.hasSuffix("testOutsideTapClearsAIAnswerSelection]") {
            app.launchEnvironment["BOOKSLIDE_UI_TEST_DISCUSSION"] = "1"
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["library-open-featured"].waitForExistence(timeout:15))
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    private func openNodeActions(_ node: XCUIElement? = nil) {
        if let node {
            XCTAssertTrue(node.waitForExistence(timeout:5))
            node.press(forDuration:0.7)
        } else {
            // Native text fields own their selection gestures. Press the card header.
            let graph = app.webViews["direct-graph-canvas"]
            let card = graph.otherElements.matching(NSPredicate(format:"label BEGINSWITH %@", "展开的")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout:5))
            let heading = card.staticTexts.firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout:3))
            heading.press(forDuration:0.7)
        }
        let strip = app.descendants(matching:.any).matching(identifier:"canvas-node-actions").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["更多节点命令"].exists)
        XCTAssertFalse(app.buttons["整理分支"].exists)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openMapForGestureTest(expand: Bool = true, theme: String? = nil) -> XCUIElement {
        app.buttons["library-open-featured"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:15))
        openReaderMenu()
        if let theme {
            app.buttons["主题与排版"].tap()
            let option = app.buttons[theme + "主题"]
            XCTAssertTrue(option.waitForExistence(timeout:8))
            option.tap()
            app.buttons["reader-panel-close"].tap()
            openReaderMenu()
        }
        let entry=app.buttons["全书脉络与笔记"]
        XCTAssertTrue(entry.waitForExistence(timeout:10)); entry.tap()
        let graph=app.webViews["direct-graph-canvas"]
        XCTAssertTrue(graph.waitForExistence(timeout:15))
        if expand {
            let control=app.buttons["展开画布"]
            XCTAssertTrue(control.waitForExistence(timeout:5)); control.tap()
        }
        app.buttons["查看整张结构图"].tap()
        return graph
    }

    private func openReaderMenu() {
        let menu=app.buttons["reader-menu"], reveal=app.buttons["reader-show-tools"]
        wait(for:[expectation(for:NSPredicate { _,_ in
            menu.exists && menu.isEnabled && menu.isHittable || reveal.exists && reveal.isEnabled && reveal.isHittable
        },evaluatedWith:nil)],timeout:20)
        if !(menu.exists && menu.isEnabled && menu.isHittable), reveal.exists && reveal.isHittable { reveal.tap() }
        wait(for:[expectation(for:NSPredicate { _,_ in menu.exists && menu.isEnabled && menu.isHittable },evaluatedWith:nil)],timeout:10)
        menu.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
    }

    private func checkDiscussionTheme(_ theme: String) {
        let graph = openMapForGestureTest(expand:false,theme:theme)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in
            let frame = self.app.windows.firstMatch.frame
            return frame.width > frame.height && graph.exists
        },evaluatedWith:nil)],timeout:10)
        app.buttons["查看整张结构图"].tap()
        let root = graph.staticTexts["留一点时间，给阅读"]
        XCTAssertTrue(root.waitForExistence(timeout:8))
        root.tap()
        openNodeActions(root)
        app.buttons["AI 对话"].tap()
        let composer = app.textViews["讨论问题"]
        XCTAssertTrue(composer.waitForExistence(timeout:8))
        let context = app.buttons["本次讨论的上下文"]
        XCTAssertTrue(context.waitForExistence(timeout:5))
        context.tap()
        XCTAssertTrue(app.switches["带入已读正文摘录"].waitForExistence(timeout:5))
        capture("阅读主题-" + theme)
    }

    func testPaperDiscussionTheme() { checkDiscussionTheme("纸色") }
    func testLightDiscussionTheme() { checkDiscussionTheme("明亮") }
    func testNightDiscussionTheme() { checkDiscussionTheme("夜间") }

    func testTwoFingerPinchZoomsTheGraphInAndOut() {
        let graph = openMapForGestureTest()
        let chapter = graph.staticTexts["让时间慢下来"]
        XCTAssertTrue(chapter.waitForExistence(timeout:8))
        let initialWidth = chapter.frame.width
        capture("双指缩放-初始")
        // The full web view includes native floating controls. Keep both
        // fingers on a card so an outer corner cannot hit the zoom toolbar.
        chapter.pinch(withScale:1.6,velocity:1)
        wait(for:[expectation(for:NSPredicate { _,_ in chapter.frame.width > initialWidth * 1.25 },evaluatedWith:nil)],timeout:8)
        let enlargedWidth = chapter.frame.width
        capture("双指缩放-放大")
        chapter.pinch(withScale:0.6,velocity:-1)
        wait(for:[expectation(for:NSPredicate { _,_ in chapter.frame.width < enlargedWidth * 0.85 },evaluatedWith:nil)],timeout:8)
        capture("双指缩放-缩小")
    }

    func testRootAndChapterOpenSeparateAIReadingConversations() {
        let graph = openMapForGestureTest(expand:false)
        let root = graph.staticTexts["留一点时间，给阅读"]
        XCTAssertTrue(root.waitForExistence(timeout:8)); root.tap()
        let ai = app.buttons["AI 对话"]
        openNodeActions(root)
        capture("图书节点-操作清单")
        XCTAssertFalse(app.buttons["删除节点"].exists)
        XCTAssertTrue(ai.waitForExistence(timeout:5)); ai.tap()
        let composer = app.textViews["讨论问题"]
        XCTAssertTrue(composer.waitForExistence(timeout:8))
        let editor = app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        XCTAssertTrue(editor.exists,"Root AI opens through the original node editor")
        let page = app.webViews["reader-book-web"]
        XCTAssertTrue(page.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertGreaterThan(page.frame.height,200)
        XCTAssertFalse(page.frame.intersects(composer.frame),"The book stays beside or above the AI composer")
        XCTAssertFalse(app.buttons["串起已读内容的主线"].exists)
        XCTAssertFalse(app.buttons["discussion-send"].isEnabled)
        composer.tap()
        composer.typeText("What is a metaphor?")
        XCTAssertEqual(composer.value as? String,"What is a metaphor?")
        graph.buttons["完成节点编辑"].tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !editor.exists && !self.app.keyboards.firstMatch.exists },evaluatedWith:nil)],timeout:8)
        app.buttons["查看整张结构图"].tap()
        let chapter = graph.staticTexts["让时间慢下来"]
        XCTAssertTrue(chapter.waitForExistence(timeout:8)); chapter.tap()
        openNodeActions(chapter)
        capture("章节节点-操作清单")
        XCTAssertFalse(app.buttons["删除节点"].exists)
        XCTAssertTrue(ai.waitForExistence(timeout:5)); ai.tap()
        XCTAssertTrue(composer.waitForExistence(timeout:8))
        XCTAssertFalse(app.buttons["梳理本章的已读内容"].exists)
        XCTAssertFalse(app.buttons["discussion-send"].isEnabled)
        XCTAssertNotEqual(composer.value as? String,"What is a metaphor?")
        XCTAssertTrue(editor.exists,"Chapter AI opens through the same node editor")
    }

    func testOutsideTapClearsAIAnswerSelection() {
        let graph = openMapForGestureTest(expand:false)
        let root = graph.staticTexts["留一点时间，给阅读"]
        XCTAssertTrue(root.waitForExistence(timeout:8)); root.tap()
        let ai = app.buttons["AI 对话"]
        openNodeActions(root)
        XCTAssertTrue(ai.waitForExistence(timeout:5)); ai.tap()
        let editor = app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        let answer = editor.staticTexts["Reading starts with a question."]
        XCTAssertTrue(answer.waitForExistence(timeout:8),app.debugDescription)
        let copy = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","拷贝")).firstMatch
        let text = answer.coordinate(withNormalizedOffset:CGVector(dx:0.13,dy:0.5))
        let page = app.webViews["reader-book-web"]
        XCTAssertTrue(page.exists)
        text.press(forDuration:1.1)
        XCTAssertTrue(copy.waitForExistence(timeout:6),app.debugDescription)
        page.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout:5),"Tapping the book must dismiss the answer's text menu")
        XCTAssertTrue(editor.exists,"The conversation stays open while reading the book")
        text.press(forDuration:1.1)
        XCTAssertTrue(copy.waitForExistence(timeout:6),app.debugDescription)
        graph.coordinate(withNormalizedOffset:CGVector(dx:0.16,dy:0.63)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout:5),"Tapping blank canvas must dismiss the answer's text menu")
        XCTAssertTrue(editor.waitForNonExistence(timeout:5),"Tapping blank canvas must deselect the expanded AI node")
        XCTAssertFalse(graph.staticTexts["Reading starts with a question."].exists,"The response stays inside the conversation")
    }

    func testFingerDragMovesNoteToAnotherChapter() {
        let graph = openMapForGestureTest()
        let chapter=graph.staticTexts["让时间慢下来"]
        XCTAssertTrue(chapter.waitForExistence(timeout:8)); chapter.tap()
        let add=app.buttons["添加子节点"]
        openNodeActions(chapter)
        XCTAssertTrue(add.waitForExistence(timeout:5)); add.tap()
        let input=graph.textViews["节点文字"]
        XCTAssertTrue(input.waitForExistence(timeout:8)); input.typeText("拖动验证\n")
        app.buttons["查看整张结构图"].tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !input.exists },evaluatedWith:nil)],timeout:8)
        let source=graph.staticTexts.matching(identifier:"拖动验证").firstMatch, target=graph.staticTexts["在文字之间呼吸"]
        XCTAssertTrue(source.waitForExistence(timeout:8)); XCTAssertTrue(target.waitForExistence(timeout:8))
        capture("节点拖动-改挂前")
        source.press(forDuration:0.08,thenDragTo:target)
        let moved=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","已移动「拖动验证」")).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertGreaterThan(source.frame.minX,target.frame.minX)
        capture("节点拖动-改挂后")
    }

    func testMapCanPanWhileAddingAndDeleteABranchThenUndo() {
        let graph = openMapForGestureTest()
        let chapter = graph.staticTexts["让时间慢下来"]
        XCTAssertTrue(chapter.waitForExistence(timeout:8)); chapter.tap()
        let addChild = app.buttons["添加子节点"]
        openNodeActions(chapter)
        XCTAssertTrue(addChild.waitForExistence(timeout:5)); addChild.tap()
        let input = graph.textViews["节点文字"]
        XCTAssertTrue(input.waitForExistence(timeout:10),app.debugDescription)
        input.typeText("Editable branch")
        let before = input.frame
        capture("节点输入-拖动前")
        XCTAssertFalse(app.otherElements["graph-inline-editor"].exists,"A new node is edited on the canvas")
        let start = graph.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:0.15))
        start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:120,dy:55)))
        let parent = graph.staticTexts["Editable branch"]
        XCTAssertTrue(parent.waitForExistence(timeout:5),app.debugDescription)
        capture("节点输入-拖动后")
        XCTAssertGreaterThan(abs(parent.frame.midX-before.midX),60,"Dragging blank canvas must work while entering a new node; graph=\(graph.frame) before=\(before) after=\(parent.frame) \(app.debugDescription)")
        parent.tap()
        openNodeActions()
        let add = app.buttons["添加子节点"]
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(input.waitForExistence(timeout:5)); input.typeText("Child node\n")
        let child = graph.staticTexts["Child node"]
        XCTAssertTrue(child.waitForExistence(timeout:5))
        parent.tap()
        let remove = app.buttons["删除节点"]
        openNodeActions()
        XCTAssertTrue(remove.waitForExistence(timeout:5)); remove.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !parent.exists && !child.exists },evaluatedWith:nil)],timeout:8)
        app.buttons["撤销导图操作"].tap()
        XCTAssertTrue(parent.waitForExistence(timeout:8)); XCTAssertTrue(child.waitForExistence(timeout:8))
        parent.tap()
        let details = app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertLessThan(details.frame.width,graph.frame.width*0.55,"Content must leave the canvas available")
        XCTAssertLessThan(details.frame.height,graph.frame.height*0.55,"Content must not cover the map")
        let content = app.textViews["节点内容"]
        XCTAssertTrue(content.waitForExistence(timeout:5)); content.tap()
        XCTAssertEqual(content.value as? String,"Editable branch")
        content.typeText(String(repeating:"Long content remains inside this node. ",count:6))
        capture("节点内容-保留可拖动画布")
        app.buttons["完成节点编辑"].tap()
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            wait(for:[expectation(for:NSPredicate { _,_ in
                let window = self.app.windows.firstMatch.frame
                return (window.width > window.height) == (orientation == .landscapeLeft)
            },evaluatedWith:nil)],timeout:10)
            app.buttons["查看整张结构图"].tap()
            capture("节点编辑-增删撤销-\(orientation == .portrait ? "竖屏" : "横屏")")
        }
    }

    func testInsertionAndConnectionAreLocalToThePressedNode() {
        let graph = openMapForGestureTest()
        graph.coordinate(withNormalizedOffset:CGVector(dx:0.12,dy:0.38)).tap()
        XCTAssertFalse(app.buttons["添加节点"].exists)
        XCTAssertFalse(app.buttons["连接节点"].exists)
        capture("画布-顶部工具")
        openNodeActions(graph.staticTexts["让时间慢下来"])
        app.buttons["添加子节点"].tap()
        let input = graph.textViews["节点文字"]
        XCTAssertTrue(input.waitForExistence(timeout:5))
        input.typeText("我的阅读问题")
        capture("添加节点-直接输入")
        input.typeText("\n")
        app.buttons["查看整张结构图"].tap()
        let created = graph.staticTexts["我的阅读问题"]
        XCTAssertTrue(created.waitForExistence(timeout:8))
        openNodeActions(created)
        let strip = app.descendants(matching:.any).matching(identifier:"canvas-node-actions").firstMatch
        XCTAssertTrue(graph.frame.contains(strip.frame))
        XCTAssertFalse(strip.buttons["选择插入方式"].exists)
        for title in ["添加子节点","连接节点","编辑节点文字","AI 对话","删除节点"] {
            let button = strip.buttons[title]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width,44)
            XCTAssertGreaterThanOrEqual(button.frame.height,44)
        }
        let closeup = XCTAttachment(screenshot:strip.screenshot())
        closeup.name = "笔记节点-短命令"; closeup.lifetime = .keepAlways; self.add(closeup)
        capture("添加节点-节点旁的子节点入口")
        app.buttons["添加子节点"].tap()
        XCTAssertTrue(input.waitForExistence(timeout:5))
        input.typeText("先记下一个例子\n")
        app.buttons["查看整张结构图"].tap()
        let child = graph.staticTexts["先记下一个例子"]
        XCTAssertTrue(child.waitForExistence(timeout:8))
        XCTAssertGreaterThan(child.frame.minX,created.frame.minX)
        capture("添加节点-父子分支")
    }

    func testTapOpensContentAndLongPressOffersCompactCommands() {
        let graph = openMapForGestureTest()
        let chapter = graph.staticTexts["让时间慢下来"]
        XCTAssertTrue(chapter.waitForExistence(timeout:8)); chapter.tap()
        openNodeActions(chapter)
        app.buttons["添加子节点"].tap()
        let input = graph.textViews["节点文字"]
        XCTAssertTrue(input.waitForExistence(timeout:8)); input.typeText("先理解，再记录。\n")
        app.buttons["查看整张结构图"].tap()
        let node = graph.staticTexts["先理解，再记录。"]
        XCTAssertTrue(node.waitForExistence(timeout:8)); node.tap()
        let details = app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout:5),"Tapping the node opens its content")
        let expandedCard=graph.otherElements["展开的节点：先理解，再记录。"]
        XCTAssertTrue(expandedCard.waitForExistence(timeout:5))
        XCTAssertEqual(app.textViews["节点内容"].value as? String,"先理解，再记录。")
        XCTAssertFalse(node.exists,"The editor replaces the collapsed text")
        XCTAssertTrue(expandedCard.frame.insetBy(dx:-1,dy:-1).contains(details.frame),"The editor must stay inside the original expanded node")
        let rename = app.buttons["编辑节点文字"]
        let ai = app.buttons["AI 对话"]
        XCTAssertFalse(app.buttons["节点操作"].exists)
        openNodeActions()
        for control in [rename,ai,app.buttons["添加子节点"],app.buttons["删除节点"]] { XCTAssertTrue(control.isHittable) }
        XCTAssertFalse(app.buttons["选择插入方式"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists,"Opening content must not start typing automatically")
        capture("基本节点操作-竖屏")
        rename.tap()
        XCTAssertTrue(input.waitForExistence(timeout:8)); input.typeText("把读到的内容写成自己的理解。\n")
        app.buttons["查看整张结构图"].tap()
        let renamed = graph.staticTexts["把读到的内容写成自己的理解。"]
        XCTAssertTrue(renamed.waitForExistence(timeout:8)); renamed.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height },evaluatedWith:nil)],timeout:10)
        app.buttons["完成节点编辑"].tap()
        app.buttons["查看整张结构图"].tap(); renamed.tap()
        openNodeActions()
        XCTAssertTrue(rename.isHittable); capture("基本节点操作-横屏")
        app.buttons["添加子节点"].tap()
        XCTAssertTrue(input.waitForExistence(timeout:8)); input.typeText("让问题把阅读连起来。\n")
        app.buttons["查看整张结构图"].tap()
        let other = graph.staticTexts["让问题把阅读连起来。"]
        XCTAssertTrue(other.waitForExistence(timeout:8)); openNodeActions(other)
        let connect=app.buttons["连接节点"]
        XCTAssertTrue(connect.waitForExistence(timeout:5));connect.tap()
        let cancel=graph.buttons["取消连线"]
        XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.tap()
        openNodeActions(other)
        XCTAssertTrue(ai.waitForExistence(timeout:5)); ai.tap()
        XCTAssertTrue(app.textViews["讨论问题"].waitForExistence(timeout:8),app.debugDescription)
        capture("节点-AI对话")
    }

    func testTextStillScrollsAfterReturningFromNotes() {
        app.buttons["library-open-featured"].tap()
        XCTAssertTrue(app.buttons["reader-close-book"].waitForExistence(timeout:15))
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout:15))
        let menu = app.buttons["reader-menu"]
        if !menu.isHittable { page.tap() }
        wait(for:[expectation(for:NSPredicate { _,_ in menu.isHittable && menu.isEnabled },evaluatedWith:nil)],timeout:10)
        menu.tap()
        let appearance = app.buttons["主题与排版"]
        XCTAssertTrue(appearance.waitForExistence(timeout:5)); appearance.tap()
        let scroll = app.buttons["滚动"]
        XCTAssertTrue(scroll.waitForExistence(timeout:5)); scroll.tap()
        app.buttons["reader-panel-close"].tap()
        let notes = app.buttons["reader-add-section-note"]
        if !notes.isHittable { page.tap() }
        XCTAssertTrue(notes.waitForExistence(timeout:5)); notes.tap()
        let editor = app.textViews["节点文字"]
        XCTAssertTrue(editor.waitForExistence(timeout:10)); editor.typeText("返回后继续阅读。\n")
        let close = app.buttons["收起笔记，继续阅读"]
        XCTAssertTrue(close.waitForExistence(timeout:10)); close.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !close.exists },evaluatedWith:nil)],timeout:10)
        let texts = page.staticTexts.allElementsBoundByIndex.filter { $0.frame.intersects(page.frame) && $0.frame.height > 15 && !$0.label.isEmpty }
        let paragraph = texts.max { $0.label.count < $1.label.count }
        XCTAssertNotNil(paragraph,app.debugDescription)
        guard let paragraph else { return }
        let before = paragraph.frame
        capture("返回笔记后-滑动前")
        page.swipeUp(velocity:.slow)
        wait(for:[expectation(for:NSPredicate { _,_ in abs(paragraph.frame.minY-before.minY) > 30 },evaluatedWith:nil)],timeout:8)
        capture("返回笔记后-滑动后")
        XCTAssertGreaterThan(abs(paragraph.frame.minY-before.minY),30,"A real finger swipe after closing notes must move the text")
    }

    func testScrollingTextUsesTheScreenBottomInBothIPadOrientations() {
        app.buttons["library-open-featured"].tap()
        XCTAssertTrue(app.buttons["reader-close-book"].waitForExistence(timeout:15))
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout:15))
        let menu = app.buttons["reader-menu"]
        if !menu.isHittable { page.tap() }
        wait(for:[expectation(for:NSPredicate { _,_ in menu.isHittable && menu.isEnabled },evaluatedWith:nil)],timeout:10)
        XCTAssertTrue(menu.isHittable,app.debugDescription); menu.tap()
        let appearance = app.buttons["主题与排版"]
        XCTAssertTrue(appearance.waitForExistence(timeout:5),app.debugDescription); appearance.tap()
        let scroll = app.buttons["滚动"]
        XCTAssertTrue(scroll.waitForExistence(timeout:5)); scroll.tap()
        app.buttons["reader-panel-close"].tap()
        for orientation in [UIDeviceOrientation.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            wait(for:[expectation(for:NSPredicate { _,_ in
                let window = self.app.windows.firstMatch.frame
                return (window.width > window.height) == landscape &&
                    abs(page.frame.maxY-window.maxY) < 1 && abs(page.frame.minY-window.minY) < 1
            },evaluatedWith:nil)],timeout:15)
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(page.frame.minY,window.minY,accuracy:1)
            XCTAssertEqual(page.frame.maxY,window.maxY,accuracy:1)
            page.swipeUp(velocity:.slow)
            capture("连续滚动-屏幕底边-\(landscape ? "横屏" : "竖屏")")
            page.swipeDown(velocity:.slow)
        }
    }

    private func openNotesAndWrite(_ text: String) {
        app.buttons["library-open-featured"].tap()
        let menu = app.buttons["reader-menu"], reveal = app.buttons["reader-show-tools"]
        wait(for:[expectation(for:NSPredicate { _,_ in
            menu.exists && menu.isEnabled && menu.isHittable || reveal.exists && reveal.isEnabled && reveal.isHittable
        },evaluatedWith:nil)],timeout:20)
        if reveal.exists && reveal.isHittable { reveal.tap() }
        let add = app.buttons["reader-add-section-note"]
        XCTAssertTrue(add.waitForExistence(timeout:10)); add.tap()
        let editor = app.textViews["节点文字"]
        XCTAssertTrue(editor.waitForExistence(timeout:10),app.debugDescription)
        editor.typeText(text+"\n")
        app.buttons["查看整张结构图"].tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !editor.exists },evaluatedWith:nil)],timeout:8)
        XCTAssertTrue(app.webViews["direct-graph-canvas"].staticTexts[text].waitForExistence(timeout:10))
    }




    func testWriteReturnSearchAndReopenWithoutLosingTheNote() {
        let text = "把读到的内容写成自己的理解。"
        openNotesAndWrite(text)
        capture("笔记-输入与保存")
        func searchSavedNode() {
            let search = app.buttons["搜索全书脉络"]
            XCTAssertTrue(search.waitForExistence(timeout:15)); search.tap()
            let field = app.textFields["reading-record-search"]
            XCTAssertTrue(field.waitForExistence(timeout:5)); field.tap(); field.typeText("自己的理解")
            XCTAssertTrue(field.isHittable,"Typing must keep the search field visible and focused")
            let result = app.buttons.matching(identifier:"companion-search-result").firstMatch
            XCTAssertTrue(result.waitForExistence(timeout:5)); capture("笔记-搜索结果"); result.tap()
            let node = app.webViews["direct-graph-canvas"].staticTexts[text]
            XCTAssertTrue(node.waitForExistence(timeout:10),"Search must return to the saved node on the map")
        }
        searchSavedNode()
        let close = app.buttons["收起笔记，继续阅读"]
        XCTAssertTrue(close.isHittable); close.tap()
        app.terminate(); app.launch()
        let notes = app.buttons["脉络与笔记"]
        XCTAssertTrue(notes.waitForExistence(timeout:15)); notes.tap()
        searchSavedNode()
    }


    func testNoteControlsRemainUsableWithPortraitKeyboardAndRotation() {
        let text = "旋转前的笔记。"
        openNotesAndWrite(text)
        let graph = app.webViews["direct-graph-canvas"]
        let node = graph.staticTexts[text]
        XCTAssertTrue(node.waitForExistence(timeout:10)); node.tap()
        let rename = app.buttons["编辑节点文字"]
        openNodeActions()
        XCTAssertTrue(rename.waitForExistence(timeout:5)); rename.tap()
        let editor = app.textViews["节点文字"]
        XCTAssertTrue(editor.waitForExistence(timeout:5)); editor.typeText("旋转后继续写。")
        XCTAssertTrue(app.buttons["收起笔记，继续阅读"].isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists,"Exercise the real software keyboard")
        XCTAssertLessThanOrEqual(editor.frame.maxY,app.keyboards.firstMatch.frame.minY+1)
        capture("笔记-竖屏软键盘")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in
            let window = self.app.windows.firstMatch.frame
            return window.width > window.height && editor.exists && editor.isHittable
        },evaluatedWith:nil)],timeout:10)
        editor.typeText("横屏也能继续输入。\n")
        app.buttons["查看整张结构图"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout:5))
        openNodeActions(graph.staticTexts["旋转后继续写。横屏也能继续输入。"])
        app.buttons["添加子节点"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout:5)); editor.typeText("第二条笔记。")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width,window.height)
        XCTAssertGreaterThanOrEqual(editor.frame.minX,window.minX)
        XCTAssertLessThanOrEqual(editor.frame.maxX,window.maxX)
        XCTAssertLessThanOrEqual(editor.frame.maxY,app.keyboards.firstMatch.frame.minY+1)
        XCTAssertTrue(app.buttons["收起笔记，继续阅读"].isHittable)
        capture("笔记-横屏再次新建")
    }

}

extension NotesFlowTests {
    func testRecordInkNodesShortDemo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOOKSLIDE_RECORD_DEMO"]=="1","Opt-in recording; prepare the live EPUB ink fixture first")
        func mark(_ name: String) { print("BOOKSLIDE_DEMO_MARK \(Date().timeIntervalSince1970) \(name)") }
        app.terminate()
        app.launchEnvironment["BOOKSLIDE_UI_TEST_LIBRARY"]="92FA25CA-312D-4A43-B709-2159B0D21AD6"
        app.launch()
        XCTAssertTrue(app.buttons["library-open-featured"].waitForExistence(timeout:15))
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in self.app.windows.firstMatch.frame.width>self.app.windows.firstMatch.frame.height },evaluatedWith:nil)],timeout:10)
        let graph=openMapForGestureTest()
        let (one,two)=inkPreviews(in:graph)
        mark("graph");Thread.sleep(forTimeInterval:1)
        one.tap()
        XCTAssertTrue(app.images["手写笔迹"].waitForExistence(timeout:5))
        mark("content");capture("短片-文字与笔迹");Thread.sleep(forTimeInterval:1)
        let expandedCard=graph.otherElements["展开的手写节点"]
        let inlineContent=app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        XCTAssertTrue(expandedCard.frame.insetBy(dx:-1,dy:-1).contains(inlineContent.frame))
        mark("collapse");graph.buttons["完成节点编辑"].tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !inlineContent.exists },evaluatedWith:nil)],timeout:5)
        Thread.sleep(forTimeInterval:0.7);one.tap()
        XCTAssertTrue(inlineContent.waitForExistence(timeout:5));mark("expanded")
        let merge=app.buttons["合并标记"]
        openNodeActions()
        mark("merge-action")
        XCTAssertTrue(merge.waitForExistence(timeout:5));Thread.sleep(forTimeInterval:0.7);merge.tap()
        XCTAssertTrue(graph.buttons["取消合并"].waitForExistence(timeout:5));two.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !one.exists },evaluatedWith:nil)],timeout:8)
        mark("merged")
        two.tap()
        Thread.sleep(forTimeInterval:1)
        let split=app.buttons["拆分标记"]
        openNodeActions()
        mark("split-action")
        XCTAssertTrue(split.waitForExistence(timeout:5));capture("短片-合并与拆分");Thread.sleep(forTimeInterval:0.7);split.tap()
        XCTAssertTrue(one.waitForExistence(timeout:8));mark("split");Thread.sleep(forTimeInterval:1)
        one.tap();mark("return-action")
        let resume=app.buttons["回原文书写"]
        XCTAssertTrue(resume.waitForExistence(timeout:5));resume.tap()
        XCTAssertTrue(app.buttons["reader-pencil-mode-pen"].waitForExistence(timeout:10))
        mark("reading");capture("短片-回原文书写");Thread.sleep(forTimeInterval:2);mark("end")
    }

    func testInkNodesUseDirectActionsHistoryAndReturnToPencil() {
        app.terminate()
        // Created by PencilPageTests.testPrepareInkGraphUIFixtureFromTheLiveEPUB.
        app.launchEnvironment["BOOKSLIDE_UI_TEST_LIBRARY"]="92FA25CA-312D-4A43-B709-2159B0D21AD6"
        app.launch()
        XCTAssertTrue(app.buttons["library-open-featured"].waitForExistence(timeout:15))
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in self.app.windows.firstMatch.frame.width>self.app.windows.firstMatch.frame.height && self.app.buttons["library-open-featured"].isHittable },evaluatedWith:nil)],timeout:10)
        let graph=openMapForGestureTest()
        let (one,two)=inkPreviews(in:graph)
        let label=two.label
        one.tap()
        let expandedCard=graph.otherElements["展开的手写节点"]
        let inlineContent=app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        let preview=inlineContent.images["手写笔迹"]
        XCTAssertTrue(preview.waitForExistence(timeout:5));capture("Pencil节点-标记优先")
        XCTAssertTrue(expandedCard.exists)
        XCTAssertTrue(expandedCard.frame.insetBy(dx:-1,dy:-1).contains(inlineContent.frame))
        XCTAssertFalse(app.textViews["手写标记的文字笔记"].exists)
        XCTAssertFalse(inlineContent.staticTexts["ink-source-excerpt"].exists,"The preview already contains the selected source")
        let write=inlineContent.buttons["写笔记"],edit=inlineContent.buttons["编辑笔记"]
        let input=inlineContent.textViews["手写标记的文字笔记"]
        let done=inlineContent.buttons["完成笔记"]
        let savedText=inlineContent.staticTexts["ink-written-note"]
        let written="留下自己的理解。"
        XCTAssertTrue(write.isHittable)
        XCTAssertGreaterThan(write.frame.minY,preview.frame.minY)
        let merge=app.buttons["合并标记"],split=app.buttons["拆分标记"]
        XCTAssertFalse(app.buttons["节点操作"].exists)
        XCTAssertFalse(app.buttons["删除节点"].exists)
        XCTAssertTrue(inlineContent.buttons["回原文书写"].isHittable)
        let associations=inlineContent.buttons["关联事物"]
        let entitySearch=inlineContent.textFields["事物名称"], person=inlineContent.buttons["林川"]
        XCTAssertFalse(entitySearch.exists)
        associations.tap()
        XCTAssertTrue(entitySearch.isHittable)
        XCTAssertFalse(person.exists,"Unrelated people appear when searched")
        entitySearch.tap();entitySearch.typeText("林川")
        XCTAssertTrue(person.waitForExistence(timeout:5));person.tap()
        XCTAssertTrue(person.isSelected)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout:5))
        capture("Pencil节点-关联事物")
        XCTAssertEqual(entitySearch.value as? String,"搜索或新建事物")
        person.tap()
        XCTAssertTrue(person.waitForNonExistence(timeout:5))
        associations.tap()
        let beforePan=inlineContent.frame
        let blankCanvas=graph.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:0.36))
        blankCanvas.press(forDuration:0.05,thenDragTo:blankCanvas.withOffset(CGVector(dx:100,dy:28)))
        wait(for:[expectation(for:NSPredicate { _,_ in
            abs(inlineContent.frame.minX-beforePan.minX)>10 && expandedCard.frame.insetBy(dx:-1,dy:-1).contains(inlineContent.frame)
        },evaluatedWith:nil)],timeout:5)
        capture("Pencil节点-展开后移动画布")
        write.tap()
        XCTAssertTrue(input.waitForExistence(timeout:5))
        let keyboard=app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout:5))
        wait(for:[expectation(for:NSPredicate { _,_ in
            input.isHittable && done.isHittable && inlineContent.frame.insetBy(dx:-1,dy:-1).contains(input.frame) &&
                input.frame.maxY <= keyboard.frame.minY+1
        },evaluatedWith:nil)],timeout:8)
        XCTAssertTrue((input.value as? String ?? "").isEmpty)
        input.typeText(written)
        capture("Pencil节点-写笔记")
        done.tap()
        XCTAssertTrue(savedText.waitForExistence(timeout:5))
        XCTAssertEqual(savedText.label,written)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout:5))
        openNodeActions(preview)
        XCTAssertTrue(merge.isHittable)
        XCTAssertFalse(split.exists)
        for title in ["AI 对话","删除节点"] { XCTAssertTrue(app.buttons[title].exists) }
        capture("Pencil节点-长按命令")
        merge.tap()
        XCTAssertTrue(graph.buttons["取消合并"].waitForExistence(timeout:5));two.tap()
        XCTAssertTrue(one.waitForNonExistence(timeout:8))
        XCTAssertTrue(two.waitForExistence(timeout:8));two.tap()
        XCTAssertTrue(inlineContent.images.matching(identifier:"手写笔迹").element(boundBy:1).waitForExistence(timeout:5))
        XCTAssertFalse(app.textViews["讨论问题"].exists,"Merging a mark must not open a discussion")
        openNodeActions()
        XCTAssertTrue(split.waitForExistence(timeout:5))
        XCTAssertTrue(split.isHittable)
        capture("Pencil节点-直接拆分标记");split.tap()
        XCTAssertTrue(one.waitForExistence(timeout:8));XCTAssertTrue(two.exists)
        app.buttons["撤销导图操作"].tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !one.exists },evaluatedWith:nil)],timeout:8)
        app.buttons["重做导图操作"].tap()
        XCTAssertTrue(one.waitForExistence(timeout:8));capture("Pencil节点-拆分重做")
        XCUIDevice.shared.orientation = .portrait
        wait(for:[expectation(for:NSPredicate { _,_ in self.app.windows.firstMatch.frame.width<self.app.windows.firstMatch.frame.height },evaluatedWith:nil)],timeout:10)
        app.buttons["查看整张结构图"].tap()
        one.tap();XCTAssertTrue(preview.waitForExistence(timeout:5))
        XCTAssertTrue(expandedCard.frame.insetBy(dx:-1,dy:-1).contains(inlineContent.frame),"Rotation keeps content inside its node")
        capture("Pencil节点-竖屏文字与笔迹")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in self.app.windows.firstMatch.frame.width>self.app.windows.firstMatch.frame.height },evaluatedWith:nil)],timeout:10)
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        XCTAssertTrue(input.waitForExistence(timeout:5))
        XCTAssertEqual(input.value as? String,written,"Grouping and splitting preserve the note entered on this mark")
        done.tap()
        openNodeActions()
        let remove=app.buttons["删除节点"]
        XCTAssertTrue(remove.waitForExistence(timeout:5));remove.tap()
        XCTAssertTrue(one.waitForNonExistence(timeout:8))
        app.buttons["撤销导图操作"].tap()
        XCTAssertTrue(one.waitForExistence(timeout:8));one.tap()
        let resume=inlineContent.buttons["回原文书写"]
        XCTAssertTrue(resume.waitForExistence(timeout:5));resume.tap()
        wait(for:[expectation(for:NSPredicate { _,_ in !graph.exists },evaluatedWith:nil)],timeout:10)
        XCTAssertTrue(app.buttons["reader-pencil-mode-pen"].waitForExistence(timeout:10))
        capture("Pencil节点-回原文继续书写")
        let inkTools=app.buttons["reader-ink-tools"]
        XCTAssertTrue(inkTools.waitForExistence(timeout:5));inkTools.tap()
        app.terminate();app.launch()
        let reopened=openMapForGestureTest()
        XCTAssertTrue(reopened.images[label].waitForExistence(timeout:8))
        XCTAssertFalse(reopened.staticTexts[written].exists)
        one.tap()
        XCTAssertTrue(preview.waitForExistence(timeout:5))
        capture("Pencil节点-重启保留")
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        XCTAssertTrue(input.waitForExistence(timeout:5));XCTAssertEqual(input.value as? String,written)
        done.tap()
        inlineContent.buttons["查看原文"].tap()
        XCTAssertTrue(app.buttons["展开画布"].waitForExistence(timeout:5))
    }

    func testLongPressInkOnTheMapKeepsBranchesVisible() {
        app.terminate()
        app.launchEnvironment["BOOKSLIDE_UI_TEST_LIBRARY"]="92FA25CA-312D-4A43-B709-2159B0D21AD6"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(for:[expectation(for:NSPredicate { _,_ in
            self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height &&
                self.app.buttons["library-open-featured"].isHittable
        },evaluatedWith:nil)],timeout:10)
        let graph = openMapForGestureTest()
        let (ink,other) = inkPreviews(in:graph)
        capture("长按前-手写导图")
        let original = ink.frame
        openNodeActions(ink)
        let merge = app.buttons["合并标记"], remove = app.buttons["删除节点"]
        XCTAssertTrue(remove.isHittable)
        XCTAssertLessThanOrEqual(merge.frame.height,48)
        XCTAssertLessThan(remove.frame.maxX-merge.frame.minX,280)
        XCTAssertFalse(merge.frame.intersects(ink.frame))
        XCTAssertEqual(ink.frame.minX,original.minX,accuracy:2)
        XCTAssertFalse(app.images["手写笔迹"].exists)
        capture("长按后-手写导图")
        XCTAssertTrue(app.buttons["删除节点"].isHittable)
        graph.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.35)).tap()
        XCTAssertTrue(app.buttons["删除节点"].waitForNonExistence(timeout:3))
        ink.tap()
        let preview = app.images["手写笔迹"]
        XCTAssertTrue(preview.waitForExistence(timeout:5))
        openNodeActions(preview)
        XCTAssertTrue(app.buttons["合并标记"].isHittable)
        XCTAssertFalse(remove.frame.intersects(preview.frame))
        app.buttons["合并标记"].tap()
        XCTAssertTrue(graph.buttons["取消合并"].waitForExistence(timeout:5))
        other.tap()
        XCTAssertTrue(ink.waitForNonExistence(timeout:5))
        openNodeActions(other)
        capture("已合并标记-直接拆分")
        app.buttons["拆分标记"].tap()
        XCTAssertTrue(ink.waitForExistence(timeout:5))
    }

    func testEntityAndDiscussionShareNodeActionMenu() {
        app.terminate()
        app.launchEnvironment["BOOKSLIDE_UI_TEST_ENTITY"] = "1"
        app.launch()
        let graph=openMapForGestureTest()
        let entity=graph.staticTexts["林川"]
        XCTAssertTrue(entity.waitForExistence(timeout:8))
        entity.tap()
        XCTAssertTrue(app.textViews["节点内容"].waitForExistence(timeout:5))
        let editor = app.descendants(matching:.any).matching(identifier:"graph-inline-editor").firstMatch
        XCTAssertTrue(editor.buttons["笔记"].isSelected)
        XCTAssertFalse(editor.descendants(matching:.any).matching(NSPredicate(format:"label == %@", "属性")).firstMatch.exists)
        openNodeActions()
        XCTAssertTrue(app.buttons["编辑节点文字"].isHittable)
        XCTAssertFalse(app.buttons["合并标记"].exists)
        capture("事物节点-操作清单")
        app.buttons["AI 对话"].tap()
        XCTAssertTrue(app.textViews["讨论问题"].waitForExistence(timeout:8))
        openNodeActions()
        XCTAssertTrue(app.buttons["删除节点"].isHittable)
        XCTAssertTrue(app.buttons["AI 对话"].isHittable)
        let card = graph.otherElements["展开的节点：林川"]
        XCTAssertTrue(card.exists,"The conversation belongs to the same card")
        app.buttons["AI 对话"].tap()
        editor.buttons["笔记"].tap()
        editor.buttons["AI"].tap()
        XCTAssertTrue(app.textViews["讨论问题"].waitForExistence(timeout:5))
        editor.buttons["笔记"].tap()
        XCTAssertTrue(app.textViews["节点内容"].waitForExistence(timeout:5))
        app.textViews["节点内容"].tap()
        app.textViews["节点内容"].typeText("人物出场时的想法")
        editor.buttons["连接"].tap()
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout:5))
        // Scope the row to the expanded card so the graph label cannot receive the tap.
        let row = editor.buttons.matching(NSPredicate(format:"label CONTAINS %@", "初次相遇")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:5))
        row.tap()
        XCTAssertTrue(editor.textFields["节点连接名称"].waitForExistence(timeout:5))
        editor.buttons["返回连接列表"].tap()
        XCTAssertTrue(row.waitForExistence(timeout:5))
        XCTAssertTrue(card.exists)
        editor.buttons["笔记"].tap()
        XCTAssertEqual(app.textViews["节点内容"].value as? String,"人物出场时的想法")
        capture("同一节点-笔记连接与AI")
    }

    private func inkPreviews(in graph: XCUIElement) -> (XCUIElement,XCUIElement) {
        let first=graph.images.element(boundBy:0),second=graph.images.element(boundBy:1)
        XCTAssertTrue(second.waitForExistence(timeout:8))
        let firstLabel=first.label,secondLabel=second.label
        XCTAssertNotEqual(firstLabel,secondLabel,"Each mark is identified by its own source excerpt")
        return (graph.images[firstLabel],graph.images[secondLabel])
    }
}
