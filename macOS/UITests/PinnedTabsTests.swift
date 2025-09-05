//
//  PinnedTabsTests.swift
//
//  Copyright © 2024 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest

class PinnedTabsTests: UITestCase {
    private static let failureObserver = TestFailureObserver()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication.setUp()

        app.openNewWindow()
    }

    func testPinnedTabsFunctionality() {
        openThreeSitesOnSameWindow()
        openNewWindowAndLoadSite()
        moveBackToPreviousWindows()

        waitForSite(pageTitle: "Page #3")
        pinsPageOne()
        pinsPageTwo()
        assertsPageTwoIsPinned()
        assertsPageOneIsPinned()
        dragsPageTwoPinnedTabToTheFirstPosition()
        assertsCommandWFunctionality()
        assertWindowTwoHasNoPinnedTabsFromWindowsOne()
        app.terminate()
        assertPinnedTabsRestoredState()
    }

    // MARK: - Utilities

    private func openThreeSitesOnSameWindow() {
        app.openSite(pageTitle: "Page #1")
        app.openNewTab()
        app.openSite(pageTitle: "Page #2")
        app.openNewTab()
        app.openSite(pageTitle: "Page #3")
    }

    private func openNewWindowAndLoadSite() {
        app.openNewWindow()
        app.openSite(pageTitle: "Page #4")
    }

    private func moveBackToPreviousWindows() {
        let menuItem = app.menuItems["Page #3"].firstMatch
        XCTAssertTrue(
            menuItem.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Reset bookmarks menu item didn't become available in a reasonable timeframe."
        )
        menuItem.hover()
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    }

    private func pinsPageOne() {
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.menuItems["Pin Tab"].tap()
    }

    private func pinsPageTwo() {
        app.typeKey("]", modifierFlags: [.command, .shift])
        app.menuItems["Pin Tab"].tap()
    }

    private func assertsPageTwoIsPinned() {
        XCTAssertTrue(app.menuItems["Unpin Tab"].firstMatch.waitForExistence(timeout: UITests.Timeouts.elementExistence))
        XCTAssertTrue(app.menuItems["Unpin Tab"].firstMatch.exists)
        XCTAssertFalse(app.menuItems["Pin Tab"].firstMatch.exists)
    }

    private func assertsPageOneIsPinned() {
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.menuItems["Unpin Tab"].firstMatch.exists)
        XCTAssertFalse(app.menuItems["Pin Tab"].firstMatch.exists)
    }

    private func dragsPageTwoPinnedTabToTheFirstPosition() {
        app.typeKey("]", modifierFlags: [.command, .shift])
        let toolbar = app.toolbars.firstMatch
        let toolbarCoordinate = toolbar.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let startPoint = toolbarCoordinate.withOffset(CGVector(dx: 128, dy: -15))
        let endPoint = toolbarCoordinate.withOffset(CGVector(dx: 0, dy: 0))
        startPoint.press(forDuration: 0, thenDragTo: endPoint)

        sleep(1)

        /// Asserts the re-order worked by moving to the next tab and checking is Page #1
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Sample text for Page #1"].exists)
    }

    private func assertsCommandWFunctionality() {
        app.closeCurrentTab()
        XCTAssertTrue(app.staticTexts["Sample text for Page #3"].exists)
    }

    private func assertWindowTwoHasNoPinnedTabsFromWindowsOne() {
        let items = app.menuItems.matching(identifier: "Page #4")
        let pageFourMenuItem = items.element(boundBy: 1)
        XCTAssertTrue(
            pageFourMenuItem.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "Reset bookmarks menu item didn't become available in a reasonable timeframe."
        )
        pageFourMenuItem.hover()
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        sleep(1)

        /// Goes to Page #2 to check the state
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.staticTexts["Sample text for Page #2"].exists)
        /// Goes to Page #1 to check the state
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.staticTexts["Sample text for Page #1"].exists)

        app.closeWindow()
    }

    private func assertPinnedTabsRestoredState() {
        let newApp = XCUIApplication.setUp()
        XCTAssertTrue(
            newApp.windows.firstMatch.waitForExistence(timeout: UITests.Timeouts.elementExistence),
            "App window didn't become available in a reasonable timeframe."
        )

        /// Goes to Page #2 to check the state
        newApp.typeKey("[", modifierFlags: [.command, .shift])
        newApp.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(newApp.staticTexts["Sample text for Page #2"].waitForExistence(timeout: UITests.Timeouts.elementExistence))
        /// Goes to Page #1 to check the state
        newApp.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(newApp.staticTexts["Sample text for Page #1"].waitForExistence(timeout: UITests.Timeouts.elementExistence))
    }

    private func waitForSite(pageTitle: String) {
        XCTAssertTrue(app.windows.webViews[pageTitle].waitForExistence(timeout: UITests.Timeouts.elementExistence))
    }
}
