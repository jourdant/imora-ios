import UIKit
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

        XCTAssertTrue(waitForValuePrefix("\(assetID)|loaded", on: tileForAsset(), timeout: 10), "thumbnail did not finish loading")

        for _ in 0..<5 {
            let tile = tileForAsset()
            XCTAssertTrue(tile.exists && tile.isHittable, "source tile was not immediately available")
            tile.tap()

            let viewer = app.descendants(matching: .any)["asset-viewer"]
            XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer did not open")
            XCTAssertEqual(viewer.value as? String, assetID, "viewer did not open on the tapped asset")
            let close = control("viewer-close", in: app)
            XCTAssertTrue(close.waitForExistence(timeout: 2), "viewer close button did not appear")
            close.tap()

            XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close")
            XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 2), "photos navigation bar did not return")
            XCTAssertTrue(app.descendants(matching: .any)["profile-avatar"].waitForExistence(timeout: 2), "profile avatar did not return")
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 2), "tab bar did not return")

            let tileAfterClose = tileForAsset()
            XCTAssertTrue(tileAfterClose.waitForExistence(timeout: 2), "tile disappeared after viewer dismissal")
            // prefix match: badge grids append a third value segment.
            XCTAssertTrue(
                (tileAfterClose.value as? String)?.hasPrefix("\(assetID)|loaded") == true,
                "thumbnail returned to a placeholder"
            )
        }

        // burst: reopen immediately after each close with no settling waits,
        // the way an impatient thumb does it.
        for round in 0..<3 {
            let tile = tileForAsset()
            XCTAssertTrue(tile.waitForExistence(timeout: 3), "tile missing in burst round \(round)")
            tile.tap()
            let viewer = app.descendants(matching: .any)["asset-viewer"]
            XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer did not open in burst round \(round)")
            let close = control("viewer-close", in: app)
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
            let close = control("viewer-close", in: app)
            XCTAssertTrue(close.waitForExistence(timeout: 2), "chrome did not return for fallback close")
            close.tap()
            XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close")
        }

        let reopenedTile = tileForAsset()
        XCTAssertTrue(reopenedTile.waitForExistence(timeout: 2) && reopenedTile.isHittable, "tile was not available after drag dismissal")
        reopenedTile.tap()
        XCTAssertTrue(control("viewer-close", in: app).waitForExistence(timeout: 2), "viewer chrome stayed hidden after reopening")
        XCTAssertTrue(control("viewer-info", in: app).waitForExistence(timeout: 2), "viewer info stayed hidden after reopening")
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

        let close = control("viewer-close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 2), "close button missing after paging")
        close.tap()
        XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close after paging")
    }

    /// walks every viewer action surface without mutating the shared demo
    /// library: dialogs are cancelled, the editor is discarded.
    @MainActor
    func testViewerActionsAndInfoPanel() throws {
        let app = launchDemoApp()

        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no tiles loaded")
        tile.tap()

        let viewer = app.descendants(matching: .any)["asset-viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "viewer did not open")

        // share and info are offered for every photo, including a partner's.
        XCTAssertTrue(control("viewer-share", in: app).waitForExistence(timeout: 5), "share button missing")
        XCTAssertTrue(control("viewer-info", in: app).waitForExistence(timeout: 5), "info button missing")

        // the main timeline includes partner photos, and their owner-only
        // actions are deliberately hidden, so page until an owned one is up.
        // which photos are whose changes on the shared demo server, so this
        // cannot assume the first tile is the signed-in user's.
        var ownedPhotoFound = false
        for _ in 0..<10 {
            if control("viewer-favorite", in: app).waitForExistence(timeout: 2) {
                ownedPhotoFound = true
                break
            }
            viewer.swipeLeft()
        }
        XCTAssertTrue(ownedPhotoFound, "no photo owned by the signed-in user in the first pages")
        XCTAssertTrue(control("viewer-trash", in: app).waitForExistence(timeout: 3), "trash button missing")
        snap("viewer-chrome")

        // trash asks first, and cancel leaves everything untouched.
        control("viewer-trash", in: app).tap()
        XCTAssertTrue(app.buttons["Move to Trash"].firstMatch.waitForExistence(timeout: 4), "trash confirmation did not appear")
        snap("viewer-trash-confirm")
        dismissConfirmation(in: app)
        XCTAssertTrue(waitForDisappearance(app.buttons["Move to Trash"], timeout: 3), "trash confirmation did not close")

        // the more menu carries the full action set.
        let menu = control("viewer-menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "more menu missing")
        menu.tap()
        XCTAssertTrue(app.buttons["Add to Album"].firstMatch.waitForExistence(timeout: 4), "menu did not open")
        for label in ["Share Link", "Cast", "View Similar", "Set as Profile Picture", "Download", "Open in Browser", "Archive", "Move to Trash", "Delete Permanently"] {
            XCTAssertTrue(app.buttons[label].exists, "menu item \(label) missing")
        }
        snap("viewer-menu")

        // add to album sheet, cancelled.
        app.buttons["Add to Album"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add to Album"].waitForExistence(timeout: 6), "add-to-album sheet did not open")
        XCTAssertTrue(control("add-to-album-new", in: app).waitForExistence(timeout: 4), "new album row missing")
        snap("viewer-add-to-album")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Add to Album"], timeout: 3), "add-to-album sheet did not close")

        // share link sheet, closed without creating anything.
        menu.tap()
        XCTAssertTrue(app.buttons["Share Link"].firstMatch.waitForExistence(timeout: 4), "menu did not reopen")
        app.buttons["Share Link"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Share Link"].waitForExistence(timeout: 6), "share link sheet did not open")
        XCTAssertTrue(control("album-share-new", in: app).waitForExistence(timeout: 4), "new link row missing")
        snap("viewer-share-link")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Share Link"], timeout: 3), "share link sheet did not close")

        // view similar results load through smart search.
        menu.tap()
        XCTAssertTrue(app.buttons["View Similar"].firstMatch.waitForExistence(timeout: 4), "menu did not reopen for similar")
        app.buttons["View Similar"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Similar Photos"].waitForExistence(timeout: 6), "similar sheet did not open")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch.waitForExistence(timeout: 15),
            "similar results never loaded"
        )
        snap("viewer-similar")
        app.navigationBars["Similar Photos"].swipeDown(velocity: .fast)
        if app.navigationBars["Similar Photos"].exists {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Similar Photos"], timeout: 4), "similar sheet did not close")

        // the editor opens for images; discard leaves the photo untouched.
        menu.tap()
        XCTAssertTrue(app.buttons["Cast"].firstMatch.waitForExistence(timeout: 4), "menu did not reopen for edit")
        if app.buttons["Edit"].firstMatch.exists {
            app.buttons["Edit"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Edit"].waitForExistence(timeout: 10), "editor did not open")
            XCTAssertTrue(control("edit-reset", in: app).waitForExistence(timeout: 10), "editor controls missing")
            snap("viewer-editor")
            app.buttons["Square"].firstMatch.tap()
            sleep(1)
            snap("viewer-editor-square")
            control("edit-cancel", in: app).tap()
            XCTAssertTrue(app.buttons["Discard Changes"].firstMatch.waitForExistence(timeout: 4), "discard dialog did not appear")
            snap("edit-discard-confirm")
            app.buttons["Discard Changes"].firstMatch.tap()
            XCTAssertTrue(waitForDisappearance(app.navigationBars["Edit"], timeout: 4), "editor did not close")
        } else {
            // video page: dismiss the menu without touching anything.
            app.buttons["Cast"].firstMatch.tap()
            sleep(1)
        }

        // swiping the picture up reveals the info panel, photos style.
        XCTAssertTrue(viewer.waitForExistence(timeout: 3), "viewer lost after editor")
        viewer.swipeUp(velocity: .fast)
        let details = app.descendants(matching: .any)["asset-details"]
        if !details.waitForExistence(timeout: 3) {
            // fall back to the info button when the synthesized swipe missed.
            control("viewer-info", in: app).tap()
        }
        XCTAssertTrue(details.waitForExistence(timeout: 5), "info panel did not appear")
        XCTAssertTrue(app.staticTexts["Details"].waitForExistence(timeout: 8), "details section missing")
        XCTAssertTrue(control("info-caption", in: app).waitForExistence(timeout: 8), "caption field missing")
        snap("viewer-info-panel")

        // adjust date sheet opens and cancels.
        let adjustDate = control("info-adjust-date", in: app)
        XCTAssertTrue(adjustDate.waitForExistence(timeout: 8), "adjust date button missing")
        adjustDate.tap()
        XCTAssertTrue(app.navigationBars["Adjust Date & Time"].waitForExistence(timeout: 6), "adjust date sheet did not open")
        snap("viewer-adjust-date")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Adjust Date & Time"], timeout: 3), "adjust date sheet did not close")

        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 3), "info panel toolbar missing")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(details, timeout: 3), "info panel did not close")

        let close = control("viewer-close", in: app)
        if !close.exists {
            viewer.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 3), "close button missing at the end")
        close.tap()
        XCTAssertTrue(waitForDisappearance(viewer, timeout: 3), "viewer did not close")
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

    @MainActor
    func testAlbumManagement() throws {
        let app = launchDemoApp()

        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")

        // albums tab.
        app.tabBars.buttons["Albums"].tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 10), "albums list missing")

        // create a scratch album to exercise every management feature on.
        let albumName = "imora e2e \(UInt32.random(in: 1000..<10_000_000))"
        app.descendants(matching: .any).matching(identifier: "albums-create").firstMatch.tap()
        let createAlert = app.alerts["New Album"]
        XCTAssertTrue(createAlert.waitForExistence(timeout: 5), "create alert missing")
        createAlert.textFields.firstMatch.tap()
        createAlert.textFields.firstMatch.typeText(albumName)
        createAlert.buttons["Create"].tap()
        sleep(3)

        // open it.
        let albumCell = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", albumName)).firstMatch
        XCTAssertTrue(albumCell.waitForExistence(timeout: 10), "created album not in list")
        albumCell.tap()
        let menu = app.descendants(matching: .any).matching(identifier: "album-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "album menu missing")
        snap("album-created")

        // edit: add a description and confirm the header shows it.
        menu.tap()
        let editItem = app.buttons["Edit Album"].firstMatch
        XCTAssertTrue(editItem.waitForExistence(timeout: 5), "edit menu item missing")
        editItem.tap()
        let descriptionField = app.descendants(matching: .any).matching(identifier: "album-edit-description").firstMatch
        XCTAssertTrue(descriptionField.waitForExistence(timeout: 5), "edit sheet missing")
        descriptionField.tap()
        descriptionField.typeText("Managed by the imora ui test")
        app.descendants(matching: .any).matching(identifier: "album-edit-save").firstMatch.tap()
        let description = app.staticTexts["Managed by the imora ui test"]
        XCTAssertTrue(description.waitForExistence(timeout: 10), "description not shown after edit")
        snap("album-edited")

        // add photos: pick the first two tiles from the library picker.
        menu.tap()
        let addPhotos = app.buttons["Add Photos"].firstMatch
        XCTAssertTrue(addPhotos.waitForExistence(timeout: 5), "add photos menu item missing")
        addPhotos.tap()
        let pickerTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(pickerTile.waitForExistence(timeout: 20), "picker grid empty")
        sleep(1)
        let tiles = app.descendants(matching: .any).matching(identifier: "asset-tile")
        tiles.element(boundBy: 0).tap()
        if tiles.count > 1 {
            tiles.element(boundBy: 1).tap()
        }
        app.descendants(matching: .any).matching(identifier: "album-picker-add").firstMatch.tap()
        let feedback = app.descendants(matching: .any).matching(identifier: "album-feedback").firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 15), "no feedback after adding photos")
        let albumTile = app.descendants(matching: .any).matching(identifier: "asset-tile").firstMatch
        XCTAssertTrue(albumTile.waitForExistence(timeout: 15), "album grid empty after add")
        snap("album-photos-added")

        // invite sheet opens and lists the server's users; do not actually
        // invite anyone on the shared demo server.
        menu.tap()
        let invite = app.buttons["Invite People"].firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 5), "invite menu item missing")
        invite.tap()
        XCTAssertTrue(app.navigationBars["Invite to Album"].waitForExistence(timeout: 10), "invite sheet missing")
        snap("album-invite")
        app.buttons["Cancel"].firstMatch.tap()
        sleep(1)

        // options: activity toggle is present for the owner and flips.
        menu.tap()
        let options = app.buttons["Options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5), "options menu item missing")
        options.tap()
        let activityToggle = app.descendants(matching: .any).matching(identifier: "album-activity-toggle").firstMatch
        XCTAssertTrue(activityToggle.waitForExistence(timeout: 10), "activity toggle missing")
        let activitySwitch = activityToggle.switches.firstMatch
        if activitySwitch.exists {
            activitySwitch.tap()
            sleep(2)
        }
        snap("album-options")
        app.buttons["Done"].firstMatch.tap()
        sleep(1)

        // shared link: create one, confirm the url appears, then delete it.
        menu.tap()
        let shareLink = app.buttons["Share Link"].firstMatch
        XCTAssertTrue(shareLink.waitForExistence(timeout: 5), "share link menu item missing")
        shareLink.tap()
        let newLink = app.descendants(matching: .any).matching(identifier: "album-share-new").firstMatch
        XCTAssertTrue(newLink.waitForExistence(timeout: 10), "share sheet missing")
        newLink.tap()
        let saveLink = app.descendants(matching: .any).matching(identifier: "share-link-save").firstMatch
        XCTAssertTrue(saveLink.waitForExistence(timeout: 5), "link form missing")
        // let the push transition settle, a toolbar tap mid-morph can miss.
        sleep(2)
        saveLink.tap()
        let created = app.descendants(matching: .any).matching(identifier: "album-share-created").firstMatch
        if !created.waitForExistence(timeout: 8) && saveLink.exists {
            snap("album-share-form-stuck")
            saveLink.tap()
        }
        XCTAssertTrue(created.waitForExistence(timeout: 15), "created link banner missing")
        snap("album-share-link")
        let linkRow = app.cells.matching(NSPredicate(format: "label CONTAINS 'Public link'")).firstMatch
        if linkRow.exists {
            linkRow.swipeLeft()
            let deleteAction = app.buttons["Delete"].firstMatch
            if deleteAction.waitForExistence(timeout: 3) {
                deleteAction.tap()
                let confirmDelete = app.buttons["Delete Link"].firstMatch
                if confirmDelete.waitForExistence(timeout: 3) {
                    confirmDelete.tap()
                    sleep(2)
                }
            }
        }
        app.buttons["Done"].firstMatch.tap()
        sleep(1)

        // delete the album and land back on the refreshed list.
        menu.tap()
        let deleteItem = app.buttons["Delete Album"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), "delete menu item missing")
        deleteItem.tap()
        let confirm = app.buttons["Delete Album"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "delete confirmation missing")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 10), "did not return to albums list")
        sleep(3)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", albumName)).firstMatch.exists,
            "album still listed after delete"
        )
        snap("album-deleted")
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
    /// toolbar-hosted controls expose their identifier on both the bar item
    /// and the inner button, so strict single-match lookups throw.
    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// ios 26 confirmation dialogs may render without a cancel row; tapping
    /// outside the card dismisses them.
    private func dismissConfirmation(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 1), cancel.isHittable {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
    }

    private func waitForValuePrefix(_ value: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - e2e against the disposable docker immich

    /// uploads an asset through the api while the app is open and expects the
    /// timeline to gain and lose tiles with no pull-to-refresh at all.
    @MainActor
    func testRealtimeTimelineUpdates() async throws {
        try skipUnlessE2E()
        let server = try await E2EServer.logIn()
        let app = launchE2EApp()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")
        sleep(3)

        // a tile already on screen is the witness that updates land in
        // place: it must keep its loaded thumbnail through both resyncs
        // instead of the grid visibly reloading around it.
        let loadedTile = app.descendants(matching: .any)
            .matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "value CONTAINS '|loaded'"))
            .firstMatch
        XCTAssertTrue(loadedTile.waitForExistence(timeout: 15), "no loaded tile to witness with")
        let witnessId = String((loadedTile.value as? String ?? "").split(separator: "|").first ?? "")
        XCTAssertFalse(witnessId.isEmpty, "witness tile had no asset id")
        let witness = app.descendants(matching: .any)
            .matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "value BEGINSWITH %@", "\(witnessId)|loaded"))
            .firstMatch

        // upload from the outside, like another device would.
        let assetId = try await server.uploadTinyImage()
        let tile = tileForAsset(assetId, in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "uploaded asset never appeared in the timeline")
        XCTAssertTrue(witness.waitForExistence(timeout: 5), "existing tile lost its thumbnail during the insert")
        snap("realtime-appeared")

        // trash from the outside; the tile must vanish on its own.
        try await server.trash(ids: [assetId])
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tile)
        await fulfillment(of: [gone], timeout: 25)
        XCTAssertTrue(witness.waitForExistence(timeout: 5), "existing tile lost its thumbnail during the removal")
        snap("realtime-removed")
    }

    /// exercises the destructive and mutating viewer actions against the
    /// disposable server: favorite, caption, server-side edit, trash.
    @MainActor
    func testViewerMutationsEndToEnd() async throws {
        try skipUnlessE2E()
        let server = try await E2EServer.logIn()
        let assetId = try await server.uploadTinyImage()

        let app = launchE2EApp()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")

        let tile = tileForAsset(assetId, in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 25), "uploaded asset never appeared")
        tile.tap()
        let viewer = app.descendants(matching: .any)["asset-viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "viewer did not open")

        // favorite lands on the server.
        control("viewer-favorite", in: app).tap()
        try await pollServer(timeout: 15, message: "favorite never reached the server") {
            try await server.assetInfo(assetId)["isFavorite"] as? Bool == true
        }

        // caption saves from the info panel.
        control("viewer-info", in: app).tap()
        let caption = control("info-caption", in: app)
        XCTAssertTrue(caption.waitForExistence(timeout: 8), "caption field missing")
        caption.tap()
        caption.typeText("hello from e2e")
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 3), "info done missing")
        app.buttons["Done"].firstMatch.tap()
        try await pollServer(timeout: 15, message: "caption never reached the server") {
            let info = try await server.assetInfo(assetId)
            let exif = info["exifInfo"] as? [String: Any]
            return exif?["description"] as? String == "hello from e2e"
        }

        // a rotate edit persists through the server-side edit list.
        let menu = control("viewer-menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "menu missing")
        menu.tap()
        XCTAssertTrue(app.buttons["Edit"].firstMatch.waitForExistence(timeout: 4), "edit item missing")
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit"].waitForExistence(timeout: 10), "editor did not open")
        XCTAssertTrue(control("edit-reset", in: app).waitForExistence(timeout: 10), "editor did not load")
        app.buttons["Rotate right"].firstMatch.tap()
        sleep(1)
        let done = control("edit-done", in: app)
        XCTAssertTrue(done.waitForExistence(timeout: 3), "editor done missing")
        done.tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Edit"], timeout: 20), "editor did not close after save")
        try await pollServer(timeout: 15, message: "edit never reached the server") {
            try await server.assetInfo(assetId)["isEdited"] as? Bool == true
        }
        snap("e2e-edited")

        // trash asks first, then the asset really moves to the trash.
        control("viewer-trash", in: app).tap()
        XCTAssertTrue(app.buttons["Move to Trash"].firstMatch.waitForExistence(timeout: 4), "trash confirmation missing")
        app.buttons["Move to Trash"].firstMatch.tap()
        try await pollServer(timeout: 15, message: "trash never reached the server") {
            try await server.assetInfo(assetId)["isTrashed"] as? Bool == true
        }
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tileForAsset(assetId, in: app))
        await fulfillment(of: [gone], timeout: 20)
        snap("e2e-trashed")
    }

    private func pollServer(
        timeout: TimeInterval,
        message: String,
        _ check: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail(message)
    }

    /// enables backup, grants photo access, and expects device photos to end
    /// up on the server with cloud badges on their tiles.
    @MainActor
    func testBackupBadgesEndToEnd() async throws {
        try skipUnlessE2E()
        _ = try await E2EServer.logIn()
        let app = launchE2EApp()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30), "timeline did not appear")

        // settings -> backup -> back up now. the plain button is reliable
        // under xcui where the form toggle tap can miss, and start() asks
        // for photo access itself.
        app.navigationBars["Photos"].buttons.firstMatch.tap()
        let backupRow = app.descendants(matching: .any).matching(identifier: "settings-backup").firstMatch
        XCTAssertTrue(backupRow.waitForExistence(timeout: 10), "backup row missing")
        backupRow.tap()
        sleep(2)
        let start = app.descendants(matching: .any).matching(identifier: "backup-start").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "backup start button missing")
        start.tap()
        allowFullPhotoAccess()

        // a tap landing during the push transition misses silently: retry.
        let status = app.descendants(matching: .any).matching(identifier: "backup-status").firstMatch
        sleep(3)
        if status.exists, status.label.hasPrefix("Waiting") {
            if start.exists { start.tap() }
            allowFullPhotoAccess()
        }

        // the simulator library is small; give hashing plus uploads a while.
        let done = expectation(
            for: NSPredicate(format: "label BEGINSWITH 'Done'"),
            evaluatedWith: status
        )
        await fulfillment(of: [done], timeout: 240)
        snap("backup-done")

        // back to the timeline: pop to the settings root, then close the
        // sheet - the close button only lives on the root toolbar.
        app.navigationBars.buttons.firstMatch.tap()
        let close = app.descendants(matching: .any).matching(identifier: "settings-close").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "settings close missing")
        close.tap()
        sleep(2)
        let backedTile = app.descendants(matching: .any)
            .matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "value ENDSWITH '|cloud-done'"))
            .firstMatch
        XCTAssertTrue(backedTile.waitForExistence(timeout: 30), "no backed-up badge appeared")

        // device-only tiles must have swapped to their server twins by now.
        let localTile = app.descendants(matching: .any)
            .matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "value BEGINSWITH 'local-'"))
            .firstMatch
        let swapped = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: localTile)
        await fulfillment(of: [swapped], timeout: 30)
        snap("badges-backed-up")
    }

    private func skipUnlessE2E() throws {
        guard ProcessInfo.processInfo.environment["IMORA_TEST_E2E"] == "1" else {
            throw XCTSkip("set IMORA_TEST_E2E=1 with scripts/e2e-immich running")
        }
    }

    @MainActor
    private func launchE2EApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["IMORA_SERVER"] = E2EServer.root
        app.launchEnvironment["IMORA_EMAIL"] = E2EServer.email
        app.launchEnvironment["IMORA_PASSWORD"] = E2EServer.password
        app.launch()
        return app
    }

    @MainActor
    private func tileForAsset(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "asset-tile")
            .matching(NSPredicate(format: "value BEGINSWITH %@", id))
            .firstMatch
    }

    /// answers the system photos dialog when it shows; a clone that already
    /// granted access simply has no dialog.
    @MainActor
    private func allowFullPhotoAccess() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 5) {
                button.tap()
                return
            }
        }
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

// MARK: - e2e api client

/// thin rest client for the disposable docker immich the e2e tests drive
/// from the outside, playing the role of another device.
private struct E2EServer {
    static let root = "http://localhost:2283"
    static let email = "e2e@imora.test"
    static let password = "imora-e2e-pass"

    private static var api: URL { URL(string: root + "/api")! }

    let token: String

    static func logIn() async throws -> E2EServer {
        // the first run against a fresh server creates the admin; later runs
        // get a 400 here, which is fine.
        _ = try? await postJSON("auth/admin-sign-up", body: [
            "name": "E2E", "email": email, "password": password,
        ])
        let data = try await postJSON("auth/login", body: ["email": email, "password": password])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["accessToken"] as? String
        else {
            throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "login failed"])
        }
        return E2EServer(token: token)
    }

    /// uploads a tiny generated png with unique bytes, so a rerun never
    /// collides with the checksum of a previously trashed copy.
    func uploadTinyImage() async throws -> String {
        let size = CGSize(width: 240, height: 240)
        let marker = UUID().uuidString
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (marker as NSString).draw(
                at: CGPoint(x: 10, y: 110),
                withAttributes: [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11)]
            )
        }
        guard let png = image.pngData() else {
            throw NSError(domain: "e2e", code: 2, userInfo: [NSLocalizedDescriptionKey: "png render failed"])
        }

        let iso = ISO8601DateFormatter()
        let now = iso.string(from: Date())
        let boundary = "e2e-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("deviceAssetId", "e2e-\(marker)")
        field("deviceId", "e2e-runner")
        field("fileCreatedAt", now)
        field("fileModifiedAt", now)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"e2e-\(marker).png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.api.appending(path: "assets"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String
        else {
            throw NSError(domain: "e2e", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "upload failed: \(String(data: data, encoding: .utf8) ?? "")",
            ])
        }
        return id
    }

    func assetInfo(_ id: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.api.appending(path: "assets/\(id)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "e2e", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "asset info failed: \(String(data: data, encoding: .utf8) ?? "")",
            ])
        }
        return object
    }

    func trash(ids: [String]) async throws {
        var request = URLRequest(url: Self.api.appending(path: "assets"))
        request.httpMethod = "DELETE"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "e2e", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "trash failed: \(String(data: data, encoding: .utf8) ?? "")",
            ])
        }
    }

    private static func postJSON(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: api.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "e2e", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "\(path) failed: \(String(data: data, encoding: .utf8) ?? "")",
            ])
        }
        return data
    }
}
