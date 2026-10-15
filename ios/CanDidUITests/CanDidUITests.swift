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
        if name == "onboarding-keyboard" { print("Waiting for stable keyboard capture"); Thread.sleep(forTimeInterval: 10) }
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
        XCTAssertTrue(app.buttons["认识一下"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(app.staticTexts["Lin，一起准备下一次"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["项目"].firstMatch.waitForExistence(timeout: 15))
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
        XCTAssertTrue(app.staticTexts["一起准备下一次"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["项目"].firstMatch.waitForExistence(timeout: 10))
        return app
    }
    func testSoundcoreEntryAndSimulatorBoundary() {
        let app = enterApp()
        app.buttons["项目"].firstMatch.tap()
        app.buttons.containing(.staticText, identifier: "华味餐饮 · 采购沟通").firstMatch.tap()
        app.buttons.containing(.staticText,identifier:"示例 · 第一场沟通").firstMatch.tap()
        app.buttons["现场"].tap()
        let record = app.buttons["开始沟通录音"]
        XCTAssertTrue(record.waitForExistence(timeout: 10)); record.tap()
        let more = app.buttons["录音更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        app.buttons["设备连接与同步"].tap()
        let connect = app.buttons["连接与授权"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
        let note = app.staticTexts["soundcore-simulator-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["开始真实麦克风录音"].exists)
        XCTAssertFalse(app.buttons["验证 soundcore 授权"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "soundcore-recording-simulator"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testConfirmedMemoryFlow() {
        let app = enterApp()
        app.buttons["记忆库"].tap()
        app.buttons["素材"].tap()
        app.buttons["自我介绍、故事与 FAQ"].tap()
        app.buttons["待确认"].tap()
        app.buttons.containing(.staticText, identifier: "先确认交付范围").firstMatch.tap()
        let confirm = app.buttons["核对完毕，确认为事实"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        XCTAssertTrue(app.staticTexts["已确认事实"].waitForExistence(timeout: 10))
    }
    func testContinuousVoicePageCanOpenAndExitWithoutStartingCapture() {
        let app = enterApp()
        app.terminate()
        app.launchEnvironment["CANDID_INITIAL_SCREEN"] = "voice"
        app.launch()
        XCTAssertTrue(app.buttons["开始自由对话"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["静音"].exists)
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["直接开始，之后再介绍"].waitForExistence(timeout: 10))
    }
    func testOralDebriefCanSaveWithoutCloudAnalysis() {
        let app = enterApp()
        app.buttons["项目"].firstMatch.tap()
        app.buttons.containing(.staticText, identifier: "华味餐饮 · 采购沟通").firstMatch.tap()
        app.buttons.containing(.staticText,identifier:"示例 · 第一场沟通").firstMatch.tap()
        app.buttons["现场"].tap()
        let practice = app.buttons["练习与口述复盘"]
        XCTAssertTrue(practice.waitForExistence(timeout: 10)); practice.tap()
        app.buttons["练习与口述复盘"].tap()
        XCTAssertTrue(app.buttons["口述复盘"].waitForExistence(timeout:10))
        app.buttons["口述复盘"].tap()
        let editor = app.textViews["本人复述"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("I clarified the scope before proposing a pilot.")
        app.swipeUp()
        app.buttons["保存本人文字"].tap()
        XCTAssertTrue(app.alerts.staticTexts["本人复述已保存为证据，未发送给 DeepSeek。"].waitForExistence(timeout: 10))
    }
    func testHomeProjectsAndInterviewShareMeetingHierarchy() {
        let app=enterApp()
        XCTAssertTrue(app.staticTexts["一起准备下一次"].exists)
        let home=XCTAttachment(screenshot:app.screenshot());home.name="product-home";home.lifetime = .keepAlways;add(home)
        app.buttons["项目"].firstMatch.tap()
        app.buttons.containing(.staticText,identifier:"示例 · 产品经理面试").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["场次时间线"].waitForExistence(timeout:10))
        let project=XCTAttachment(screenshot:app.screenshot());project.name="product-interview";project.lifetime = .keepAlways;add(project)
        app.buttons.containing(.staticText,identifier:"示例 · 业务面").firstMatch.tap()
        XCTAssertTrue(app.buttons["整理会前准备包"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["整理会前准备包"].isEnabled)
        let meeting=XCTAttachment(screenshot:app.screenshot());meeting.name="product-meeting";meeting.lifetime = .keepAlways;add(meeting)
        app.buttons["会后"].tap()
        XCTAssertTrue(app.staticTexts["等待本场资料"].waitForExistence(timeout:10))
    }

    func testSurfaceReviewMatrix() {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchEnvironment=["CANDID_CAPTION_PREVIEW":"1"];app.launchArguments=["-candid-ui-testing","-candid-surface-review"];app.launch()
        XCTAssertTrue(app.staticTexts["一起准备下一次"].waitForExistence(timeout:15))
        let home=XCTAttachment(screenshot:app.screenshot());home.name="review-home";home.lifetime = .keepAlways;add(home)
        app.buttons["开始新录音"].tap()
        let footer=app.buttons["连接后端"].firstMatch
        let visible=XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == true"),object:footer)
        XCTAssertEqual(XCTWaiter.wait(for:[visible],timeout:10),.completed)
        XCTAssertTrue(app.staticTexts["示例 · 我们先确认接口和交付范围，再安排下一场沟通。"].waitForExistence(timeout:10))
        let recorder=XCTAttachment(screenshot:app.screenshot());recorder.name="review-live-recorder";recorder.lifetime = .keepAlways;add(recorder)
        app.buttons["收起"].tap()
        XCTAssertTrue(app.buttons["项目"].firstMatch.waitForExistence(timeout:10));app.buttons["项目"].firstMatch.tap()
        app.buttons.containing(.staticText,identifier:"华味餐饮 · 采购沟通").firstMatch.tap()
        let timeline=app.staticTexts["场次时间线"].firstMatch
        let settled=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in timeline.isHittable && timeline.frame.minX<30},object:timeline)
        XCTAssertEqual(XCTWaiter.wait(for:[settled],timeout:10),.completed)
        let project=XCTAttachment(screenshot:app.screenshot());project.name="review-sales-project";project.lifetime = .keepAlways;add(project)
        app.buttons.containing(.staticText,identifier:"示例 · 下一场谈判").firstMatch.tap()
        let goal=app.staticTexts["推进试点"].firstMatch
        let meetingSettled=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in goal.isHittable && goal.frame.minX<30},object:goal)
        XCTAssertEqual(XCTWaiter.wait(for:[meetingSettled],timeout:10),.completed)
        let meeting=XCTAttachment(screenshot:app.screenshot());meeting.name="review-sales-preparation";meeting.lifetime = .keepAlways;add(meeting)
    }

}
