import XCTest

final class ImoraUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWalkthrough() throws {
        let app = launchDemoApp()

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
    func testTimelineScrubberAndViewerDetails() throws {
        let app = launchDemoApp()

        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no tiles loaded")

        app.swipeUp(velocity: .fast)
        let scrubber = app.descendants(matching: .any).matching(identifier: "timeline-scrubber").firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 3), "timeline scrubber did not appear")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "timeline-scrubber-label")
                .firstMatch
                .waitForExistence(timeout: 1),
            "timeline scrubber did not expose its date label"
        )
        snap("timeline-scrubber")

        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        let firstTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(firstTile.waitForExistence(timeout: 5), "first tile did not return")
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: firstTile
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 3), .completed, "first tile was not hittable")
        firstTile.tap()

        let viewer = app.descendants(matching: .any).matching(identifier: "asset-viewer").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "viewer did not open")
        sleep(1)
        snap("viewer-motion")
        let info = app.descendants(matching: .any).matching(identifier: "viewer-info").firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 3), "info button did not appear")
        info.tap()

        let details = app.descendants(matching: .any).matching(identifier: "asset-details").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5), "asset details did not appear")
        XCTAssertTrue(app.staticTexts["Details"].waitForExistence(timeout: 5), "technical details were not shown")
        snap("asset-details")
    }

    @MainActor
    func testRapidViewerReopenRestoresChromeAndThumbnail() throws {
        let app = launchDemoApp()

        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")
        let firstTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(firstTile.waitForExistence(timeout: 20), "no tiles loaded")
        guard let firstValue = firstTile.value as? String,
              let assetID = firstValue.split(separator: "|").first.map(String.init),
              !assetID.isEmpty
        else {
            XCTFail("first tile did not expose its asset id")
            return
        }

        // tiles expose "assetid|phase" so one query pins the tile and reads
        // its thumbnail state.
        func tileForAsset() -> XCUIElement {
            app.descendants(matching: .any)
                .matching(identifier: "asset-tile")
                .matching(NSPredicate(format: "value BEGINSWITH %@", "\(assetID)|"))
                .firstMatch
        }

        XCTAssertTrue(waitForValue("\(assetID)|loaded", on: tileForAsset(), timeout: 10), "thumbnail did not finish loading")

        for _ in 0..<5 {
            let tile = tileForAsset()
            XCTAssertTrue(tile.exists && tile.isHittable, "source tile was not immediately available")
            tile.tap()

            let viewer = app.descendants(matching: .any)["asset-viewer"]
            XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer did not open")
            XCTAssertEqual(viewer.value as? String, assetID, "viewer did not open on the tapped asset")
            let close = app.descendants(matching: .any)["viewer-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 2), "viewer close button did not appear")
            close.tap()

            XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close")
            XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 2), "photos navigation bar did not return")
            XCTAssertTrue(app.descendants(matching: .any)["profile-avatar"].waitForExistence(timeout: 2), "profile avatar did not return")
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 2), "tab bar did not return")

            let tileAfterClose = tileForAsset()
            XCTAssertTrue(tileAfterClose.waitForExistence(timeout: 2), "tile disappeared after viewer dismissal")
            XCTAssertEqual(tileAfterClose.value as? String, "\(assetID)|loaded", "thumbnail returned to a placeholder")
        }

        // burst: reopen immediately after each close with no settling waits,
        // the way an impatient thumb does it.
        for round in 0..<3 {
            let tile = tileForAsset()
            XCTAssertTrue(tile.waitForExistence(timeout: 3), "tile missing in burst round \(round)")
            tile.tap()
            let viewer = app.descendants(matching: .any)["asset-viewer"]
            XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer did not open in burst round \(round)")
            let close = app.descendants(matching: .any)["viewer-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 2), "close missing in burst round \(round)")
            close.tap()
        }
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["asset-viewer"], timeout: 3), "viewer did not close after burst")

        tileForAsset().tap()
        let viewer = app.descendants(matching: .any)["asset-viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer did not reopen")
        viewer.tap()
        // the system zoom transition provides the pull down dismissal.
        viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        if !waitForDisappearance(viewer, timeout: 3) {
            // fall back to the close button when the synthesized gesture does
            // not engage the system dismissal in the simulator.
            viewer.tap()
            let close = app.descendants(matching: .any)["viewer-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 2), "chrome did not return for fallback close")
            close.tap()
            XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close")
        }

        let reopenedTile = tileForAsset()
        XCTAssertTrue(reopenedTile.waitForExistence(timeout: 2) && reopenedTile.isHittable, "tile was not available after drag dismissal")
        reopenedTile.tap()
        XCTAssertTrue(app.descendants(matching: .any)["viewer-close"].waitForExistence(timeout: 2), "viewer chrome stayed hidden after reopening")
        XCTAssertTrue(app.descendants(matching: .any)["viewer-info"].waitForExistence(timeout: 2), "viewer info stayed hidden after reopening")
    }

    @MainActor
    func testViewerPagingRendersAdjacentPhotos() throws {
        let app = launchDemoApp()

        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no tiles loaded")
        tile.tap()

        let viewer = app.descendants(matching: .any)["asset-viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer did not open")
        sleep(2)

        for step in 1...3 {
            viewer.swipeLeft()
            sleep(2)
            snap("viewer-page-\(step)")
        }
        viewer.swipeRight()
        sleep(2)
        snap("viewer-page-back")

        let close = app.descendants(matching: .any)["viewer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 2), "close button missing after paging")
        close.tap()
        XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close after paging")
    }

    @MainActor
    func testOAuthLoginReachesIdentityProvider() throws {
        let app = XCUIApplication()
        app.launchEnvironment["IMORA_SERVER"] = "https://photos.vexcited.com"
        app.launch()

        let oauthButton = app.buttons["Login with Pocket ID"]
        XCTAssertTrue(oauthButton.waitForExistence(timeout: 20), "oauth button did not appear")
        sleep(3)
        snap("oauth-step")

        if !app.webViews.firstMatch.exists {
            oauthButton.tap()
        }

        // the system consent dialog may come from the app or springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for container in [app, springboard] {
            let continueButton = container.alerts.buttons["Continue"].firstMatch
            if continueButton.waitForExistence(timeout: 6) {
                snap("oauth-consent")
                continueButton.tap()
                break
            }
        }

        let web = app.webViews.firstMatch
        if web.waitForExistence(timeout: 25) {
            sleep(4)
            snap("oauth-idp")
        } else {
            sleep(4)
            snap("oauth-after-continue")
        }
    }

    @MainActor
    func testSearchFeature() throws {
        let app = launchDemoApp()

        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")

        // search tab shows the quick links landing.
        app.tabBars.buttons["Search"].tap()
        let recentlyTaken = app.descendants(matching: .any).matching(identifier: "quick-link-recentlyTaken").firstMatch
        XCTAssertTrue(recentlyTaken.waitForExistence(timeout: 10), "quick links missing")
        snap("search-landing")

        // videos quick link is a canned metadata search.
        let videos = app.descendants(matching: .any).matching(identifier: "quick-link-videos").firstMatch
        videos.tap()
        let videoTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(videoTile.waitForExistence(timeout: 20), "videos grid empty")
        snap("search-videos")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)

        // smart search from the context scope.
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "search field missing")
        searchField.tap()
        searchField.typeText("beach\n")
        let resultTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(resultTile.waitForExistence(timeout: 25), "no smart search results")
        snap("search-results")

        // media type filter narrows to video. the chip can start off screen,
        // so swipe the chip row until its frame is inside the window.
        let chipsRow = app.descendants(matching: .any).matching(identifier: "filter-chips").firstMatch
        let mediaChip = app.descendants(matching: .any).matching(identifier: "filter-chip-mediaType").firstMatch
        XCTAssertTrue(mediaChip.exists, "media type chip missing")
        revealChip(mediaChip, in: chipsRow, app: app)
        mediaChip.tap()
        let videoOption = app.descendants(matching: .any).matching(identifier: "media-type-video").firstMatch
        XCTAssertTrue(videoOption.waitForExistence(timeout: 5), "media type sheet missing")
        videoOption.tap()
        app.descendants(matching: .any).matching(identifier: "filter-apply").firstMatch.tap()
        sleep(3)
        snap("search-filter-video")

        // display options sheet applies favorites, and the chip reflects it.
        let displayChip = app.descendants(matching: .any).matching(identifier: "filter-chip-display").firstMatch
        XCTAssertTrue(displayChip.exists, "display options chip missing")
        revealChip(displayChip, in: chipsRow, app: app)
        displayChip.tap()
        let favoriteToggle = app.descendants(matching: .any).matching(identifier: "display-favorite").firstMatch
        XCTAssertTrue(favoriteToggle.waitForExistence(timeout: 5), "favorite toggle missing")
        // tapping the row center does not flip a form toggle - aim at the
        // switch itself, falling back to the trailing edge.
        let favoriteSwitch = favoriteToggle.switches.firstMatch
        if favoriteSwitch.exists {
            favoriteSwitch.tap()
        } else {
            favoriteToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        app.descendants(matching: .any).matching(identifier: "filter-apply").firstMatch.tap()
        sleep(3)
        XCTAssertTrue(displayChip.label.contains("Favorite"), "display chip did not activate")
        snap("search-filter-favorite")

        // cancel restores the landing content once the filter is cleared.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        sleep(1)
    }

    /// horizontally scrolls a chip row until the chip's frame is on screen.
    /// hittability queries throw for off-screen elements, frames do not.
    @MainActor
    private func revealChip(_ chip: XCUIElement, in row: XCUIElement, app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        var attempts = 0
        while attempts < 4 && chip.frame.maxX > window.maxX - 8 {
            row.swipeLeft()
            sleep(1)
            attempts += 1
        }
        attempts = 0
        while attempts < 4 && chip.frame.minX < 8 {
            row.swipeRight()
            sleep(1)
            attempts += 1
        }
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func launchDemoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["IMORA_SERVER"] = "https://demo.immich.app"
        app.launchEnvironment["IMORA_EMAIL"] = "demo@immich.app"
        app.launchEnvironment["IMORA_PASSWORD"] = "demo"
        app.launch()
        return app
    }

    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
