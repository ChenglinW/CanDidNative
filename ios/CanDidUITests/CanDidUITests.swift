import XCTest

final class CanDidUITests: XCTestCase {
    func testSpeakerNamingFormSeparatesNamesAndSelfIdentity() {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["-candid-ui-testing","-candid-speaker-review"]
        app.launch()
        let name=app.textFields["speaker-name-part0:1"]
        XCTAssertTrue(app.textFields["speaker-name-part0:0"].waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["speaker-save"].isEnabled)
        XCTAssertEqual(app.textFields["speaker-name-part0:0"].value as? String,"林晓")
        XCTAssertEqual(app.switches["speaker-self-part0:0"].value as? String,"1")
        capture(app,"speaker-editor-initial")
        for _ in 0..<4 {if name.exists && name.isHittable {break};app.swipeUp()}
        XCTAssertTrue(name.exists && name.isHittable)
        name.tap();name.typeText("王总")
        XCTAssertTrue(app.buttons["speaker-save"].isEnabled)
        XCTAssertEqual(app.switches["speaker-self-part0:1"].value as? String,"0")
        capture(app,"speaker-editor-keyboard")
        app.buttons["收起键盘"].tap()
        let later=app.textFields["speaker-name-part1:0"]
        for _ in 0..<4 {if later.exists && later.isHittable {break};app.swipeUp()}
        XCTAssertTrue(later.exists && later.isHittable)
        capture(app,"speaker-editor-later-chunk")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        if name == "onboarding-introduction" { app.scrollViews.firstMatch.swipeDown() }
        // Accessibility geometry can settle before the simulator compositor finishes keyboard motion.
        if name.contains("keyboard") { print("Waiting for stable keyboard capture"); Thread.sleep(forTimeInterval: 10) }
        else { Thread.sleep(forTimeInterval: 0.8) }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testCompleteOnboardingPersistsProfileAndAllowsLaterEditing() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-candid-ui-testing"]
        app.launchEnvironment = ["CANDID_ONBOARDING_TEST_ID": UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 15))
        capture(app, "onboarding-welcome")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.buttons["销售 BD"].waitForExistence(timeout: 10))
        app.buttons["销售 BD"].tap(); app.buttons["面试"].tap()
        XCTAssertEqual(app.buttons["销售 BD"].value as? String, "已选择")
        XCTAssertEqual(app.buttons["面试"].value as? String, "已选择")
        capture(app, "onboarding-purposes")
        app.buttons["onboarding-next"].tap()
        let name = app.textFields["onboarding-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Lin")
        let intro = app.descendants(matching: .any)["onboarding-introduction"].firstMatch
        intro.tap(); intro.typeText("I design products and prepare for interviews.")
        let next = app.buttons["onboarding-next"]
        XCTAssertTrue(next.isHittable)
        XCTAssertGreaterThan(intro.frame.height, 80)
        XCTAssertLessThanOrEqual(intro.frame.maxY, next.frame.minY + 1, "底部操作不能覆盖正在输入的介绍")
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(next.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            XCTAssertGreaterThanOrEqual(intro.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1, "当前编辑框必须滚入可见区域")
            capture(app, "onboarding-keyboard")
        }
        if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        capture(app, "onboarding-introduction")
        XCTAssertTrue(next.isHittable)
        app.buttons["返回上一步"].tap()
        XCTAssertEqual(app.buttons["销售 BD"].value as? String, "已选择")
        app.buttons["onboarding-next"].tap()
        XCTAssertEqual(app.textFields["onboarding-name"].value as? String, "Lin")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.buttons["添加资料"].waitForExistence(timeout: 10))
        capture(app, "onboarding-materials")
        app.buttons["资料稍后再补"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Candid"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["认识一下"].exists)
        app.buttons["记忆库"].firstMatch.tap()
        app.buttons["我的介绍与资料"].tap()
        let savedIntroduction = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "I design products and prepare for interviews.")).firstMatch
        XCTAssertTrue(savedIntroduction.waitForExistence(timeout: 10))
        XCTAssertEqual(savedIntroduction.label.trimmingCharacters(in: .whitespacesAndNewlines), "I design products and prepare for interviews.")
        capture(app, "onboarding-personal-profile")
        app.buttons["编辑我的介绍与资料"].tap()
        XCTAssertTrue(app.textFields["onboarding-name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["onboarding-name"].value as? String, "Lin")
    }
    func testEachOnboardingStepCanBeSkippedWithoutInventingUserData() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-candid-ui-testing"]; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 15)); app.buttons["onboarding-next"].tap()
        app.buttons["这一步先跳过"].tap()
        XCTAssertTrue(app.textFields["onboarding-name"].waitForExistence(timeout: 10))
        app.buttons["这一步先跳过"].tap()
        XCTAssertTrue(app.buttons["添加资料"].waitForExistence(timeout: 10))
        app.buttons["资料稍后再补"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.waitForExistence(timeout: 10))
        app.buttons["记忆库"].firstMatch.tap(); app.buttons["我的介绍与资料"].tap()
        XCTAssertTrue(app.staticTexts["慢慢认识你"].waitForExistence(timeout: 10))
    }
    private func enterApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment=[:]
        app.launchArguments = ["-candid-ui-testing"]
        app.launch()
        let start = app.buttons["直接开始，之后再介绍"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        XCTAssertTrue(app.buttons["Candid"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    func testV2EmptyHomeHasThreeDestinationsAndRealVoiceEntrances() {
        let app=enterApp()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.exists)
        XCTAssertFalse(app.buttons["项目"].exists)
        XCTAssertTrue(app.buttons["记忆库"].exists)
        XCTAssertTrue(app.buttons["录音"].exists)
        XCTAssertFalse(app.staticTexts["华味餐饮 · 产品方案沟通"].exists)
        capture(app,"v2-empty-home")
        app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.tap()
        let continuous=app.buttons["连续对话"].firstMatch
        XCTAssertTrue(continuous.waitForExistence(timeout:10));continuous.tap()
        XCTAssertTrue(app.buttons["开始自由对话"].waitForExistence(timeout:10))
        capture(app,"v2-continuous")
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(app.buttons["收起对话"].waitForExistence(timeout:10));app.buttons["收起对话"].tap()
        app.buttons["candid-avatar"].doubleTap()
        XCTAssertTrue(app.buttons["开始自由对话"].waitForExistence(timeout:10))
    }
    func testV2ChatDraftPersistsAcrossCollapseAndTabs() {
        let app=enterApp()
        app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.tap()
        let input=app.descendants(matching:.any).matching(identifier:"给 Candid 的消息").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:10));input.tap();input.typeText("Keep my draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:10))
        XCTAssertLessThanOrEqual(input.frame.maxY,app.keyboards.firstMatch.frame.minY+1)
        capture(app,"v2-chat-keyboard")
        app.buttons["收起对话"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.waitForExistence(timeout:10))
        app.buttons["记忆库"].firstMatch.tap();app.buttons["录音"].firstMatch.tap();app.buttons["Candid"].firstMatch.tap()
        app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout:10))
        XCTAssertEqual(input.value as? String,"Keep my draft")
    }
    func testV2PopulatedHomeReportsAndRecordingIdentity() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated"];app.launchEnvironment=[:];app.launch()
        XCTAssertTrue(app.buttons["preparation-card-preview-preparation"].waitForExistence(timeout:15))
        capture(app,"v2-populated-home")
        app.buttons["preparation-card-preview-preparation"].tap()
        XCTAssertTrue(app.staticTexts["本次目标"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["生成准备包"].exists)
        XCTAssertFalse(app.buttons["记忆库"].exists,"只读报告不应保留底部主导航")
        capture(app,"v2-preparation")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons.containing(.staticText,identifier:"华味餐饮 · 产品方案沟通").firstMatch.tap()
        XCTAssertTrue(app.buttons["原文"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["播放录音"].exists,"复盘打开即显示播放器")
        capture(app,"fidelity-review")
        app.buttons["原文"].tap()
        XCTAssertTrue(app.staticTexts["请先确认服务范围，再安排三家门店试点。"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["说话人认领"].exists)
        XCTAssertTrue(app.buttons["play-sentence-preview-line"].exists,"每句都有独立播放入口")
        XCTAssertFalse(app.buttons["记忆库"].exists)
        capture(app,"v2-transcript")
    }
    // Exercise the whole visible segment, not only the text in its centre.
    func testReportSegmentsAcceptRepeatedEdgeTaps() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated"];app.launchEnvironment=[:];app.launch()
        let row=app.buttons.containing(.staticText,identifier:"华味餐饮 · 产品方案沟通").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:15));row.tap()
        XCTAssertTrue(app.buttons["原文"].waitForExistence(timeout:10))
        exerciseSegments(app,["原文","复盘"])
        capture(app,"solid-report-segments")
        app.buttons["原文"].tap()
        XCTAssertTrue(app.buttons["play-sentence-preview-line"].exists)
        XCTAssertTrue(app.buttons["说话人认领"].exists)
        XCTAssertTrue(app.buttons["修订原文"].exists)
    }
    func testMemorySegmentsAcceptRepeatedEdgeTaps() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated"];app.launchEnvironment=[:];app.launch()
        XCTAssertTrue(app.buttons["记忆库"].waitForExistence(timeout:15));app.buttons["记忆库"].tap()
        XCTAssertTrue(app.buttons["表达积累"].waitForExistence(timeout:10))
        exerciseSegments(app,["表达积累","长期资料"])
        capture(app,"solid-memory-segments")
        XCTAssertTrue(app.buttons["上传资料"].exists)
    }
    func testReportSelectorDoesNotMoveWhenLongTranscriptBecomesShortReview() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated","-candid-long-transcript"];app.launchEnvironment=[:];app.launch()
        let row=app.buttons.containing(.staticText,identifier:"华味餐饮 · 产品方案沟通").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:15));row.tap()
        XCTAssertTrue(app.buttons["原文"].waitForExistence(timeout:10));app.buttons["原文"].tap()
        let scroll=app.scrollViews.firstMatch
        scroll.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.75)).press(forDuration:0.1,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.60)),withVelocity:.slow,thenHoldForDuration:0.4)
        let original=app.buttons["复盘"].frame
        XCTAssertTrue(app.buttons["复盘"].isHittable)
        app.buttons["复盘"].tap()
        XCTAssertEqual(app.buttons["复盘"].frame.minY,original.minY,accuracy:2,"短内容不能把切换按钮推离原点击位置")
        app.buttons["原文"].coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["原文"].isSelected)
        XCTAssertTrue(app.buttons["play-sentence-preview-long-0"].exists)
        capture(app,"solid-long-transcript")
    }
    func testTranscriptInitialFocusDoesNotRepeatOnRefresh() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated","-candid-long-transcript","-candid-focused-recording"];app.launchEnvironment=[:];app.launch()
        let line=app.staticTexts["第11段沟通记录，先确认服务范围与实施安排。"]
        XCTAssertTrue(line.waitForExistence(timeout:15))
        let visible=NSPredicate(format:"hittable == true")
        expectation(for:visible,evaluatedWith:line)
        waitForExpectations(timeout:10)
        let scroll=app.scrollViews.firstMatch
        let before=line.frame.minY
        scroll.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.80)).press(forDuration:0.02,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.50)))
        let after=line.frame.minY
        XCTAssertGreaterThan(abs(after-before),40)
        Thread.sleep(forTimeInterval:6)
        XCTAssertEqual(line.frame.minY,after,accuracy:3,"定时刷新不能把用户拉回最初句子")
        capture(app,"solid-transcript-after-refresh")
    }
    func testLargeTextReportKeepsSelectorAndTranscriptActionsReachable() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated","-candid-long-transcript","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"];app.launchEnvironment=[:];app.launch()
        let row=app.buttons.containing(.staticText,identifier:"华味餐饮 · 产品方案沟通").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:15));row.tap()
        let raw=app.buttons["原文"]
        XCTAssertTrue(raw.waitForExistence(timeout:10));XCTAssertTrue(raw.isHittable);raw.tap()
        XCTAssertTrue(raw.isSelected)
        XCTAssertGreaterThan(app.scrollViews.firstMatch.frame.height,100,"固定页头之后仍需保留可阅读正文")
        let y=raw.frame.minY
        // Large text must wrap fully; metadata can scroll while the selector remains available.
        XCTAssertGreaterThan(app.staticTexts["华味餐饮 · 产品方案沟通"].frame.height,80)
        for _ in 0..<4 {
            if app.buttons["说话人认领"].isHittable {break}
            let scroll=app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.8)).press(forDuration:0.1,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.6)),withVelocity:.slow,thenHoldForDuration:0.3)
        }
        XCTAssertTrue(app.buttons["说话人认领"].isHittable)
        XCTAssertTrue(app.buttons["修订原文"].isHittable)
        XCTAssertTrue(raw.isHittable);XCTAssertEqual(raw.frame.minY,y,accuracy:2)
        capture(app,"solid-report-large-text")
    }
    func testReportSegmentsAcceptTapsBesideMiddleDivider() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated"];app.launchEnvironment=[:];app.launch()
        let row=app.buttons.containing(.staticText,identifier:"华味餐饮 · 产品方案沟通").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:15));row.tap()
        let left=app.buttons["复盘"],right=app.buttons["原文"]
        XCTAssertTrue(right.waitForExistence(timeout:10));right.tap()
        let divider=(left.frame.maxX+right.frame.minX)/2
        let y=left.frame.midY
        for n in 0..<10 {
            let target=n%2==0 ? left:right
            let x=divider+(n%2==0 ? -1.0:1.0)
            app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:y)).tap()
            XCTAssertTrue(target.isSelected,"中缝旁点击必须归入对应半格；两按钮间距=\(right.frame.minX-left.frame.maxX)pt")
        }
    }
    private func exerciseSegments(_ app:XCUIApplication,_ titles:[String]) {
        let points:[CGVector]=[CGVector(dx:0.08,dy:0.5),CGVector(dx:0.92,dy:0.5),CGVector(dx:0.5,dy:0.12),CGVector(dx:0.5,dy:0.88),CGVector(dx:0.5,dy:0.5)]
        for n in 0..<100 {
            let title=titles[n%2];let button=app.buttons[title]
            let before=button.frame
            XCTAssertTrue(button.isHittable,"segment must remain visible: \(n)")
            button.coordinate(withNormalizedOffset:points[n%points.count]).tap()
            XCTAssertTrue(button.isSelected,"missed visible segment at tap \(n), point \(points[n%points.count]), frame \(before)")
        }
    }
    func testNativeTabBarKeepsSingleSystemNavigationAndFixedAppearance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-candid-ui-testing", "-candid-v2-populated"]
        app.launchEnvironment = ["CANDID_ONBOARDING_TEST_ID": UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.count, 1)
        for _ in 0..<3 {
            for title in ["记忆库", "录音", "Candid"] {
                let tab = app.tabBars.buttons[title]
                XCTAssertTrue(tab.isHittable); tab.tap()
                XCTAssertTrue(tab.isSelected)
            }
        }
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        let input = app.textFields["home-chat-input"]
        XCTAssertTrue(input.isHittable)
        XCTAssertLessThan(input.frame.maxY, app.tabBars.firstMatch.frame.minY)
        capture(app, "native-tabs-fixed-home")
        app.buttons["candid-avatar"].press(forDuration: 1.2)
        let settings = app.buttons["个人与设置"]
        let menuVisible = settings.waitForExistence(timeout: 10)
        if !menuVisible { capture(app, "native-settings-menu-debug"); print(app.debugDescription) }
        XCTAssertTrue(menuVisible)
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置与隐私"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["界面外观"].exists)
        XCTAssertFalse(app.segmentedControls["appearance-navigation"].exists)
        XCTAssertFalse(app.segmentedControls["appearance-selection"].exists)
        XCTAssertFalse(app.segmentedControls["appearance-buttons"].exists)
        XCTAssertTrue(app.buttons["我的介绍与资料"].exists)
        capture(app, "native-tabs-settings-without-appearance")
        app.buttons["完成"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
    }
    func testFidelityAdaptiveHomeAndReport() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated"];app.launchEnvironment=[:];app.launch()
        let input=app.textFields["home-chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout:15));XCTAssertTrue(input.isHittable)
        let prepare=app.buttons["preparation-card-preview-preparation"]
        XCTAssertTrue(prepare.isHittable)
        XCTAssertTrue(app.buttons["复盘上一场"].exists)
        capture(app,"fidelity-adaptive-home")
        prepare.tap();XCTAssertTrue(app.staticTexts["本次目标"].waitForExistence(timeout:10));XCTAssertFalse(app.buttons["记忆库"].exists)
        capture(app,"fidelity-adaptive-report")
    }
    func testFidelityLargeTextKeepsActionsReachable() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"];app.launchEnvironment=[:];app.launch()
        let input=app.textFields["home-chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout:15));XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.buttons["连续对话"].exists)
        capture(app,"fidelity-large-home")
        app.buttons["记忆库"].firstMatch.tap();XCTAssertTrue(app.buttons["上传资料"].waitForExistence(timeout:10))
        capture(app,"fidelity-large-memory")
    }

    func testFidelityPopulatedMemoryAndSourceNavigation() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated"];app.launchEnvironment=[:];app.launch()
        app.buttons["记忆库"].firstMatch.tap()
        XCTAssertTrue(app.buttons["表达积累"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["跨场发现"].exists,"跨场发现从卡片进入，不添加第三个分类")
        capture(app,"fidelity-memory-populated")
        app.buttons["表达积累"].tap()
        app.buttons.containing(.staticText,identifier:"为什么比另一家贵？").firstMatch.tap()
        XCTAssertTrue(app.buttons["改成我的说法"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["录音"].exists)
        capture(app,"fidelity-expression-detail")
        app.buttons["改成我的说法"].tap()
        XCTAssertTrue(app.textViews["我的表达"].waitForExistence(timeout:10))
        app.navigationBars.buttons.firstMatch.tap()
        let inbox=app.buttons["查看全部发现与集中确认"]
        if !inbox.isHittable{app.swipeUp()}
        inbox.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","选择发现：")).firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["记忆库"].exists)
        capture(app,"fidelity-discovery-inbox")
    }

    func testV2MemoryRecordingAndDeviceBoundaries() {
        let app=enterApp()
        app.buttons["记忆库"].firstMatch.tap()
        XCTAssertTrue(app.buttons["上传资料"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["我的介绍与资料"].exists)
        capture(app,"v2-memory")
        XCTAssertFalse(app.buttons["表达积累"].exists,"空记忆库不应出现分类栏")
        app.buttons["录音"].firstMatch.tap()
        XCTAssertTrue(app.buttons["phone-recording-fallback"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["第一场经验，从这里留下。"].exists)
        capture(app,"v2-empty-recordings")
        app.buttons["录音设备"].tap()
        XCTAssertTrue(app.buttons["连接与同步"].waitForExistence(timeout:10))
        capture(app,"v2-device-guide")
        app.buttons["返回"].firstMatch.tap()
        app.buttons["phone-recording-fallback"].tap()
        XCTAssertTrue(app.buttons["录音更多操作"].waitForExistence(timeout:10))
        capture(app,"v2-recorder")
        app.buttons["录音更多操作"].tap();app.buttons["设备连接与同步"].tap()
        app.buttons["连接与授权"].tap()
        XCTAssertTrue(app.staticTexts["soundcore-simulator-note"].waitForExistence(timeout:10))
    }
    func testFidelityActualHTTPSentencePlayback() throws {
        guard ProcessInfo.processInfo.environment["CANDID_RUN_HTTP_UI"]=="1" else{throw XCTSkip("Requires isolated local HTTP test server")}
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=[];app.launchEnvironment=["CANDID_LOCAL_BACKEND":"1","CANDID_BACKEND_PORT":"8879","CANDID_BACKEND_TOKEN":"candid-v2-local-acceptance","CANDID_ACCEPTANCE_CACHE":UUID().uuidString]
        app.launch()
        let skip=app.buttons["直接开始，之后再介绍"];if skip.waitForExistence(timeout:10){skip.tap()}
        XCTAssertTrue(app.buttons["录音"].firstMatch.waitForExistence(timeout:30));app.buttons["录音"].firstMatch.tap()
        app.buttons.containing(.staticText,identifier:"逐句回听验收录音").firstMatch.tap()
        app.buttons["原文"].tap()
        let buttons=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","play-sentence-"))
        XCTAssertEqual(buttons.count,2)
        buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.buttons["暂停这一句"].waitForExistence(timeout:10))
        buttons.element(boundBy:1).tap()
        XCTAssertTrue(app.buttons["暂停这一句"].waitForExistence(timeout:10))
        let stopped=NSPredicate(format:"label == %@","播放这一句")
        expectation(for:stopped,evaluatedWith:buttons.element(boundBy:1))
        waitForExpectations(timeout:10)
        XCTAssertTrue(app.buttons["停止回听"].exists)
        capture(app,"fidelity-http-sentence-playback")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["记忆库"].waitForExistence(timeout:10))
    }

    func testChatPanelHasExplicitEntryAndDismissedStopDoesNotReturn() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-candid-ui-testing","-candid-v2-populated","-candid-stopped-chat","-candid-clear-task-hints"];app.launchEnvironment=[:];app.launch()
        XCTAssertTrue(app.buttons["toggle-home-chat"].waitForExistence(timeout:15))
        app.buttons["toggle-home-chat"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists,"查看历史不应弹键盘")
        let close=app.buttons["dismiss-task-preview-stopped"]
        if !close.waitForExistence(timeout:5) {print(app.debugDescription);capture(app,"chat-stop-diagnostic")}
        XCTAssertTrue(close.exists);close.tap()
        XCTAssertFalse(close.exists)
        XCTAssertTrue(app.staticTexts["先确认客户当前的目标，再讨论方案。"].exists)
        app.buttons["收起对话"].tap()
        app.buttons["toggle-home-chat"].tap()
        XCTAssertFalse(close.exists)
        capture(app,"chat-panel-stopped-dismissed")
        app.terminate();app.launchArguments.removeAll{$0=="-candid-clear-task-hints"};app.launch();app.buttons["toggle-home-chat"].tap()
        XCTAssertFalse(close.exists,"关闭恢复提示应跨重启保留")
        XCTAssertFalse(app.staticTexts["保留了一段未完成的语音"].exists)
    }
    func testActualHTTPWorkspaceCarouselRetainsContextAcrossRefreshAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["CANDID_RUN_HTTP_UI"]=="1" else{throw XCTSkip("Requires local acceptance server")}
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=[];app.launchEnvironment=["CANDID_LOCAL_BACKEND":"1","CANDID_BACKEND_PORT":"8879","CANDID_BACKEND_TOKEN":"candid-v2-local-acceptance","CANDID_ACCEPTANCE_CACHE":UUID().uuidString];app.launch()
        let skip=app.buttons["直接开始，之后再介绍"];if skip.waitForExistence(timeout:10) {skip.tap()}
        let toggle=app.buttons["toggle-home-chat"]
        XCTAssertTrue(toggle.waitForExistence(timeout:30))
        let carousel=app.scrollViews["workspace-carousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout:10))
        let create=app.buttons["新建项目空间，直接开始聊天"]
        for _ in 0..<12 {
            if create.exists && create.frame.minX>=carousel.frame.minX && create.frame.maxX<=carousel.frame.maxX+1 {break}
            carousel.swipeLeft()
        }
        XCTAssertTrue(create.isHittable);create.tap()
        XCTAssertTrue(app.buttons["收起对话"].waitForExistence(timeout:15),"新建完成后应自动展开新空间")
        let input=app.descendants(matching:.any).matching(identifier:"给 Candid 的消息").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:15));input.tap();input.typeText("Workspace draft A")
        app.buttons["收起对话"].tap()
        capture(app,"workspace-draft-a")
        // The home refresh interval is five seconds; wait through two intervals.
        Thread.sleep(forTimeInterval:11)
        toggle.tap();input.tap()
        XCTAssertEqual(input.value as? String,"Workspace draft A")
        app.buttons["收起对话"].tap()
        app.terminate();app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout:30));toggle.tap();input.tap()
        XCTAssertEqual(input.value as? String,"Workspace draft A","前后台连接恢复必须保留所选空间和草稿")
        app.buttons["收起对话"].tap()
        // Select the general assistant from the management list, independently of swipe distance.
        app.buttons["工作区管理"].tap();app.buttons["空间列表与归档"].tap()
        app.buttons["workspace-list-general"].tap()
        toggle.tap();input.tap()
        XCTAssertNotEqual(input.value as? String,"Workspace draft A","空间草稿必须隔离")
        app.buttons["收起对话"].tap()
        capture(app,"workspace-general-selected")
    }

    func testV2ActualHTTPAppAgentPreparationAndSourceAnswer() throws {
        guard ProcessInfo.processInfo.environment["CANDID_RUN_HTTP_UI"]=="1" else {throw XCTSkip("Run scripts/v2-test-server.py and set CANDID_RUN_HTTP_UI=1 for actual HTTP acceptance")}
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=[]
        let cloud=ProcessInfo.processInfo.environment["CANDID_CLOUD_ACCEPTANCE"]=="1"
        app.launchEnvironment=["CANDID_LOCAL_BACKEND":cloud ? "0":"1","CANDID_CLOUD_ACCEPTANCE":cloud ? "1":"0","CANDID_BACKEND_PORT":"8879","CANDID_BACKEND_TOKEN":cloud ? ProcessInfo.processInfo.environment["CANDID_BACKEND_TOKEN"]! : "candid-v2-local-acceptance","CANDID_ACCEPTANCE_CACHE":UUID().uuidString]
        app.launch()
        let home=app.descendants(matching:.any).matching(identifier:"home-chat-input").firstMatch
        let skip=app.buttons["直接开始，之后再介绍"]
        if skip.waitForExistence(timeout:10){skip.tap()}
        XCTAssertTrue(home.waitForExistence(timeout:30))
        home.tap()
        let input=app.descendants(matching:.any).matching(identifier:"给 Candid 的消息").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:10));input.tap();input.typeText("请告诉我产品代号")
        app.buttons["发送消息"].tap()
        XCTAssertFalse(app.staticTexts["没有识别到可发送的文字。"].exists,"普通点按不能启动按住录音")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","CANDID-A73")).firstMatch.waitForExistence(timeout:120))
        input.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:10))
        input.typeText("帮我准备客户甲的三家门店试点沟通，目标是确认服务范围，时间待定。对象采购王总，顾虑是两周上线，直接准备完整报告并保存准备包。")
        app.buttons["发送消息"].tap()
        let card=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat-preparation-")).firstMatch
        let deadline=Date().addingTimeInterval(120)
        while !card.exists && Date()<deadline {
            // Real models may elaborate after saving. The report card remains earlier
            // in this same Chat, outside LazyVStack's currently materialized rows.
            if !app.buttons["停止"].exists {app.swipeDown()}
            Thread.sleep(forTimeInterval:1)
        }
        XCTAssertTrue(card.exists)
        let id=card.identifier.replacingOccurrences(of:"chat-preparation-",with:"")
        capture(app,"v2-http-chat-report")
        card.tap();XCTAssertTrue(app.navigationBars["会前准备包"].waitForExistence(timeout:10))
        capture(app,"v2-http-preparation")
        app.navigationBars.buttons.firstMatch.tap();app.buttons["收起对话"].tap()
        XCTAssertTrue(app.buttons["preparation-card-"+id].waitForExistence(timeout:15),"首页和Chat必须是同一准备包")
        capture(app,"v2-http-home-report")
    }

}
