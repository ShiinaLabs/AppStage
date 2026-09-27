import AppStage
import AppStageCapture
import AppStageControl
import Foundation
import XCTest
@testable import AppStageCLI

@MainActor
final class StageBatchRecordWorkflowTests: XCTestCase {
    func testBatchUsesOneSessionInHostOrderAndWritesCompletedManifest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = [
            StageScenarioMetadata(id: StageScenarioID("second"), displayName: "Second", durationMilliseconds: 12),
            StageScenarioMetadata(id: StageScenarioID("first"), displayName: nil),
        ]
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios)
        try await workflow.run()

        XCTAssertEqual(log.values.filter { $0 == "launch" }.count, 1)
        XCTAssertEqual(log.values.filter { $0 == "handshake" }.count, 1)
        XCTAssertEqual(log.values.filter { $0 == "list" }.count, 1)
        XCTAssertEqual(log.values.filter { $0.hasPrefix("load:") }, ["load:second", "load:first"])
        XCTAssertFalse(log.values.contains("reset"))

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(StageCaptureManifest.self, from: data)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.status, .completed)
        XCTAssertEqual(manifest.capture.width, 1_920)
        XCTAssertEqual(manifest.capture.height, 1_080)
        XCTAssertNil(manifest.capture.backgroundImage)
        XCTAssertEqual(manifest.scenarios.map(\.output), ["second.mov", "first.mov"])
        XCTAssertEqual(manifest.scenarios.map(\.status), [.completed, .completed])
        XCTAssertNil(manifest.scenarios[0].error)
        XCTAssertNil(manifest.scenarios[1].displayName)
        XCTAssertNil(manifest.scenarios[1].declaredDurationMilliseconds)
    }

    func testBatchFailureIsFailFastAndManifestRetainsCompletedFailedAndPending() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = ["a", "b", "c"].map { StageScenarioMetadata(id: StageScenarioID($0)) }
        let workflow = makeBatchWorkflow(
            directory: directory, log: log, scenarios: scenarios, failScenario: "b",
            controller: BatchFakeController(log: log, scenarios: scenarios, blockFinishedScenario: "b")
        )
        do {
            try await workflow.run()
            XCTFail("Expected the second scenario to fail")
        } catch BatchFixtureError.recording {}

        XCTAssertEqual(log.values.filter { $0.hasPrefix("load:") }, ["load:a", "load:b"])
        let manifest = try JSONDecoder().decode(
            StageCaptureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .failed)
        XCTAssertEqual(manifest.scenarios.map(\.status), [.completed, .failed, .pending])
        XCTAssertEqual(manifest.scenarios[1].error, "The recording fixture failed.")
        XCTAssertEqual(manifest.scenarios.map(\.output), ["a.mov", "b.mov", "c.mov"])
    }

    func testBatchCancellationMarksCurrentScenarioCancelledAndPreservesManifest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = [StageScenarioMetadata(id: StageScenarioID("active")), StageScenarioMetadata(id: StageScenarioID("pending"))]
        let controller = BatchFakeController(log: log, scenarios: scenarios)
        var batchTask: Task<Void, any Error>?
        controller.onPlay = { batchTask?.cancel() }
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios, controller: controller)
        batchTask = Task { try await workflow.run() }
        do {
            try await batchTask?.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        XCTAssertTrue(log.values.contains { $0.hasPrefix("discard:") })
        let manifest = try JSONDecoder().decode(
            StageCaptureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
        XCTAssertEqual(manifest.scenarios.map(\.status), [.cancelled, .pending])
    }

    func testOutputNamingSanitizesUnsafeCharactersAndTraversalSeparators() throws {
        XCTAssertEqual(try StageCaptureOutputNaming.fileName(for: StageScenarioID("heatmap-demo")), "heatmap-demo.mov")
        XCTAssertEqual(try StageCaptureOutputNaming.fileName(for: StageScenarioID("../foo:bar")), "..-foo-bar.mov")
        XCTAssertEqual(
            StageCaptureOutputNaming.collisionKey(for: "Demo.mov"),
            StageCaptureOutputNaming.collisionKey(for: "demo.mov")
        )
        XCTAssertThrowsError(try StageCaptureOutputNaming.fileName(for: StageScenarioID("")))
    }

    func testFilenameCollisionFailsBeforeAnyScenarioStarts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = [StageScenarioMetadata(id: StageScenarioID("foo/bar")), StageScenarioMetadata(id: StageScenarioID("foo:bar"))]
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios)
        do {
            try await workflow.run()
            XCTFail("Expected filename collision")
        } catch StageBatchRecordError.filenameCollision {}
        XCTAssertFalse(log.values.contains { $0.hasPrefix("load:") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBatchWorkflow(
        directory: URL,
        log: BatchLog,
        scenarios: [StageScenarioMetadata],
        failScenario: String? = nil,
        controller: BatchFakeController? = nil
    ) -> StageBatchRecordWorkflow {
        let fakeController = controller ?? BatchFakeController(log: log, scenarios: scenarios)
        let recordWorkflow = StageRecordWorkflow(
            controller: fakeController,
            openSession: { arguments, _ in
                let launch = try StageLaunchConfiguration(arguments: arguments)
                XCTAssertNil(launch.scenarioID)
                XCTAssertTrue(launch.discoverScenarios)
                log.append("launch")
                return BatchFakeSession(log: log)
            },
            makeRecorder: { _, _, outputURL in
                BatchFakeRecorder(log: log, scenarioName: outputURL.deletingPathExtension().lastPathComponent,
                                  shouldFail: outputURL.deletingPathExtension().lastPathComponent == failScenario)
            }
        )
        let capture = try! StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: 220, verticalMargin: 120),
            includesApplicationWindows: true
        )
        return StageBatchRecordWorkflow(
            recordWorkflow: recordWorkflow,
            outputDirectory: directory,
            bundleIdentifier: "com.example.fixture",
            captureConfiguration: capture,
            horizontalMargin: 220,
            verticalMargin: 120,
            timeout: .seconds(5),
            token: "test-token",
            sessionID: UUID(),
            existingApplicationPolicy: .reject
        )
    }
}

@MainActor private final class BatchLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor private final class BatchFakeController: StageRecordControlling {
    let log: BatchLog
    let scenarios: [StageScenarioMetadata]
    let blockFinishedScenario: String?
    private var activeScenario: String?
    var onPlay: (() -> Void)?
    init(log: BatchLog, scenarios: [StageScenarioMetadata], blockFinishedScenario: String? = nil) {
        self.log = log
        self.scenarios = scenarios
        self.blockFinishedScenario = blockFinishedScenario
    }
    func start() async throws -> UInt16 { log.append("listener"); return 45_678 }
    func bindExpectedPID(_ pid: Int32) async { log.append("bind") }
    func waitForHandshake(timeout: Duration) async throws { log.append("handshake") }
    func request(_ command: StageControlCommand, timeout: Duration) async throws -> StageControlSnapshot {
        switch command {
        case .listScenarios:
            log.append("list")
            return StageControlSnapshot(state: .connected, scenarios: scenarios)
        case let .loadScenario(id):
            activeScenario = id.rawValue
            log.append("load:\(id.rawValue)")
        case .prepare: log.append("prepare")
        case .play: log.append("play"); onPlay?()
        default: XCTFail("Unexpected command")
        }
        return StageControlSnapshot(state: .connected)
    }
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws {
        switch kind {
        case .ready: log.append("ready")
        case .finished:
            log.append("finished")
            if activeScenario == blockFinishedScenario {
                try await Task.sleep(for: .seconds(3_600))
            }
        default: XCTFail("Unexpected event")
        }
    }
    func close() async { log.append("close") }
}

@MainActor private final class BatchFakeSession: StageRecordSessioning {
    let processIdentifier: pid_t = 321
    let bundleIdentifier = "com.example.fixture"
    let log: BatchLog
    init(log: BatchLog) { self.log = log }
    func finish() async { log.append("finishApp") }
}

@MainActor private final class BatchFakeRecorder: StageRecordRecording {
    let log: BatchLog
    let scenarioName: String
    let shouldFail: Bool
    init(log: BatchLog, scenarioName: String, shouldFail: Bool) {
        self.log = log
        self.scenarioName = scenarioName
        self.shouldFail = shouldFail
    }
    func start() async throws { log.append("start:\(scenarioName)") }
    func stop() async throws { log.append("stop:\(scenarioName)") }
    func waitForFailure() async throws -> Never {
        if shouldFail { throw BatchFixtureError.recording }
        do { try await Task.sleep(for: .seconds(3_600)) }
        catch { throw error }
        throw CancellationError()
    }
    func discardOutputIfOwned() async { log.append("discard:\(scenarioName)") }
}

private enum BatchFixtureError: Error, LocalizedError {
    case recording
    var errorDescription: String? { "The recording fixture failed." }
}
