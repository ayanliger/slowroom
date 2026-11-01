import XCTest

@MainActor
final class DeckUITests: XCTestCase {
    func testOriginalCleanupPreservesLibraryPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-library", "--seed-library"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let mix = app.buttons["libraryTrack_Evening study (Slowed + Reverb)"]
        XCTAssertTrue(mix.waitForExistence(timeout: 30))
        app.buttons["libraryOptions"].tap()
        app.buttons["Delete imported originals"].tap()
        app.buttons["findTestOriginals"].tap()
        XCTAssertTrue(app.staticTexts["cleanupMatchedCount"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["cleanupMatchedCount"].label, "2 matched originals")
        app.buttons["deleteMatchedOriginals"].tap()
        XCTAssertTrue(app.staticTexts["cleanupResultCount"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["cleanupResultCount"].label, "2 originals deleted")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Verified original cleanup"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        mix.tap()
        XCTAssertEqual(app.buttons["libraryPlayPause"].label, "Pause")
        app.buttons["libraryPlayPause"].tap()
    }

    func testLibraryPlaybackRenameAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-library", "--seed-library"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let mixTitle = "Evening study (Slowed + Reverb)"
        let mix = app.buttons["libraryTrack_" + mixTitle]
        XCTAssertTrue(mix.waitForExistence(timeout: 30))
        mix.tap()
        XCTAssertEqual(app.buttons["libraryPlayPause"].label, "Pause")
        XCTAssertTrue(app.staticTexts["libraryPlaybackMode"].label.contains("AS SAVED"))
        expectation(for: NSPredicate(format: "label != %@", "0:00"), evaluatedWith: app.staticTexts["libraryPosition"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["libraryNext"].isEnabled)
        app.sliders["librarySeekSlider"].adjust(toNormalizedSliderPosition: 1)
        expectation(for: NSPredicate(format: "label == %@", "Evening study"), evaluatedWith: app.staticTexts["libraryNowPlayingTitle"])
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.staticTexts["libraryNowPlayingTitle"].label, "Evening study")
        XCTAssertEqual(app.buttons["libraryPlayPause"].label, "Pause")
        app.buttons["libraryPlayPause"].tap()
        app.buttons["Options for " + mixTitle].tap()
        app.buttons["Rename"].tap()
        let title = app.textFields["renameTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else {
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: mixTitle.count))
        }
        title.typeText("Evening mix")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["libraryTrack_Evening mix"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Local library and as-saved playback"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["libraryTrack_Evening mix"].waitForExistence(timeout: 5))
        app.buttons["libraryTrack_Evening mix"].tap()
        XCTAssertTrue(app.staticTexts["libraryPlaybackMode"].label.contains("AS SAVED"))
        app.buttons["libraryPlayPause"].tap()
    }

    func testLibraryFolderPickerAndSaveMix() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-library", "--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["trackTitle"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        let save = app.buttons["saveLibraryMix"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        let failure = app.alerts["Could not complete the action"]
        if failure.waitForExistence(timeout: 2) {
            XCTFail(failure.debugDescription)
            return
        }
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["libraryTrack_Evening study (Slowed + Reverb)"].waitForExistence(timeout: 30))
        app.buttons["libraryImportToolbar"].tap()
        app.buttons["chooseLibraryFolder"].tap()
        XCTAssertTrue(app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Select a folder from iPhone Files"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLiveControlsAndOriginalComparison() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["trackTitle"].waitForExistence(timeout: 15))
        app.buttons["playPauseButton"].tap()
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        let progressed = NSPredicate(format: "label != %@", "0:00")
        expectation(for: progressed, evaluatedWith: app.staticTexts["currentPosition"])
        waitForExpectations(timeout: 5)
        app.sliders["speedSlider"].adjust(toNormalizedSliderPosition: 0.2)
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        app.segmentedControls.buttons["Original"].tap()
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        app.segmentedControls.buttons["Slowed + reverb"].tap()
        app.scrollViews.firstMatch.swipeUp()
        app.sliders["reverbSlider"].adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        app.buttons["playPauseButton"].tap()
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Play")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Live effect controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInvalidLinkShowsActionableError() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Load a link"].tap()
        let field = app.textViews["sourceURLField"].exists ? app.textViews["sourceURLField"] : app.textFields["sourceURLField"]
        field.tap()
        field.typeText("https://example.com/song")
        app.buttons["loadSourceButton"].tap()
        XCTAssertTrue(app.staticTexts["sourceError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sourceError"].label.contains("YouTube"))
    }

    func testExportPresentsFilesPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["trackTitle"].waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp()
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "Accessible effect controls"
        controls.lifetime = .keepAlways
        add(controls)
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["trackOptions"].tap()
        app.collectionViews.buttons["Save slowed WAV"].tap()
        let save = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "WAV export picker"
        picker.lifetime = .keepAlways
        add(picker)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["trackOptions"].exists)
    }

    func testYouTubeLinkLoadsNativeAudio() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Load a link"].tap()
        let field = app.textViews["sourceURLField"].exists ? app.textViews["sourceURLField"] : app.textFields["sourceURLField"]
        field.tap()
        field.typeText("https://youtu.be/aqz-KE-bpKQ")
        app.buttons["loadSourceButton"].tap()
        XCTAssertTrue(app.staticTexts["trackTitle"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["trackTitle"].label.contains("Big Buck Bunny"))
        app.buttons["playPauseButton"].tap()
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        app.buttons["playPauseButton"].tap()
    }

    func testSpotifyLinkOpensPhoneSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Load a link"].tap()
        app.buttons["Spotify account"].tap()
        if app.buttons["spotifyConnectionButton"].exists {
            throw XCTSkip("This device already has a Spotify sign-in.")
        }
        let field = app.textViews["sourceURLField"].exists ? app.textViews["sourceURLField"] : app.textFields["sourceURLField"]
        field.tap()
        field.typeText("https://open.spotify.com/track/20I6sIOMTCkB6w7ryavxtO")
        app.buttons["loadSourceButton"].tap()
        XCTAssertTrue(app.staticTexts["sourceError"].label.contains("Sign in to Spotify"))
        let signIn = app.buttons["spotifySignInButton"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.alerts.firstMatch
        if consent.waitForExistence(timeout: 5), consent.buttons["Continue"].exists {
            consent.buttons["Continue"].tap()
        }
        let browser = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        XCTAssertTrue(browser.webViews.firstMatch.waitForExistence(timeout: 25))
        XCTAssertFalse(app.staticTexts["spotifySignInError"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Spotify system browser sign-in"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testSpotifyAudioConnectionWithSavedSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Load a link"].tap()
        app.buttons["Spotify account"].tap()
        let check = app.buttons["spotifyConnectionButton"]
        guard check.exists else { throw XCTSkip("This device has no saved Spotify sign-in.") }
        check.tap()
        let ready = app.staticTexts["spotifyConnectionReady"]
        let failure = app.staticTexts["spotifySignInError"]
        let deadline = Date().addingTimeInterval(40)
        while !ready.exists && !failure.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(ready.exists, failure.exists ? failure.label : "Spotify connection did not finish.")
    }

    func testSpotifyAudioLoadsWithSavedSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Load a link"].tap()
        app.buttons["Spotify account"].tap()
        guard app.buttons["spotifyConnectionButton"].exists else {
            throw XCTSkip("This device has no saved Spotify sign-in.")
        }
        let field = app.textViews["sourceURLField"].exists ? app.textViews["sourceURLField"] : app.textFields["sourceURLField"]
        field.tap()
        field.typeText("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
        app.buttons["loadSourceButton"].tap()
        let title = app.staticTexts["trackTitle"]
        let failure = app.staticTexts["sourceError"]
        let deadline = Date().addingTimeInterval(200)
        while !title.exists && !failure.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(title.exists, failure.exists ? failure.label : "Spotify audio did not finish loading.")
        guard title.exists else { return }
        app.buttons["playPauseButton"].tap()
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        expectation(for: NSPredicate(format: "label != %@", "0:00"), evaluatedWith: app.staticTexts["currentPosition"])
        waitForExpectations(timeout: 5)
        app.sliders["speedSlider"].adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        app.buttons["playPauseButton"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Spotify audio on the physical iPhone"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
