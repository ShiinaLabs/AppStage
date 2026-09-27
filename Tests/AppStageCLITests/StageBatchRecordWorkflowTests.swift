import AppStage
import AppStageCapture
import AppStageControl
import Foundation
import XCTest
@testable import AppStageCLI

@MainActor
final class StageBatchRecordWorkflowTests: XCTestCase {
    func testBatchDiscoversOnceAndRecordsEachScenarioInMetadataOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = [
            StageScenarioMetadata(id: StageScenarioID("second"), displayName: "Second", durationMilliseconds: 12),
            StageScenarioMetadata(id: StageScenarioID("first"), displayName: nil),
        ]
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios)
        try await workflow.run()

        XCTAssertEqual(log.values.filter { $0 == "discover" }.count, 1)
        XCTAssertEqual(log.values.filter { $0.hasPrefix("record:") }, ["record:second", "record:first"])

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
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios, failScenario: "b")
        do {
            try await workflow.run()
            XCTFail("Expected the second scenario to fail")
        } catch BatchFixtureError.recording {}

        XCTAssertEqual(log.values.filter { $0.hasPrefix("record:") }, ["record:a", "record:b"])
        let manifest = try JSONDecoder().decode(
            StageCaptureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .failed)
        XCTAssertEqual(manifest.scenarios.map(\.status), [.completed, .failed, .pending])
        XCTAssertEqual(manifest.scenarios[1].error, "The recording fixture failed.")
        XCTAssertEqual(manifest.scenarios.map(\.output), ["a.mov", "b.mov", "c.mov"])
    }

    func testBatchCancellationKeepsEarlierCompletionAndLeavesLaterScenarioPending() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = [
            StageScenarioMetadata(id: StageScenarioID("completed")),
            StageScenarioMetadata(id: StageScenarioID("active")),
            StageScenarioMetadata(id: StageScenarioID("pending")),
        ]
        var batchTask: Task<Void, any Error>?
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios) { scenarioID in
            guard scenarioID.rawValue == "active" else { return }
            batchTask?.cancel()
            throw CancellationError()
        }
        batchTask = Task { try await workflow.run() }
        do {
            try await batchTask?.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        XCTAssertEqual(log.values.filter { $0.hasPrefix("record:") }, ["record:completed", "record:active"])
        let manifest = try JSONDecoder().decode(
            StageCaptureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.status, .cancelled)
        XCTAssertEqual(manifest.scenarios.map(\.status), [.completed, .cancelled, .pending])
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
        XCTAssertFalse(log.values.contains { $0.hasPrefix("record:") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    }

    func testDiscoveryPreflightFailureStartsNoScenario() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BatchLog()
        let scenarios = [
            StageScenarioMetadata(id: StageScenarioID("foo/bar")),
            StageScenarioMetadata(id: StageScenarioID("foo:bar")),
        ]
        let workflow = makeBatchWorkflow(directory: directory, log: log, scenarios: scenarios)

        do {
            try await workflow.run()
            XCTFail("Expected preflight failure")
        } catch StageBatchRecordError.filenameCollision {}

        XCTAssertEqual(log.values.filter { $0 == "discover" }.count, 1)
        XCTAssertFalse(log.values.contains { $0.hasPrefix("record:") })
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
        onRecord: (@MainActor (StageScenarioID) async throws -> Void)? = nil
    ) -> StageBatchRecordWorkflow {
        let capture = try! StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: 220, verticalMargin: 120),
            includesApplicationWindows: true
        )
        return StageBatchRecordWorkflow(
            discoverScenarios: {
                log.append("discover")
                return scenarios
            },
            recordScenario: { scenarioID, _ in
                log.append("record:\(scenarioID.rawValue)")
                try await onRecord?(scenarioID)
                if scenarioID.rawValue == failScenario { throw BatchFixtureError.recording }
            },
            outputDirectory: directory,
            bundleIdentifier: "com.example.fixture",
            captureConfiguration: capture,
            horizontalMargin: 220,
            verticalMargin: 120
        )
    }
}

@MainActor private final class BatchLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private enum BatchFixtureError: Error, LocalizedError {
    case recording
    var errorDescription: String? { "The recording fixture failed." }
}
