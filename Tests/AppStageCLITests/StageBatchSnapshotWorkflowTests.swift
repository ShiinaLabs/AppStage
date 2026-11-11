import AppStage
import AppStageControl
import XCTest
@testable import AppStageCLI

@MainActor
final class StageBatchSnapshotWorkflowTests: XCTestCase {
    func testCancellationMarksCurrentPointAndLeavesLaterPointsPending() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let workflow = StageBatchSnapshotWorkflow(
            discoverScenarios: {
                [StageScenarioMetadata(
                    id: StageScenarioID("overview"),
                    capturePointIDs: [StageCapturePointID("summary"), StageCapturePointID("details")]
                )]
            },
            capturePoint: { _, _, _ in try await Task.sleep(for: .seconds(60)) },
            outputDirectory: outputDirectory,
            bundleIdentifier: "example.app",
            horizontalMargin: 12,
            verticalMargin: 8,
            includesWindowShadow: false,
            includesDemoCursor: false
        )
        let task = Task { try await workflow.run() }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let manifestData = try Data(contentsOf: outputDirectory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["status"] as? String, "cancelled")
        let items = try XCTUnwrap(manifest["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["cancelled", "pending"])
    }

    func testBatchContinuesAfterCaptureFailureAndWritesManifest() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        var attempted: [String] = []
        let workflow = StageBatchSnapshotWorkflow(
            discoverScenarios: {
                [StageScenarioMetadata(
                    id: StageScenarioID("overview"),
                    capturePointIDs: [StageCapturePointID("summary"), StageCapturePointID("details")]
                )]
            },
            capturePoint: { _, pointID, outputURL in
                attempted.append(pointID.rawValue)
                if pointID.rawValue == "summary" { throw StageControlError.remoteFailure("capture failed") }
                try Data("png".utf8).write(to: outputURL)
            },
            outputDirectory: outputDirectory,
            bundleIdentifier: "example.app",
            horizontalMargin: 12,
            verticalMargin: 8,
            includesWindowShadow: true,
            includesDemoCursor: false
        )

        do {
            try await workflow.run()
            XCTFail("Expected the batch to report one failed point")
        } catch {
            XCTAssertEqual(error as? StageBatchSnapshotError, .itemsFailed(1))
        }

        XCTAssertEqual(attempted, ["summary", "details"])
        let manifestData = try Data(contentsOf: outputDirectory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["status"] as? String, "failed")
        let items = try XCTUnwrap(manifest["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["failed", "completed"])
        XCTAssertEqual(items.map { $0["output"] as? String }, ["overview--summary.png", "overview--details.png"])
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        XCTAssertEqual(items.map { $0["caseID"] as? String }, ["overview/summary", "overview/details"])
    }

    func testCasePlanSelectionIsRecordedAndValidatedBeforeOutputDirectoryCreation() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let scenarios = [StageScenarioMetadata(
            id: StageScenarioID("overview"),
            capturePointIDs: [StageCapturePointID("summary"), StageCapturePointID("details")]
        )]
        let plan = StageCasePlan(
            cases: [StageCasePlan.Case(id: "overview-summary", scenarioID: "overview", capturePointID: "summary")],
            suites: ["smoke": ["overview-summary"]]
        )
        var captured: [String] = []
        let workflow = StageBatchSnapshotWorkflow(
            discoverScenarios: { scenarios },
            capturePoint: { _, pointID, outputURL in
                captured.append(pointID.rawValue)
                try Data("png".utf8).write(to: outputURL)
            },
            outputDirectory: outputDirectory,
            bundleIdentifier: "example.app",
            horizontalMargin: 12,
            verticalMargin: 8,
            includesWindowShadow: false,
            includesDemoCursor: false,
            casePlan: plan,
            casePlanPath: "/tmp/suite.json",
            suite: "smoke"
        )
        try await workflow.run()
        XCTAssertEqual(captured, ["summary"])
        let manifestData = try Data(contentsOf: outputDirectory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["casePlanPath"] as? String, "/tmp/suite.json")
        XCTAssertEqual(manifest["suite"] as? String, "smoke")
        let items = try XCTUnwrap(manifest["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["caseID"] as? String }, ["overview-summary"])
    }

    func testInvalidCasePlanDoesNotCreateOutputDirectory() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let workflow = StageBatchSnapshotWorkflow(
            discoverScenarios: { [StageScenarioMetadata(id: StageScenarioID("overview"))] },
            capturePoint: { _, _, _ in XCTFail("Capture must not start") },
            outputDirectory: outputDirectory,
            bundleIdentifier: "example.app",
            horizontalMargin: 12,
            verticalMargin: 8,
            includesWindowShadow: false,
            includesDemoCursor: false,
            filters: ["no-match*"]
        )
        do {
            try await workflow.run()
            XCTFail("Expected empty selection to fail")
        } catch {
            XCTAssertEqual(error as? StageCasePlanError, .noMatchingCases)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }
}
