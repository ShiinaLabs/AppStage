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
            makeRecorder: { _, _, _ in recorder }
        )
        try await workflow.run(
            scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
            token: "secret", sessionID: UUID(), timeout: .seconds(30),
            existingApplicationPolicy: .reject,
            outputURL: URL(fileURLWithPath: "/tmp/example.mov")
        )
        XCTAssertEqual(Array(log.values.prefix(4)), ["listenerReady", "launch", "handshake", "load:example"])
        XCTAssertTrue(log.values.contains("failureWaitCancelled"))
        XCTAssertEqual(log.values.suffix(3), ["recorderStop", "controllerClose", "appCleanup"])
    }

    func testScenarioFailureStillFinalizesAndCleansUp() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log, failOnFinished: true),
            openSession: { _, _ in log.append("launch"); return FakeSession(log: log) },
            makeRecorder: { _, _, _ in FakeRecorder(log: log) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject,
                outputURL: URL(fileURLWithPath: "/tmp/example.mov")
            )
            XCTFail("Expected scenario failure")
        } catch StageControlError.remoteFailure {
            XCTAssertTrue(log.values.suffix(4).elementsEqual(["recorderStop", "discardOutput", "controllerClose", "appCleanup"]))
        }
    }

    func testRunDiscoveryStartsListsAndClosesTheDiscoveryProcess() async throws {
        let log = Log()
        let scenarios = [StageScenarioMetadata(id: StageScenarioID("walkthrough"))]
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log, scenarios: scenarios),
            openSession: { arguments, _ in
                let launch = try StageLaunchConfiguration(arguments: arguments)
                XCTAssertNil(launch.scenarioID)
                XCTAssertTrue(launch.discoverScenarios)
                log.append("launch")
                return FakeSession(log: log)
            },
            makeRecorder: { _, _, _ in XCTFail("Discovery must not record"); return FakeRecorder(log: log) }
        )

        let discovered = try await workflow.runDiscovery(
            bundleIdentifier: "com.example.fixture",
            token: "secret",
            sessionID: UUID(),
            timeout: .seconds(30),
            existingApplicationPolicy: .reject
        )

        XCTAssertEqual(discovered.map(\.id.rawValue), ["walkthrough"])
        XCTAssertEqual(log.values, ["listenerReady", "launch", "handshake", "list", "controllerClose", "appCleanup"])
    }

    func testRunDiscoveryClosesTheProcessWhenListingFails() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log, failOnList: true),
            openSession: { arguments, _ in
                let launch = try StageLaunchConfiguration(arguments: arguments)
                XCTAssertTrue(launch.discoverScenarios)
                log.append("launch")
                return FakeSession(log: log)
            },
            makeRecorder: { _, _, _ in XCTFail("Discovery must not record"); return FakeRecorder(log: log) }
        )

        do {
            _ = try await workflow.runDiscovery(
                bundleIdentifier: "com.example.fixture",
                token: "secret",
                sessionID: UUID(),
                timeout: .seconds(30),
                existingApplicationPolicy: .reject
            )
            XCTFail("Expected discovery failure")
        } catch StageControlError.remoteFailure {}

        XCTAssertEqual(log.values.suffix(2), ["controllerClose", "appCleanup"])
    }

    func testExistingApplicationRejectionSkipsCaptureAndCleanup() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log),
            openSession: { _, _ in throw StageAppSessionError.targetAlreadyRunning },
            makeRecorder: { _, _, _ in XCTFail("Must not create recorder"); return FakeRecorder(log: log) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject,
                outputURL: URL(fileURLWithPath: "/tmp/example.mov")
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
            makeRecorder: { _, _, _ in FakeRecorder(log: log, cancelOnStop: true) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject,
                outputURL: URL(fileURLWithPath: "/tmp/example.mov")
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(log.values.suffix(4), ["recorderStop", "discardOutput", "controllerClose", "appCleanup"])
        }
    }

    func testRecorderRuntimeFailureWinsRaceAndDiscardsOutput() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log, blockFinishedUntilCancelled: true),
            openSession: { _, _ in log.append("launch"); return FakeSession(log: log) },
            makeRecorder: { _, _, _ in FakeRecorder(log: log, failDuringRecording: true) }
        )
        do {
            try await workflow.run(
                scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
                token: "secret", sessionID: UUID(), timeout: .seconds(30),
                existingApplicationPolicy: .reject,
                outputURL: URL(fileURLWithPath: "/tmp/example.mov")
            )
            XCTFail("Expected runtime recorder failure")
        } catch FixtureFailure.runtime {
            XCTAssertTrue(log.values.contains("finishedCancelled"))
            XCTAssertEqual(log.values.suffix(4), ["recorderStop", "discardOutput", "controllerClose", "appCleanup"])
            XCTAssertTrue(log.values.contains("discardOutput"))
        }
    }

    func testScenarioFinishWinsRaceAndCancelsFailureWaiter() async throws {
        let log = Log()
        let workflow = StageRecordWorkflow(
            controller: FakeController(log: log),
            openSession: { _, _ in log.append("launch"); return FakeSession(log: log) },
            makeRecorder: { _, _, _ in FakeRecorder(log: log) }
        )
        try await workflow.run(
            scenarioID: StageScenarioID("example"), bundleIdentifier: "com.example.fixture",
            token: "secret", sessionID: UUID(), timeout: .seconds(30),
            existingApplicationPolicy: .reject,
            outputURL: URL(fileURLWithPath: "/tmp/example.mov")
        )
        XCTAssertTrue(log.values.contains("finished"))
        XCTAssertTrue(log.values.contains("failureWaitCancelled"))
        XCTAssertEqual(log.values.suffix(3), ["recorderStop", "controllerClose", "appCleanup"])
    }
}

@MainActor private final class Log {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor private final class FakeController: StageRecordControlling {
    let log: Log
    let failOnFinished: Bool
    let blockFinishedUntilCancelled: Bool
    let scenarios: [StageScenarioMetadata]?
    let failOnList: Bool
    init(
        log: Log,
        failOnFinished: Bool = false,
        blockFinishedUntilCancelled: Bool = false,
        scenarios: [StageScenarioMetadata]? = nil,
        failOnList: Bool = false
    ) {
        self.log = log
        self.failOnFinished = failOnFinished
        self.blockFinishedUntilCancelled = blockFinishedUntilCancelled
        self.scenarios = scenarios
        self.failOnList = failOnList
    }
    func start() async throws -> UInt16 { log.append("listenerReady"); return 49152 }
    func bindExpectedPID(_ pid: Int32) async { XCTAssertEqual(pid, 123) }
    func waitForHandshake(timeout: Duration) async throws { log.append("handshake") }
    func request(_ command: StageControlCommand, timeout: Duration) async throws -> StageControlSnapshot {
        switch command {
        case .listScenarios:
            log.append("list")
            if failOnList { throw StageControlError.remoteFailure("fixture discovery failure") }
            return StageControlSnapshot(state: .connected, scenarios: scenarios)
        case let .loadScenario(id): log.append("load:\(id.rawValue)")
        case .prepare: log.append("prepare")
        case .play: log.append("play")
        default: XCTFail("Unexpected command")
        }
        return StageControlSnapshot(state: .connected)
    }
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws {
        switch kind {
        case .ready: log.append("ready")
        case .finished:
            log.append("finished")
            if blockFinishedUntilCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch { log.append("finishedCancelled"); throw error }
            }
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
    let failDuringRecording: Bool
    init(log: Log, cancelOnStop: Bool = false, failOnStart: Bool = false, failDuringRecording: Bool = false) {
        self.log = log
        self.cancelOnStop = cancelOnStop
        self.failOnStart = failOnStart
        self.failDuringRecording = failDuringRecording
    }
    func start() async throws {
        log.append("recorderStart")
        if failOnStart { throw FixtureFailure.start }
    }
    func stop() async throws {
        log.append("recorderStop")
        if cancelOnStop { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func waitForFailure() async throws -> Never {
        if failDuringRecording { log.append("failure"); throw FixtureFailure.runtime }
        log.append("failureWait")
        do { try await Task.sleep(for: .seconds(3_600)) }
        catch { log.append("failureWaitCancelled"); throw error }
        throw CancellationError()
    }
    func discardOutputIfOwned() async { log.append("discardOutput") }
}

private enum FixtureFailure: Error { case start, runtime }
