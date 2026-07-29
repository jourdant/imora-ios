import XCTest

final class ImoraUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWalkthrough() throws {
        let app = XCUIApplication()
        app.launchEnvironment["IMORA_SERVER"] = "https://demo.immich.app"
        app.launchEnvironment["IMORA_EMAIL"] = "demo@immich.app"
        app.launchEnvironment["IMORA_PASSWORD"] = "demo"
        app.launch()

        // timeline appears after auto login.
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")
        let anyTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(anyTile.waitForExistence(timeout: 20), "no tiles loaded")
        sleep(3)
        snap("timeline")

        // scroll the grid.
        app.swipeUp(velocity: .fast)
        sleep(2)
        snap("timeline-scrolled")

        // back to the top so the tab bar expands and the first tile is hittable.
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        sleep(2)

        // open the viewer.
        let tile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        if tile.exists && tile.isHittable {
            tile.tap()
            sleep(3)
            snap("viewer")

            // info sheet.
            let info = app.descendants(matching: .any).matching(identifier: "viewer-info").firstMatch
            if info.exists {
                info.tap()
                sleep(2)
                snap("viewer-info")
                app.swipeDown(velocity: .fast)
                sleep(1)
            }

            // close the viewer.
            let close = app.descendants(matching: .any).matching(identifier: "viewer-close").firstMatch
            if close.exists {
                close.tap()
                sleep(1)
            }
        }

        // albums tab.
        app.tabBars.buttons["Albums"].tap()
        sleep(3)
        snap("albums")

        // open the first album.
        let albumCell = app.buttons.matching(NSPredicate(format: "label CONTAINS 'item'")).firstMatch
        if albumCell.waitForExistence(timeout: 6) {
            albumCell.tap()
            sleep(3)
            snap("album-detail")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        // library tab.
        app.tabBars.buttons["Library"].tap()
        sleep(2)
        snap("library")

        // favorites screen.
        let favorites = app.buttons["Favorites"].firstMatch
        if favorites.exists {
            favorites.tap()
            sleep(3)
            snap("favorites")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        // search tab.
        app.tabBars.buttons["Search"].tap()
        sleep(2)
        snap("search-discover")

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("beach\n")
            sleep(4)
            snap("search-results")
        }

        // settings sheet from photos tab. a collapsed tab bar shows a single
        // pill, so tap it first to expand before choosing the tab.
        let photosTab = app.tabBars.buttons["Photos"]
        if !photosTab.exists {
            app.tabBars.buttons.firstMatch.tap()
            sleep(1)
        }
        photosTab.tap()
        sleep(1)
        let avatar = app.navigationBars["Photos"].buttons.firstMatch
        if avatar.exists {
            avatar.tap()
            sleep(2)
            snap("settings")
        }
    }

    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
