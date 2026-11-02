import Foundation
import XCTest

@MainActor
final class RequestLabUITests: XCTestCase {
    private let alphaRequestID = "11111111-1111-1111-1111-111111111111"
    private let slowRequestID = "33333333-3333-3333-3333-333333333333"
    private let slowNodeID = "44444444-4444-4444-4444-444444444444"

    func testNavigationBetweenEditorResponsePanesAndEnvironmentSheet() throws {
        let (app, _) = try launchFixture()
        let originalURL = element("request.url", in: app).value as? String

        for name in ["Docs", "Params", "Authorization", "Headers", "Body", "Scripts", "Settings"] {
            let button = element("request.editor.tab.\(name)", in: app)
            try click(button)
            assertValue("selected", on: button)
            if let heading = ["Docs": "Request Summary", "Params": "Query Params", "Settings": "Request Settings"][name] {
                let contentHeading = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", heading, heading)).firstMatch
                XCTAssertTrue(contentHeading.waitForExistence(timeout: 5), "Selecting \(name) must display its content.")
            }
        }
        for name in ["Headers", "HTTP", "Console", "Response"] {
            let button = element("response.tab.\(name)", in: app)
            try click(button)
            assertValue("selected", on: button)
        }

        try click(element("environment.edit", in: app))
        let environmentName = element("environment.name", in: app)
        XCTAssertTrue(environmentName.waitForExistence(timeout: 5))
        assertValue("Alpha Environment", on: environmentName)
        try click(element("environment.done", in: app))
        waitUntil("Environment sheet closes") { !environmentName.exists }
        assertValue(originalURL ?? "", on: element("request.url", in: app))
        assertValue("selected", on: element("request.tab.\(alphaRequestID)", in: app))
    }

    func testOpeningSelectingCreatingAndClosingRequestTabsPreservesDrafts() throws {
        let (app, server) = try launchFixture()
        let draftURL = server.baseURL.appendingPathComponent("success").absoluteString + "?draft=tab"
        try replaceText(in: element("request.url", in: app), with: draftURL)
        try click(element("request.editor.tab.Settings", in: app))
        try click(element("sidebar.request.\(slowNodeID)", in: app))
        waitUntil("Both collection requests have tabs") { self.requestTabs(in: app).count == 2 }
        assertValue("selected", on: element("request.tab.\(slowRequestID)", in: app))
        assertValue(server.baseURL.appendingPathComponent("slow").absoluteString, on: element("request.url", in: app))
        try click(element("request.editor.tab.Params", in: app))

        try click(element("request.tab.\(alphaRequestID)", in: app))
        assertValue(draftURL, on: element("request.url", in: app))
        assertValue("selected", on: element("request.editor.tab.Settings", in: app))
        try click(element("request.tab.\(slowRequestID)", in: app))
        assertValue("selected", on: element("request.editor.tab.Params", in: app))
        try click(element("request.tab.\(alphaRequestID)", in: app))
        try click(element("request.tab.new", in: app))
        waitUntil("A new request has its own selected tab") { self.requestTabs(in: app).count == 3 }
        XCTAssertEqual(text(of: element("request.name", in: app)), "Untitled Request")
        let selectedTab = requestTabs(in: app).matching(NSPredicate(format: "value == %@", "selected")).firstMatch
        let newRequestID = String(selectedTab.identifier.dropFirst("request.tab.".count))
        XCTAssertFalse(newRequestID.isEmpty)
        try click(element("request.tab.close.\(newRequestID)", in: app))
        waitUntil("Closing the new tab leaves both collection requests") { self.requestTabs(in: app).count == 2 }
        try click(element("request.tab.close.\(slowRequestID)", in: app))
        waitUntil("Closing the slow request selects the remaining draft") { self.requestTabs(in: app).count == 1 }
        assertValue(draftURL, on: element("request.url", in: app))
        try click(element("request.tab.close.\(alphaRequestID)", in: app))
        waitUntil("Closing the last tab creates a usable new request") {
            self.requestTabs(in: app).count == 1 && self.text(of: self.element("request.name", in: app)) == "Untitled Request"
        }
        XCTAssertTrue(element("request.send", in: app).isEnabled)
    }

    func testRelaunchRestoresPreviouslySelectedWorkspace() throws {
        let (app, server) = try launchFixture()
        try selectWorkspace("Beta", in: app)
        waitUntil("Beta is selected before closing the application") {
            self.text(of: self.element("request.name", in: app)) == "Beta GET"
        }
        quitAndWaitForPersistence(app)
        let storageURL = try fixtureWorkspaceStorageURL(for: app)
        let savedState = try readFixtureWorkspace(at: storageURL)
        XCTAssertEqual(savedState["activeWorkspaceName"] as? String, "Beta")

        app.launch()
        try assertRestoredBeta(in: app, server: server)
    }

    func testRelaunchRecoversWorkspaceWithUnresolvableLegacyBookmark() throws {
        let (app, server) = try launchFixture()
        try selectWorkspace("Beta", in: app)
        waitUntil("Beta is selected before simulating a previous-version bookmark") {
            self.text(of: self.element("request.name", in: app)) == "Beta GET"
        }
        quitAndWaitForPersistence(app)
        let storageURL = try fixtureWorkspaceStorageURL(for: app)
        var savedState = try readFixtureWorkspace(at: storageURL)
        XCTAssertEqual(savedState["activeWorkspaceName"] as? String, "Beta")
        let previousDirectory = try XCTUnwrap(savedState["sharedCollectionsDirectoryPath"] as? String)
        let obsoleteBookmark = Data("Unresolvable bookmark from a previous application version".utf8).base64EncodedString()
        savedState["sharedCollectionsDirectoryBookmarkData"] = obsoleteBookmark
        try JSONSerialization.data(withJSONObject: savedState, options: [.sortedKeys])
            .write(to: storageURL, options: .atomic)

        app.launch()
        try assertRestoredBeta(in: app, server: server)
        quitAndWaitForPersistence(app)
        let repairedState = try readFixtureWorkspace(at: storageURL)
        XCTAssertEqual(repairedState["activeWorkspaceName"] as? String, "Beta")
        XCTAssertEqual(repairedState["sharedCollectionsDirectoryPath"] as? String, previousDirectory)
        let repairedBookmark = try XCTUnwrap(repairedState["sharedCollectionsDirectoryBookmarkData"] as? String)
        XCTAssertNotEqual(repairedBookmark, obsoleteBookmark, "Recovery must persist the renewed directory bookmark.")
        XCTAssertFalse(try XCTUnwrap(Data(base64Encoded: repairedBookmark)).isEmpty)
    }

    func testWorkspaceSwitchRestoresItsTabsAndDraftWithoutLeakingOtherWorkspace() throws {
        let (app, server) = try launchFixture()
        try click(element("request.tab.new", in: app))
        waitUntil("A standalone draft tab is selected") { self.requestTabs(in: app).count == 2 }
        let selectedDraft = requestTabs(in: app).matching(NSPredicate(format: "value == %@", "selected")).firstMatch
        let draftTabIdentifier = selectedDraft.identifier
        XCTAssertNotEqual(draftTabIdentifier, "request.tab.\(alphaRequestID)")
        XCTAssertEqual(text(of: element("request.name", in: app)), "Untitled Request")
        let draftURL = server.baseURL.appendingPathComponent("success").absoluteString + "?draft=workspace"
        try replaceText(in: element("request.url", in: app), with: draftURL)

        try selectWorkspace("Beta", in: app)
        waitUntil("Beta opens its own request") { self.text(of: self.element("request.name", in: app)) == "Beta GET" }
        XCTAssertEqual(requestTabs(in: app).count, 1)
        XCTAssertFalse(requestTab(named: "Alpha GET", in: app).exists)
        XCTAssertFalse(element(draftTabIdentifier, in: app).exists)
        assertValue(server.baseURL.appendingPathComponent("beta").absoluteString, on: element("request.url", in: app))
        try assertEnvironment(named: "Beta Environment", in: app)

        try selectWorkspace("Alpha", in: app)
        waitUntil("Alpha restores its standalone draft") {
            self.requestTabs(in: app).count == 1 && self.element(draftTabIdentifier, in: app).exists
        }
        assertValue("selected", on: element(draftTabIdentifier, in: app))
        assertValue(draftURL, on: element("request.url", in: app))
        XCTAssertEqual(text(of: element("request.name", in: app)), "Untitled Request")
        XCTAssertFalse(requestTab(named: "Beta GET", in: app).exists)
        try assertEnvironment(named: "Alpha Environment", in: app)
    }

    func testSendingARequestShowsRealHTTPResponseAndAddsHistory() throws {
        let (app, server) = try launchFixture()
        try click(element("request.send", in: app))
        waitUntil("The local server receives the request") { server.requestCount(for: "/success") == 1 }
        assertSuccessfulResponse("ui-success", in: app)
        waitUntil("Successful request is added to history") {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.history.")).count == 1
        }
        XCTAssertFalse(element("request.cancel", in: app).isEnabled)

        try click(element("response.tab.Headers", in: app))
        let contentTypeHeader = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Content-Type", "Content-Type")).firstMatch
        XCTAssertTrue(contentTypeHeader.waitForExistence(timeout: 5))
        try click(element("response.tab.HTTP", in: app))
        assertValue("selected", on: element("response.tab.HTTP", in: app))
    }

    func testCancelStopsTheRequestAndAllowsSendingAgain() throws {
        let (app, server) = try launchFixture()
        try click(element("sidebar.request.\(slowNodeID)", in: app))
        try click(element("request.send", in: app))
        waitUntil("The server holds the slow request") { server.requestCount(for: "/slow") == 1 }
        XCTAssertTrue(element("response.sending", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("request.cancel", in: app).isEnabled)

        try click(element("request.cancel", in: app))
        waitUntil("Cancel returns the editor to idle") { !self.element("request.cancel", in: app).isEnabled }
        waitUntil("Cancellation closes the HTTP connection") { server.cancelledSlowRequestCount == 1 }
        XCTAssertTrue(element("response.empty", in: app).exists)
        try click(element("response.tab.Console", in: app))
        let cancellationLine = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "response.console.line.", "Request cancelled.", "Request cancelled."
        )).firstMatch
        XCTAssertTrue(cancellationLine.waitForExistence(timeout: 5), "Console must show the cancellation message, including when selectable text is exposed as a text view.")
        server.releaseSlowResponses()
        XCTAssertFalse(element("response.status", in: app).waitForExistence(timeout: 1), "A cancelled response must not become visible.")

        try replaceText(in: element("request.url", in: app), with: server.baseURL.appendingPathComponent("success").absoluteString)
        try click(element("response.tab.Response", in: app))
        try click(element("request.send", in: app))
        waitUntil("The editor sends another request after cancellation") { server.requestCount(for: "/success") == 1 }
        assertSuccessfulResponse("ui-success", in: app)
        XCTAssertFalse(element("request.cancel", in: app).isEnabled)
    }

    func testSwitchingWorkspaceDuringARequestCancelsItAndDoesNotPublishIntoNewWorkspace() throws {
        let (app, server) = try launchFixture()
        try click(element("sidebar.request.\(slowNodeID)", in: app))
        try click(element("request.send", in: app))
        waitUntil("The slow request is in flight") { server.requestCount(for: "/slow") == 1 }
        try selectWorkspace("Beta", in: app)
        waitUntil("Beta becomes the current workspace") { self.text(of: self.element("request.name", in: app)) == "Beta GET" }
        waitUntil("Workspace change cancels Alpha's HTTP connection") { server.cancelledSlowRequestCount == 1 }
        server.releaseSlowResponses()
        XCTAssertFalse(element("response.status", in: app).waitForExistence(timeout: 1))
        XCTAssertFalse(element("request.cancel", in: app).isEnabled)
        XCTAssertEqual(requestTabs(in: app).count, 1)
        try click(element("request.send", in: app))
        waitUntil("Only Beta's own request is sent") { server.requestCount(for: "/beta") == 1 }
        assertSuccessfulResponse("ui-beta", in: app)
        let betaHistory = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.history."))
        waitUntil("Beta history contains only its own successful request") { betaHistory.count == 1 }
        XCTAssertTrue(betaHistory.firstMatch.label.contains("Beta GET"))

        try selectWorkspace("Alpha", in: app)
        let slowRequest = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "sidebar.request.", "Alpha Slow"
        )).firstMatch
        try click(slowRequest)
        waitUntil("The collection request reopens without its cancelled execution") {
            self.text(of: self.element("request.name", in: app)) == "Alpha Slow"
        }
        assertValue(server.baseURL.appendingPathComponent("slow").absoluteString, on: element("request.url", in: app))
        XCTAssertFalse(element("request.cancel", in: app).isEnabled)
        XCTAssertFalse(element("response.status", in: app).exists)
    }

    private func launchFixture() throws -> (XCUIApplication, TestHTTPServer) {
        continueAfterFailure = false
        let server = try TestHTTPServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("efby-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let defaultAppURL = repositoryRoot.appendingPathComponent(".build/ui-tests/EFBY Request Lab UI Tests.app")
        let appURL = ProcessInfo.processInfo.environment["EFBY_UI_TEST_APP_PATH"].map { URL(fileURLWithPath: $0) } ?? defaultAppURL
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
            throw NSError(domain: "RequestLabUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Build the UI test app with Tools/test_ui.sh before running the UI suite: \(appURL.path)"])
        }
        let app = XCUIApplication(url: appURL)
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = [
            "EFBY_UI_TEST_DIRECTORY": directory.path,
            "EFBY_UI_TEST_BASE_URL": server.baseURL.absoluteString
        ]
        addTeardownBlock { @MainActor [weak self] in
            if let self, self.testRun?.failureCount ?? 0 > 0 {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "UI at failure"
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Accessibility hierarchy at failure"
                hierarchy.lifetime = .keepAlways
                self.add(hierarchy)
            }
            if app.state != .notRunning { app.terminate() }
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        XCTAssertTrue(element("request.tab.\(alphaRequestID)", in: app).waitForExistence(timeout: 15), "The isolated Alpha workspace must load before interactions.")
        return (app, server)
    }

    private func quitAndWaitForPersistence(_ app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        waitUntil("The application saves its selected workspace before quitting", timeout: 15) {
            app.state == .notRunning
        }
    }

    private func fixtureWorkspaceStorageURL(for app: XCUIApplication) throws -> URL {
        let path = try XCTUnwrap(app.launchEnvironment["EFBY_UI_TEST_DIRECTORY"])
        let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        guard directory.lastPathComponent.hasPrefix("efby-ui-tests-") else {
            throw NSError(domain: "RequestLabUITests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Workspace metadata must only be edited inside the isolated UI test directory."
            ])
        }
        return directory.appendingPathComponent("workspace.json")
    }

    private func readFixtureWorkspace(at storageURL: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any])
    }

    private func assertRestoredBeta(in app: XCUIApplication, server: TestHTTPServer) throws {
        waitUntil("The previous session's selected Beta workspace is restored", timeout: 15) {
            self.text(of: self.element("request.name", in: app)) == "Beta GET"
        }
        XCTAssertEqual(requestTabs(in: app).count, 1)
        XCTAssertFalse(requestTab(named: "Alpha GET", in: app).exists)
        XCTAssertFalse(element("workspace.directory.required", in: app).exists)
        XCTAssertFalse(app.buttons["Use Repository"].exists, "A previously selected directory must not prompt for selection again.")
        assertValue(server.baseURL.appendingPathComponent("beta").absoluteString, on: element("request.url", in: app))
        try assertEnvironment(named: "Beta Environment", in: app)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func requestTabs(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@ AND identifier != %@", "request.tab.", "request.tab.close.", "request.tab.new"))
    }

    private func requestTab(named name: String, in app: XCUIApplication) -> XCUIElement {
        requestTabs(in: app).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func selectWorkspace(_ name: String, in app: XCUIApplication) throws {
        try click(element("workspace.selector", in: app))
        try click(element("workspace.option.\(name)", in: app))
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Workspace changes must display their existing information message.")
        let title = sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Info", "Info")).firstMatch
        XCTAssertTrue(title.exists, "Only the expected Info sheet should be acknowledged.")
        let workspaceMessage = sheet.staticTexts.matching(textContains(name)).firstMatch
        XCTAssertTrue(workspaceMessage.exists, "The information message must refer to the selected workspace '\(name)'.")
        try click(sheet.buttons["OK"])
        waitUntil("The workspace information sheet closes") { !sheet.exists }
    }

    private func assertEnvironment(named name: String, in app: XCUIApplication) throws {
        try click(element("environment.edit", in: app))
        let environmentName = element("environment.name", in: app)
        XCTAssertTrue(environmentName.waitForExistence(timeout: 5))
        assertValue(name, on: environmentName)
        try click(element("environment.done", in: app))
        waitUntil("Environment sheet closes") { !environmentName.exists }
    }

    private func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        guard element.exists || element.waitForExistence(timeout: 5) else {
            XCTFail("Missing UI control: \(element)", file: file, line: line)
            throw NSError(domain: "RequestLabUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing UI control"])
        }
        element.click()
    }

    private func replaceText(in field: XCUIElement, with value: String) throws {
        try click(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        assertValue(value, on: field)
    }

    private func assertSuccessfulResponse(_ marker: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let status = element("response.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "A successful response must become visible.", file: file, line: line)
        XCTAssertTrue(text(of: status).contains("200"), "Expected HTTP 200, got \(text(of: status))", file: file, line: line)
        let body = element("response.body", in: app)
        let visibleBodyText = body.descendants(matching: .any).matching(textContains(marker)).firstMatch
        XCTAssertTrue(visibleBodyText.waitForExistence(timeout: 10), "The displayed response body must contain \(marker).", file: file, line: line)
    }

    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func textContains(_ substring: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", substring, substring)
    }

    private func assertValue(_ value: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("Expected UI value '\(value)'", file: file, line: line) { (element.value as? String) == value }
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, condition: @escaping @MainActor () -> Bool) {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }
}
