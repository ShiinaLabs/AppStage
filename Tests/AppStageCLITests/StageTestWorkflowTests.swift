import AppStage
import XCTest
@testable import AppStageCLI

@MainActor
final class StageTestWorkflowTests: XCTestCase {
    func testExactFilterSelectsOnlyMatchingCaseID() async throws {
        let cases = ["network-roaming", "network-roaming-slow", "network-baseline"].map {
            StageCaseMetadata(id: StageCaseID($0), scenarioID: StageScenarioID($0))
        }
        var attempted: [String] = []
        let workflow = StageTestWorkflow(
            discoverCases: { _ in cases },
            runCase: { caseID, _ in attempted.append(caseID.rawValue) }
        )

        let report = try await workflow.run(
            timeout: 45,
            filters: ["network-roaming"],
            exclusions: [],
            listOnly: false
        )

        XCTAssertEqual(report.selectedCases.map(\.id), ["network-roaming"])
        XCTAssertEqual(attempted, ["network-roaming"])
        XCTAssertEqual(report.failureCount, 0)
    }

    func testGlobIncludesAndExcludesPreserveHostOrder() async throws {
        let cases = ["network-roaming", "network-slow-roaming", "network-baseline", "settings"].map {
            StageCaseMetadata(id: StageCaseID($0), scenarioID: StageScenarioID($0))
        }
        var attempted: [String] = []
        let workflow = StageTestWorkflow(
            discoverCases: { _ in cases },
            runCase: { caseID, _ in attempted.append(caseID.rawValue) }
        )

        let report = try await workflow.run(
            timeout: 45,
            filters: ["network-*", "settings?"],
            exclusions: ["*slow*"],
            listOnly: false
        )

        XCTAssertEqual(report.selectedCases.map(\.id), ["network-roaming", "network-baseline"])
        XCTAssertEqual(attempted, ["network-roaming", "network-baseline"])
    }

    func testListOnlyReturnsFilteredCasesWithoutExecutingThem() async throws {
        let cases = ["network-roaming", "network-baseline"].map {
            StageCaseMetadata(id: StageCaseID($0), scenarioID: StageScenarioID($0))
        }
        let workflow = StageTestWorkflow(
            discoverCases: { _ in cases },
            runCase: { _, _ in XCTFail("List-only mode must not execute a Case") }
        )

        let report = try await workflow.run(
            timeout: 45,
            filters: ["network-*"],
            exclusions: ["*-baseline"],
            listOnly: true
        )

        XCTAssertEqual(report.selectedCases.map(\.id), ["network-roaming"])
        XCTAssertTrue(report.results.isEmpty)
    }

    func testFailureDoesNotStopLaterCasesAndTimeoutReachesEveryOperation() async throws {
        let cases = ["first", "broken", "last"].map {
            StageCaseMetadata(id: StageCaseID($0), scenarioID: StageScenarioID($0))
        }
        var discoveredTimeout: Int?
        var attempted: [(String, Int)] = []
        var events: [StageTestWorkflow.Event] = []
        let workflow = StageTestWorkflow(
            discoverCases: { timeout in
                discoveredTimeout = timeout
                return cases
            },
            runCase: { caseID, timeout in
                attempted.append((caseID.rawValue, timeout))
                if caseID.rawValue == "broken" {
                    throw NSError(domain: "StageTestWorkflowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "case failed"])
                }
            }
        )

        let report = try await workflow.run(
            timeout: 73,
            filters: [],
            exclusions: [],
            listOnly: false,
            onEvent: { events.append($0) }
        )

        XCTAssertEqual(discoveredTimeout, 73)
        XCTAssertEqual(attempted.map(\.0), ["first", "broken", "last"])
        XCTAssertEqual(attempted.map(\.1), [73, 73, 73])
        XCTAssertEqual(report.results.map(\.id), ["first", "broken", "last"])
        XCTAssertEqual(report.results.map { $0.error == nil }, [true, false, true])
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(events, [
            .selected(3),
            .started("first"), .finished(.init(id: "first", error: nil)),
            .started("broken"), .finished(.init(id: "broken", error: "case failed")),
            .started("last"), .finished(.init(id: "last", error: nil)),
        ])
    }

    func testListOnlyReturnsAnEmptyReportWhenNothingMatches() async throws {
        let workflow = StageTestWorkflow(
            discoverCases: { _ in [StageCaseMetadata(id: StageCaseID("network"), scenarioID: StageScenarioID("network"))] },
            runCase: { _, _ in XCTFail("An unmatched Case must not execute") }
        )

        let report = try await workflow.run(
            timeout: 45,
            filters: ["missing"],
            exclusions: [],
            listOnly: true
        )

        XCTAssertTrue(report.selectedCases.isEmpty)
        XCTAssertTrue(report.results.isEmpty)
    }
}
