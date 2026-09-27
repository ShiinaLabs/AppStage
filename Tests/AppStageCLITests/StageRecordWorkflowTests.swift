import AppStage
import AppStageControl
import Foundation
import XCTest
@testable import AppStageCLI

@MainActor
final class StageRecordWorkflowTests: XCTestCase {
    func testControlledRecordingFinalizesBeforeOwnedApplicationCleanup() async throws {
        let log = Log()
        let controller = FakeController(log: log)
        let session = FakeSession(log: log)
        let recorder = FakeRecorder(log: log)
        let workflow = StageRecordWorkflow(
            controller: controller,
            openSession: { arguments, policy in
                XCTAssertEqual(policy, .reject)
                let launch = try StageLaunchConfiguration(arguments: arguments)
                XCTAssertEqual(launch.scenarioID, StageScenarioID("example"))
                XCTAssertEqual(launch.controlHost, "127.0.0.1")
                XCTAssertEqual(launch.controlPort, 49152)
                XCTAssertEqual(launch.controlToken, "secret")
                XCTAssertNotNil(launch.controlSession)
                XCTAssertFalse(launch.autoplay)
                log.append("launch")
                return session
            },
            makeRecorder: { _, _ in recorder }
        )
        try await workflow.run(
            scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
            token: "secret", sessionID: UUID(), timeout: .seconds(30),
            existingApplicationPolicy: .reject
        )
        XCTAssertEqual(log.values, [
            "listenerReady", "launch", "handshake", "load", "prepare", "ready",
            "recorderStart", "play", "finished", "recorderStop", "controllerClose", "appCleanup",
        ])
    }

    func testScenarioFailureStillFinalizesAndCleansUp() async throws {
        let log = Log()
        let controller = FakeController(log: log, failOnFinished: true)
        let session = FakeSession(log: log)
        let recorder = FakeRecorder(log: log)
        let workflow = StageRecordWorkflow(
            controller: controller,
            openSession: { _, _ in log.append("launch"); return session },
            makeRecorder: { _, _ in recorder }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject
            )
            XCTFail("Expected scenario failure")
        } catch StageControlError.remoteFailure {
            XCTAssertEqual(log.values.suffix(4), ["recorderStop", "discardOutput", "controllerClose", "appCleanup"])
        }
    }

    func testExistingApplicationRejectionSkipsCaptureAndCleanup() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log),
            openSession: { _, _ in throw StageAppSessionError.targetAlreadyRunning },
            makeRecorder: { _, _ in XCTFail("Must not create recorder"); return FakeRecorder(log: log) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject
            )
            XCTFail("Expected rejection")
        } catch StageAppSessionError.targetAlreadyRunning {
            XCTAssertEqual(log.values, ["listenerReady", "controllerClose"])
        }
    }

    func testCancellationDuringFinalizeStillCleansUpAndFails() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log),
            openSession: { _, _ in log.append("launch"); return FakeSession(log: log) },
            makeRecorder: { _, _ in FakeRecorder(log: log, cancelOnStop: true) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(log.values.suffix(4), ["recorderStop", "discardOutput", "controllerClose", "appCleanup"])
        }
    }

    func testRecorderStartFailureStillClosesControlAndOwnedApplication() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log),
            openSession: { _, policy in
                XCTAssertEqual(policy, .replace)
                log.append("launch")
                return FakeSession(log: log)
            },
            makeRecorder: { _, _ in FakeRecorder(log: log, failOnStart: true) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .replace
            )
            XCTFail("Expected recorder failure")
        } catch FixtureFailure.start {
            XCTAssertEqual(log.values.suffix(3), ["recorderStart", "controllerClose", "appCleanup"])
            XCTAssertFalse(log.values.contains("play"))
        }
    }
}

@MainActor private final class Log {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor private final class FakeController: StageRecordControlling {
    let log: Log
    let failOnFinished: Bool
    init(log: Log, failOnFinished: Bool = false) { self.log = log; self.failOnFinished = failOnFinished }
    func start() async throws -> UInt16 { log.append("listenerReady"); return 49152 }
    func bindExpectedPID(_ pid: Int32) async { XCTAssertEqual(pid, 123) }
    func waitForHandshake(timeout: Duration) async throws { log.append("handshake") }
    func request(_ command: StageControlCommand, timeout: Duration) async throws {
        switch command {
        case .loadScenario: log.append("load")
        case .prepare: log.append("prepare")
        case .play: log.append("play")
        default: XCTFail("Unexpected command")
        }
    }
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws {
        switch kind {
        case .ready: log.append("ready")
        case .finished:
            log.append("finished")
            if failOnFinished { throw StageControlError.remoteFailure("fixture failure") }
        default: XCTFail("Unexpected event")
        }
    }
    func close() async { log.append("controllerClose") }
}

@MainActor private final class FakeSession: StageRecordSessioning {
    let processIdentifier: pid_t = 123
    let bundleIdentifier = "com.example.fixture"
    let log: Log
    init(log: Log) { self.log = log }
    func finish() async { log.append("appCleanup") }
}

@MainActor private final class FakeRecorder: StageRecordRecording {
    let log: Log
    let cancelOnStop: Bool
    let failOnStart: Bool
    init(log: Log, cancelOnStop: Bool = false, failOnStart: Bool = false) {
        self.log = log
        self.cancelOnStop = cancelOnStop
        self.failOnStart = failOnStart
    }
    func start() async throws {
        log.append("recorderStart")
        if failOnStart { throw FixtureFailure.start }
    }
    func stop() async throws {
        log.append("recorderStop")
        if cancelOnStop { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func discardOutputIfOwned() async { log.append("discardOutput") }
}

private enum FixtureFailure: Error { case start }
