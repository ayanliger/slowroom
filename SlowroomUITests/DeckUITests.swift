import XCTest

@MainActor
final class DeckUITests: XCTestCase {
    func testOriginalCleanupPreservesLibraryPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-library", "--seed-library", "--large-cleanup-fixtures"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let mix = app.buttons["libraryTrack_Evening study (Slowed + Reverb)"]
        XCTAssertTrue(mix.waitForExistence(timeout: 120))
        app.buttons["libraryOptions"].tap()
        app.buttons["Delete imported originals"].tap()
        app.buttons["findTestOriginals"].tap()
        XCTAssertTrue(app.staticTexts["cleanupMatchedCount"].waitForExistence(timeout: 60))
        XCTAssertEqual(app.staticTexts["cleanupMatchedCount"].label, "2 matched originals")
        app.buttons["deleteMatchedOriginals"].tap()
        XCTAssertTrue(app.staticTexts["cleanupResultCount"].waitForExistence(timeout: 60))
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

    func testSpotifyLinkFindsYouTubeVersionAndPlaysAudio() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Load a link"].tap()
        let field = app.textViews["sourceURLField"].exists ? app.textViews["sourceURLField"] : app.textFields["sourceURLField"]
        field.tap()
        field.typeText("https://open.spotify.com/track/20I6sIOMTCkB6w7ryavxtO")
        XCTAssertEqual(app.buttons["loadSourceButton"].label, "Find on YouTube")
        app.buttons["loadSourceButton"].tap()
        let match = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "youtubeMatch_")).firstMatch
        let failure = app.staticTexts["sourceError"]
        expectation(for: NSPredicate { _, _ in match.exists || failure.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 60)
        XCTAssertTrue(match.exists, failure.exists ? failure.label : "No YouTube matches appeared.")
        guard match.exists else { return }
        XCTAssertEqual(app.staticTexts["spotifyMatchTitle"].label, "Call Me Maybe")
        XCTAssertFalse(app.buttons["spotifySignInButton"].exists)
        let matches = XCTAttachment(screenshot: app.screenshot())
        matches.name = "YouTube versions for a Spotify track"
        matches.lifetime = .keepAlways
        add(matches)
        match.tap()
        let title = app.staticTexts["trackTitle"]
        expectation(for: NSPredicate { _, _ in title.exists || failure.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        XCTAssertTrue(title.exists, failure.exists ? failure.label : "The selected YouTube audio did not load.")
        guard title.exists else { return }
        XCTAssertTrue(title.label.localizedCaseInsensitiveContains("Call Me Maybe"))
        XCTAssertTrue(app.staticTexts["YOUTUBE"].exists)
        app.buttons["playPauseButton"].tap()
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        expectation(for: NSPredicate(format: "label != %@", "0:00"), evaluatedWith: app.staticTexts["currentPosition"])
        waitForExpectations(timeout: 5)
        app.sliders["speedSlider"].adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Pause")
        app.buttons["playPauseButton"].tap()
        let audio = XCTAttachment(screenshot: app.screenshot())
        audio.name = "Spotify match playing from YouTube"
        audio.lifetime = .keepAlways
        add(audio)
        app.buttons["trackOptions"].tap()
        app.buttons["Load a link"].tap()
        XCTAssertTrue(app.buttons["loadSourceButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["spotifyMatchTitle"].exists)
        XCTAssertFalse(match.exists)
    }

}
