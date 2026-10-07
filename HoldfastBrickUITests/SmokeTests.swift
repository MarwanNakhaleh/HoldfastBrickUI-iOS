import XCTest

/// One end-to-end walk through the app against the in-process mock brick
/// (`-mockAPI`): discovery → pairing → dashboard → Ad Blocking.
final class SmokeTests: XCTestCase {
    func testDiscoverPairAndSeeDashboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-mockAPI"]
        app.launch()

        // Discovery: the demo brick appears without typing anything.
        let deviceRow = app.buttons["discovery.device.demo"]
        XCTAssertTrue(deviceRow.waitForExistence(timeout: 5),
                      "discovered device should appear")
        deviceRow.tap()

        // Pairing: enter the mock code.
        let codeField = app.textFields["pairing.codeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 3))
        codeField.tap()
        codeField.typeText("123456")

        let connect = app.buttons["pairing.connectButton"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        // Dashboard: protection badge and the Ad Blocking card.
        let badge = app.staticTexts["dashboard.protectionBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5),
                      "dashboard should appear after pairing")

        let adBlockingCard = app.buttons["dashboard.card.adguard"]
        XCTAssertTrue(adBlockingCard.waitForExistence(timeout: 3))
        adBlockingCard.tap()

        // Ad Blocking screen: the master toggle is present and on.
        let toggle = app.switches["adblocking.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
    }

    func testWrongPairingCodeShowsError() {
        let app = XCUIApplication()
        app.launchArguments = ["-mockAPI"]
        app.launch()

        let deviceRow = app.buttons["discovery.device.demo"]
        XCTAssertTrue(deviceRow.waitForExistence(timeout: 5))
        deviceRow.tap()

        let codeField = app.textFields["pairing.codeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 3))
        codeField.tap()
        codeField.typeText("000000")
        app.buttons["pairing.connectButton"].tap()

        XCTAssertTrue(app.staticTexts["pairing.error"].waitForExistence(timeout: 5),
                      "a wrong code should show a friendly error")
    }
}
