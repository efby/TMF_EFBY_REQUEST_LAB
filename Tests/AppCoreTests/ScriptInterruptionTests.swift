import EfbyPresentation
import Foundation
import XCTest
#if os(macOS)
import Darwin

final class ScriptInterruptionTests: XCTestCase {
    private static let scenarioKey = "EFBY_ISOLATED_SCRIPT_INTERRUPTION_SCENARIO"

    // Infinite-loop cases run in child test processes. A broken native watchdog must fail a
    // test within ten seconds rather than leave swift test hanging forever.
    func testInfiniteExecutionScenariosInIsolatedProcesses() throws {
        for scenario in ["script", "utility", "expression", "message", "done", "cancel", "recovery"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest", "-XCTest", "AppCoreTests.ScriptInterruptionTests/testIsolatedInterruptionWorker",
                Bundle(for: ScriptInterruptionTests.self).bundleURL.path,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment[Self.scenarioKey] = scenario
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + 10) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                XCTFail("Native JavaScript watchdog did not interrupt scenario '\(scenario)' before the external deadline.")
                continue
            }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // A failed test host can print its entire environment. Keep that out of test logs.
            let diagnostic = text.components(separatedBy: "\n").filter { $0.contains(": error:") }.joined(separator: "\n")
            XCTAssertEqual(process.terminationStatus, 0, "Isolated scenario '\(scenario)' failed: \(diagnostic)")
            XCTAssertTrue(text.contains("EFBY_SCRIPT_INTERRUPTION_SUCCESS:\(scenario)"),
                "Child did not finish the selected scenario '\(scenario)': \(text)")
        }
    }

    func testIsolatedInterruptionWorker() async throws {
        guard let scenario = ProcessInfo.processInfo.environment[Self.scenarioKey] else { return }
        let engine = ScriptEngine(executionTimeLimit: scenario == "cancel" ? 5 : 0.08)
        let variable = VariableValue(key: "keep", value: "original")
        let profile = EnvironmentProfile(name: "QA", variables: [variable])
        var runtime = ScriptRuntimeContext(
            globals: ["keep": "original"], collection: ["keep": "original"],
            environment: ["keep": "original"], environments: [profile], activeEnvironmentID: profile.id,
            local: ["keep": "original"]
        )
        let infinite = #"pm.environment.set("keep", "partial"); while (true) {}"#
        let report: ScriptExecutionReport
        switch scenario {
        case "utility":
            report = engine.execute(scripts: [script(#"console.log("must-not-run");"#)], event: .preRequest, runtime: runtime,
                utilities: [WorkspaceScriptUtility(name: "Infinite utility", source: infinite)])
        case "expression":
            let result = try XCTUnwrap(engine.evaluateTemplateExpressionReport(
                "(function() { \(infinite) })()", runtime: runtime
            ))
            assertDeadline(result.interruption)
            XCTAssertNil(result.value)
            XCTAssertEqual(result.runtime.environment, runtime.environment)
            XCTAssertEqual(result.runtime.environments, runtime.environments)
            print("EFBY_SCRIPT_INTERRUPTION_SUCCESS:\(scenario)")
            return
        case "message", "done":
            let handler = scenario == "message" ? "onMessage" : "onDone"
            runtime.webSocketMessage = scenario == "message" ? "incoming" : nil
            runtime.webSocketDoneCause = scenario == "done" ? "closed" : nil
            report = engine.execute(scripts: [script("pm.websocket.\(handler)(function() { \(infinite) });")],
                event: .preRequest, runtime: runtime)
            XCTAssertTrue(report.runtime.webSocketShouldDisconnect)
        case "cancel":
            let initial = runtime
            let task = Task.detached {
                engine.execute(scripts: [selfScript(infinite)], event: .preRequest, runtime: initial)
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            report = await task.value
            XCTAssertEqual(report.interruption, .cancelled)
            XCTAssertThrowsError(try report.checkInterruption()) { XCTAssertTrue($0 is CancellationError) }
        case "script", "recovery":
            report = engine.execute(scripts: [
                script(#"pm.globals.set("keep", "partial");"#),
                script(infinite), script(#"console.log("must-not-run");"#),
            ], event: .preRequest, runtime: runtime)
        default:
            XCTFail("Unknown isolated scenario: \(scenario)")
            return
        }
        if scenario != "cancel" { assertDeadline(report.interruption) }
        XCTAssertEqual(report.runtime.environment, runtime.environment)
        XCTAssertEqual(report.runtime.environments, runtime.environments)
        XCTAssertEqual(report.runtime.globals, runtime.globals)
        XCTAssertEqual(report.runtime.collection, runtime.collection)
        XCTAssertEqual(report.runtime.local, runtime.local)
        XCTAssertFalse(report.logs.contains("must-not-run"))

        // Use the same engine after an interruption: a fresh context must remain usable.
        let next = engine.execute(scripts: [script(#"pm.environment.set("next", "ok");"#)],
            event: .preRequest, runtime: runtime)
        XCTAssertNil(next.interruption)
        XCTAssertEqual(next.runtime.environment["next"], "ok")
        print("EFBY_SCRIPT_INTERRUPTION_SUCCESS:\(scenario)")
    }

    func testInvalidExecutionBudgetsUseSafeDefaultAndMinimum() {
        for invalid in [TimeInterval.nan, .infinity, 0, -1] {
            XCTAssertEqual(ScriptEngine(executionTimeLimit: invalid).executionTimeLimit, 5)
        }
        XCTAssertEqual(ScriptEngine(executionTimeLimit: 0.001).executionTimeLimit, 0.01)
    }

    func testReportCheckDistinguishesCancellationAndDeadline() {
        let runtime = ScriptRuntimeContext()
        XCTAssertNoThrow(try ScriptExecutionReport(runtime: runtime, logs: []).checkInterruption())
        XCTAssertThrowsError(try ScriptExecutionReport(runtime: runtime, logs: [], interruption: .cancelled).checkInterruption()) {
            XCTAssertTrue($0 is CancellationError)
        }
        let deadline = ScriptExecutionInterruption.timeLimitExceeded(seconds: 0.1)
        XCTAssertThrowsError(try TemplateExpressionEvaluationReport(value: nil, runtime: runtime, logs: [], interruption: deadline).checkInterruption()) {
            XCTAssertEqual($0 as? ScriptExecutionInterruption, deadline)
        }
    }

    private func script(_ source: String) -> ScriptDefinition { selfScript(source) }

    private func assertDeadline(_ interruption: ScriptExecutionInterruption?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .some(.timeLimitExceeded(seconds: _)) = interruption else {
            XCTFail("Expected deadline interruption, got \(String(describing: interruption))", file: file, line: line)
            return
        }
    }
}

private func selfScript(_ source: String) -> ScriptDefinition {
    ScriptDefinition(name: "Interruption probe", listen: .preRequest, language: "javascript", source: source)
}
#endif
