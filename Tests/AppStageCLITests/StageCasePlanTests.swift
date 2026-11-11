import AppStage
import XCTest
@testable import AppStageCLI

final class StageCasePlanTests: XCTestCase {
    func testSelectsCasesInSuiteOrderAndAppliesIncludeThenExcludePatterns() throws {
        let plan = try loadPlan("""
        {
          "schemaVersion": 1,
          "defaultSuite": "smoke",
          "cases": [
            { "id": "overview-summary", "scenarioID": "overview", "capturePointID": "summary" },
            { "id": "settings-summary", "scenarioID": "settings", "capturePointID": "summary" },
            { "id": "overview-details", "scenarioID": "overview", "capturePointID": "details" }
          ],
          "suites": { "smoke": ["overview-details", "overview-summary", "settings-summary"] }
        }
        """)
        let scenarios = [
            StageScenarioMetadata(id: StageScenarioID("overview"), capturePointIDs: [StageCapturePointID("summary"), StageCapturePointID("details")]),
            StageScenarioMetadata(id: StageScenarioID("settings"), capturePointIDs: [StageCapturePointID("summary")]),
        ]

        let selected = try plan.select(
            from: scenarios,
            kind: .capturePoint,
            suite: nil,
            includes: ["*-summary", "overview-*"],
            excludes: ["settings-*"]
        )

        XCTAssertEqual(selected.map(\.id), ["overview-details", "overview-summary"])
        XCTAssertEqual(selected.map { $0.capturePointID?.rawValue }, ["details", "summary"])
    }

    func testStructuredTargetsAndGeneratedCaseIDsRemainUniqueWithSlashes() throws {
        let plan = try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [
            { "id": "scenario-target", "scenarioID": "foo/bar" },
            { "id": "point-target", "scenarioID": "foo", "capturePointID": "bar" }
          ],
          "suites": { "scenario": ["scenario-target"] }
        }
        """)
        let selected = try plan.select(
            from: [
                StageScenarioMetadata(id: StageScenarioID("foo/bar")),
                StageScenarioMetadata(id: StageScenarioID("foo"), capturePointIDs: [StageCapturePointID("bar")]),
            ],
            kind: .scenario,
            suite: "scenario",
            includes: [],
            excludes: []
        )
        XCTAssertEqual(selected.map(\.scenario.id.rawValue), ["foo/bar"])

        let generated = try StageCasePlan.select(
            from: [
                StageScenarioMetadata(id: StageScenarioID("foo/bar"), capturePointIDs: [StageCapturePointID("baz")]),
                StageScenarioMetadata(id: StageScenarioID("foo"), capturePointIDs: [StageCapturePointID("bar/baz")]),
            ],
            using: nil,
            kind: .capturePoint,
            suite: nil,
            includes: [],
            excludes: []
        )
        XCTAssertEqual(generated.map(\.id), ["7:foo/bar3:baz", "3:foo7:bar/baz"])
        XCTAssertEqual(Set(generated.map(\.id)).count, generated.count)
    }

    func testUnconfiguredSelectionUsesAllDiscoveredScenariosAndCapturePoints() throws {
        let scenarios = [
            StageScenarioMetadata(id: StageScenarioID("overview"), capturePointIDs: [StageCapturePointID("summary")]),
            StageScenarioMetadata(id: StageScenarioID("settings")),
        ]

        let recordings = try StageCasePlan.select(
            from: scenarios,
            using: nil,
            kind: .scenario,
            suite: nil,
            includes: [],
            excludes: []
        )
        let snapshots = try StageCasePlan.select(
            from: scenarios,
            using: nil,
            kind: .capturePoint,
            suite: nil,
            includes: [],
            excludes: []
        )

        XCTAssertEqual(recordings.map(\.id), ["overview", "settings"])
        XCTAssertEqual(snapshots.map(\.id), ["8:overview7:summary"])
        XCTAssertThrowsError(try StageCasePlan.select(
            from: scenarios,
            using: nil,
            kind: .scenario,
            suite: "smoke",
            includes: [],
            excludes: []
        )) { XCTAssertEqual($0 as? StageCasePlanError, .suiteRequiresConfiguration) }
    }

    func testLoadsRuntimeDefaultsAndResolvesPathsRelativeToPlan() throws {
        let plan = try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [{ "id": "overview", "scenarioID": "overview" }],
          "defaults": {
            "captureAll": {
              "outputDirectory": "./Artifacts/movies",
              "timeoutSeconds": 45,
              "frameRate": 30,
              "transparentBackground": true
            }
          }
        }
        """)

        XCTAssertEqual(plan.defaults?.captureAll?.timeoutSeconds, 45)
        XCTAssertEqual(plan.defaults?.captureAll?.frameRate, 30)
        XCTAssertEqual(
            plan.resolvedPath(plan.defaults!.captureAll!.outputDirectory!, relativeTo: URL(fileURLWithPath: "/repo/appstage-plan.json")),
            "/repo/Artifacts/movies"
        )
    }

    func testRejectsUnsupportedSchemaAndDuplicateCasesOrTargets() {
        XCTAssertThrowsError(try loadPlan("""
        { "schemaVersion": 2, "cases": [] }
        """)) { XCTAssertEqual($0 as? StageCasePlanError, .unsupportedSchemaVersion(2)) }

        XCTAssertThrowsError(try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [
            { "id": "same", "scenarioID": "overview" },
            { "id": "same", "scenarioID": "settings" }
          ]
        }
        """)) { XCTAssertEqual($0 as? StageCasePlanError, .duplicateCaseID("same")) }

        XCTAssertThrowsError(try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [
            { "id": "first", "scenarioID": "overview", "capturePointID": "summary" },
            { "id": "second", "scenarioID": "overview", "capturePointID": "summary" }
          ]
        }
        """)) { XCTAssertEqual($0 as? StageCasePlanError, .duplicateTarget("overview/summary")) }
    }

    func testRejectsUnknownSuiteAndDuplicateSuiteReferences() {
        XCTAssertThrowsError(try loadPlan("""
        {
          "schemaVersion": 1,
          "defaultSuite": "missing",
          "cases": []
        }
        """)) { XCTAssertEqual($0 as? StageCasePlanError, .unknownSuite("missing")) }

        XCTAssertThrowsError(try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [{ "id": "overview", "scenarioID": "overview" }],
          "suites": { "smoke": ["overview", "overview"] }
        }
        """)) { XCTAssertEqual($0 as? StageCasePlanError, .duplicateSuiteCase("smoke", "overview")) }
    }

    func testRejectsUnknownHostTargetsWrongCaseKindAndEmptyResults() throws {
        let unknownPlan = try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [{ "id": "unknown", "scenarioID": "missing" }],
          "suites": { "unknown": ["unknown"] }
        }
        """)
        let pointPlan = try loadPlan("""
        {
          "schemaVersion": 1,
          "cases": [{ "id": "overview-summary", "scenarioID": "overview", "capturePointID": "summary" }],
          "suites": { "summary": ["overview-summary"] }
        }
        """)
        let scenarios = [StageScenarioMetadata(id: StageScenarioID("overview"), capturePointIDs: [StageCapturePointID("summary")])]

        XCTAssertThrowsError(try unknownPlan.select(from: scenarios, kind: .scenario, suite: "unknown", includes: [], excludes: [])) {
            XCTAssertEqual($0 as? StageCasePlanError, .unknownScenario("unknown", "missing"))
        }
        XCTAssertThrowsError(try pointPlan.select(from: scenarios, kind: .scenario, suite: "summary", includes: [], excludes: [])) {
            XCTAssertEqual($0 as? StageCasePlanError, .incompatibleCase("overview-summary", expected: "scenario"))
        }
        XCTAssertThrowsError(try pointPlan.select(from: scenarios, kind: .capturePoint, suite: "summary", includes: ["no-match*"], excludes: [])) {
            XCTAssertEqual($0 as? StageCasePlanError, .noMatchingCases)
        }
    }

    private func loadPlan(_ json: String) throws -> StageCasePlan {
        try JSONDecoder().decode(StageCasePlan.self, from: Data(json.utf8))
    }
}
