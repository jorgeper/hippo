import XCTest

@MainActor
final class CaptureFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-HippoResetStore", "YES"]
        app.launch()
    }

    /// The timeline row for a capture: its accessibility label is "{title}, {time}, {sync}".
    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func createNote(_ text: String) {
        let note = app.buttons["note-button"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(text)
        app.buttons["note-save"].tap()
        XCTAssertTrue(row(text).waitForExistence(timeout: 10))
    }

    func testNoteSyncsToDeveloperFolder() throws {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let connect = app.buttons["Connect Developer folder"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        createNote("UI test note")

        let synced = NSPredicate(format: "label ENDSWITH %@", "Synced")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: synced, object: row("UI test note"))], timeout: 30)
        XCTAssertEqual(result, .completed, "row never reached Synced")
    }

    func testDeleteRemovesCapture() throws {
        createNote("Delete me")
        row("Delete me").tap()
        let menu = app.buttons["detail-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let delete = app.buttons["Delete from iPhone…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["note-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera-button"].exists)
        XCTAssertTrue(app.buttons["record-button"].exists)
        let gone = NSPredicate(format: "exists == false")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: row("Delete me"))], timeout: 10)
        XCTAssertEqual(result, .completed, "row still present")
    }

    /// Detail has the comment bar (Note and Record, no Camera), and a typed comment shows under "Comments".
    func testDetailHasCommentButtons() throws {
        createNote("Comment on me")
        row("Comment on me").tap()
        XCTAssertTrue(app.buttons["detail-menu"].waitForExistence(timeout: 10))
        let note = app.buttons["note-button"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record-button"].exists)
        XCTAssertFalse(app.buttons["camera-button"].exists)

        note.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("A later thought")
        app.buttons["note-save"].tap()
        XCTAssertTrue(app.staticTexts["A later thought"].waitForExistence(timeout: 10))
    }

    /// `make uitest` grants the microphone via simctl and sets HIPPO_UITEST_MIC_GRANTED=1 (forwarded with the
    /// TEST_RUNNER_ prefix); without it the system permission alert would block the flow, so the test skips.
    func testRecordStartsImmediately() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HIPPO_UITEST_MIC_GRANTED"] == "1",
                          "microphone permission is not pre-granted")
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
    }
}
