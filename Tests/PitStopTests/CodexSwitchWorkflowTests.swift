import XCTest
@testable import PitStop

@MainActor
final class CodexSwitchWorkflowTests: XCTestCase {
    private struct TestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class FakeApplication: CodexApplicationControlling {
        var url: URL?
        var running: Bool
        var events: [String] = []
        var quitError: Error?
        var launchError: Error?

        init(installed: Bool = true, running: Bool = true) {
            url = installed ? URL(fileURLWithPath: "/Applications/ChatGPT.app") : nil
            self.running = running
        }

        func applicationURL() -> URL? { url }
        func isRunning() -> Bool { running }

        func quitNormallyIfRunning() async throws {
            guard running else { return }
            events.append("quit")
            if let quitError { throw quitError }
            running = false
        }

        func launch(at url: URL) async throws {
            events.append("launch")
            if let launchError { throw launchError }
            running = true
        }
    }

    func testRelaunchWrapsCredentialSwitchAndVerificationInOrder() async throws {
        let app = FakeApplication()
        let workflow = CodexSwitchWorkflow(application: app)

        let relaunched = try await workflow.run(relaunchApplication: true) {
            app.events.append("switch")
        } verifyCredentials: {
            app.events.append("verify")
            return true
        }

        XCTAssertTrue(relaunched)
        XCTAssertEqual(app.events, ["quit", "switch", "launch", "verify"])
    }

    func testDisabledRelaunchOnlySwitchesWhileCodexIsClosed() async throws {
        let app = FakeApplication(running: false)
        let workflow = CodexSwitchWorkflow(application: app)

        let relaunched = try await workflow.run(relaunchApplication: false) {
            app.events.append("switch")
        } verifyCredentials: {
            app.events.append("verify")
            return true
        }

        XCTAssertFalse(relaunched)
        XCTAssertEqual(app.events, ["switch", "verify"])
    }

    func testDisabledRelaunchRejectsSwitchWhileCodexIsOpen() async {
        let app = FakeApplication()
        let workflow = CodexSwitchWorkflow(application: app)

        do {
            _ = try await workflow.run(relaunchApplication: false) {
                app.events.append("switch")
            } verifyCredentials: { true }
            XCTFail("Expected the open-app rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Codex is open. Close it before switching accounts, or enable Codex relaunch in Settings")
        }
        XCTAssertEqual(app.events, [])
    }

    func testMissingDesktopAppKeepsCLISwitchWorking() async throws {
        let app = FakeApplication(installed: false, running: false)
        let workflow = CodexSwitchWorkflow(application: app)

        let relaunched = try await workflow.run(relaunchApplication: true) {
            app.events.append("switch")
        } verifyCredentials: {
            app.events.append("verify")
            return true
        }

        XCTAssertFalse(relaunched)
        XCTAssertEqual(app.events, ["switch", "verify"])
    }

    func testQuitFailurePreventsCredentialSwitch() async {
        let app = FakeApplication()
        app.quitError = TestError(message: "quit failed")
        let workflow = CodexSwitchWorkflow(application: app)

        do {
            _ = try await workflow.run(relaunchApplication: true) {
                app.events.append("switch")
            } verifyCredentials: { true }
            XCTFail("Expected the quit failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "quit failed")
        }
        XCTAssertEqual(app.events, ["quit"])
    }

    func testCredentialFailureReopensPreviouslyRunningCodex() async {
        let app = FakeApplication()
        let workflow = CodexSwitchWorkflow(application: app)

        do {
            _ = try await workflow.run(relaunchApplication: true) {
                app.events.append("switch")
                throw TestError(message: "switch failed")
            } verifyCredentials: { true }
            XCTFail("Expected the credential failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "switch failed")
        }
        XCTAssertEqual(app.events, ["quit", "switch", "launch"])
    }

    func testCredentialFailureDoesNotOpenPreviouslyClosedCodex() async {
        let app = FakeApplication(running: false)
        let workflow = CodexSwitchWorkflow(application: app)

        do {
            _ = try await workflow.run(relaunchApplication: true) {
                app.events.append("switch")
                throw TestError(message: "switch failed")
            } verifyCredentials: { true }
            XCTFail("Expected the credential failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "switch failed")
        }
        XCTAssertEqual(app.events, ["switch"])
    }

    func testLaunchFailureReportsPostSwitchState() async {
        let app = FakeApplication()
        app.launchError = TestError(message: "launch failed")
        let workflow = CodexSwitchWorkflow(application: app)

        do {
            _ = try await workflow.run(relaunchApplication: true) {
                app.events.append("switch")
            } verifyCredentials: { true }
            XCTFail("Expected the launch failure")
        } catch {
            XCTAssertTrue(error is CodexSwitchWorkflow.PostSwitchError)
            XCTAssertEqual(error.localizedDescription,
                           "The account was changed, but Codex could not be reopened: launch failed")
        }
        XCTAssertEqual(app.events, ["quit", "switch", "launch"])
    }

    func testVerificationFailureIsReportedAfterRelaunch() async {
        let app = FakeApplication()
        let workflow = CodexSwitchWorkflow(application: app)

        do {
            _ = try await workflow.run(relaunchApplication: true) {
                app.events.append("switch")
            } verifyCredentials: {
                app.events.append("verify")
                return false
            }
            XCTFail("Expected the verification failure")
        } catch {
            XCTAssertTrue(error is CodexSwitchWorkflow.PostSwitchError)
            XCTAssertEqual(error.localizedDescription,
                           "Codex reopened, but auth.json does not contain the selected account")
        }
        XCTAssertEqual(app.events, ["quit", "switch", "launch", "verify"])
    }
}
