import XCTest

final class CanDidUITests: XCTestCase {
    private func enterApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-candid-ui-testing"]
        app.launch()
        let start = app.buttons["进入原生 App 示例"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp()
        app.switches["同意本机保存我主动提供的资料与录音"].tap()
        start.tap()
        XCTAssertTrue(app.tabBars.buttons["场合"].waitForExistence(timeout: 10))
        return app
    }
    func testSoundcoreEntryAndSimulatorBoundary() {
        let app = enterApp()
        app.tabBars.buttons["场合"].tap()
        app.buttons.containing(.staticText, identifier: "华味餐饮 · 采购沟通").firstMatch.tap()
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
        app.tabBars.buttons["记忆库"].tap()
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
        XCTAssertTrue(app.buttons["进入原生 App 示例"].waitForExistence(timeout: 10))
    }
    func testOralDebriefCanSaveWithoutCloudAnalysis() {
        let app = enterApp()
        app.tabBars.buttons["场合"].tap()
        app.buttons.containing(.staticText, identifier: "华味餐饮 · 采购沟通").firstMatch.tap()
        let practice = app.buttons["练习与口述复盘"]
        XCTAssertTrue(practice.waitForExistence(timeout: 10)); practice.tap()
        app.buttons["口述复盘"].tap()
        let editor = app.textViews["本人复述"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("I clarified the scope before proposing a pilot.")
        app.swipeUp()
        app.buttons["保存本人文字"].tap()
        XCTAssertTrue(app.alerts.staticTexts["本人复述已保存为证据，未发送给 DeepSeek。"].waitForExistence(timeout: 10))
    }
}
