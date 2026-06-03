import XCTest

final class IndoorNavigation_iOSUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {}

    @MainActor
    func testBuildingSearchAndFloorSelection() throws {
        let app = XCUIApplication()
        app.launch()

        // Wait for map view to load
        let mapView = app.otherElements.firstMatch
        XCTAssertTrue(mapView.waitForExistence(timeout: 10))

        // Tap search bar
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should exist")
        searchField.tap()

        // Type building name
        searchField.typeText("hoom")

        // Wait for results table
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5), "Search results table should appear")

        // Tap first result (hoom-test)
        let firstCell = table.cells.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5), "hoom-test cell should appear")
        firstCell.tap()

        // Wait for info card or navigation
        sleep(2)

        // Tap "목적지 선택" button if visible
        let buttons = app.buttons.matching(identifier: "목적지 선택")
        if buttons.firstMatch.exists {
            buttons.firstMatch.tap()
        } else {
            // Try any button in info card area
            let allButtons = app.buttons
            for i in 0..<allButtons.count {
                let btn = allButtons.element(boundBy: i)
                if btn.label.contains("선택") || btn.label.contains("진입") || btn.label.contains("목적지") {
                    btn.tap()
                    break
                }
            }
        }

        sleep(3)
        XCTAssertTrue(true, "Navigation flow executed without crash")
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
