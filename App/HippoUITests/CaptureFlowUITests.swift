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
        XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 10))
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
        let gone = NSPredicate(format: "exists == false")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: row("Delete me"))], timeout: 10)
        XCTAssertEqual(result, .completed, "row still present")
    }
}
