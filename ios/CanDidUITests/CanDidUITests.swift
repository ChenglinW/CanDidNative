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
    func testAppearanceSettingsApplyPersistAndPreserveNavigation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-candid-ui-testing", "-candid-v2-populated"]
        app.launchEnvironment = ["CANDID_ONBOARDING_TEST_ID": UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["candid-avatar"].waitForExistence(timeout: 15))
        capture(app, "appearance-default-full-width")
        let input = app.textFields["home-chat-input"]
        input.tap(); input.typeText("Keep appearance draft")
        app.buttons["收起对话"].tap()
        openAppearanceSettings(app)
        XCTAssertTrue(app.segmentedControls["appearance-navigation"].buttons["全宽底栏"].isSelected)
        XCTAssertTrue(app.segmentedControls["appearance-selection"].buttons["液态玻璃"].isSelected)
        app.buttons["悬浮胶囊"].tap()
        app.buttons["轻盈玻璃"].tap()
        capture(app, "appearance-settings-glass")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["Candid"].waitForExistence(timeout: 10))
        capture(app, "appearance-floating-home")
        app.buttons["记忆库"].firstMatch.tap()
        XCTAssertTrue(app.buttons["表达积累"].waitForExistence(timeout: 10))
        app.buttons["表达积累"].tap()
        XCTAssertTrue(app.buttons["表达积累"].isSelected)
        capture(app, "appearance-floating-memory")
        app.buttons["录音"].firstMatch.tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "华味餐饮 · 产品方案沟通").firstMatch.waitForExistence(timeout: 10))
        let recording = app.buttons.containing(.staticText, identifier: "华味餐饮 · 产品方案沟通").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(recording); recording?.tap()
        XCTAssertTrue(app.buttons["原文"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["记忆库"].exists)
        app.buttons["原文"].tap()
        XCTAssertTrue(app.buttons["play-sentence-preview-line"].waitForExistence(timeout: 10))
        capture(app, "appearance-transcript-sentence-playback")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Candid"].firstMatch.tap()
        input.tap()
        XCTAssertEqual(input.value as? String, "Keep appearance draft")
        app.buttons["收起对话"].tap()
        app.terminate(); app.launch()
        openAppearanceSettings(app)
        XCTAssertTrue(app.buttons["悬浮胶囊"].isSelected)
        XCTAssertTrue(app.buttons["轻盈玻璃"].isSelected)
        app.buttons["全宽底栏"].tap(); app.buttons["经典色块"].tap(); app.buttons["原版立体"].tap()
        capture(app, "appearance-settings-classic")
        app.buttons["完成"].tap()
        capture(app, "appearance-classic-home")
        app.terminate(); app.launch()
        openAppearanceSettings(app)
        XCTAssertTrue(app.buttons["全宽底栏"].isSelected)
        XCTAssertTrue(app.buttons["经典色块"].isSelected)
        XCTAssertTrue(app.buttons["原版立体"].isSelected)
        app.buttons["完成"].tap()
    }
    private func openAppearanceSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["candid-avatar"].waitForExistence(timeout: 15))
        app.buttons["candid-avatar"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 5))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.segmentedControls["appearance-navigation"].waitForExistence(timeout: 10))
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
