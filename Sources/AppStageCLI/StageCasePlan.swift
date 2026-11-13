import AppStage
import ArgumentParser
import Foundation

struct StageCasePlan: Decodable, Sendable {
    struct Case: Decodable, Sendable {
        let id: String
        let scenarioID: String
        let capturePointID: String?
    }

    struct Defaults: Decodable, Sendable {
        struct CaptureAll: Decodable, Sendable {
            let outputDirectory: String?
            let timeoutSeconds: Int?
            let horizontalMargin: Double?
            let verticalMargin: Double?
            let frameRate: Int?
            let backgroundImage: String?
            let transparentBackground: Bool?
        }

        struct CaptureAllSnapshots: Decodable, Sendable {
            let outputDirectory: String?
            let timeoutSeconds: Int?
            let horizontalMargin: Double?
            let verticalMargin: Double?
            let includeWindowShadow: Bool?
            let nativeSize: Bool?
            let includeDemoCursor: Bool?
        }

        struct Verify: Decodable, Sendable {
            let outputDirectory: String?
            let timeoutSeconds: Int?
            let iterations: Int?
            let retainMovies: String?
            let transparentBackground: Bool?
        }

        let captureAll: CaptureAll?
        let captureAllSnapshots: CaptureAllSnapshots?
        let verify: Verify?
    }

    enum Kind: Sendable {
        case scenario
        case capturePoint
    }

    private enum Target: Hashable {
        case scenario(String)
        case capturePoint(scenarioID: String, capturePointID: String)
    }

    struct SelectedCase: Equatable, Sendable {
        let id: String
        let scenario: StageScenarioMetadata
        let capturePointID: StageCapturePointID?
    }

    let schemaVersion: Int
    let defaultSuite: String?
    let cases: [Case]
    let suites: [String: [String]]
    let defaults: Defaults?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, defaultSuite, cases, suites, defaults
    }

    init(
        cases: [Case] = [],
        defaultSuite: String? = nil,
        suites: [String: [String]] = [:],
        defaults: Defaults? = nil
    ) {
        schemaVersion = 1
        self.defaultSuite = defaultSuite
        self.cases = cases
        self.suites = suites
        self.defaults = defaults
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        defaultSuite = try container.decodeIfPresent(String.self, forKey: .defaultSuite)
        cases = try container.decode([Case].self, forKey: .cases)
        suites = try container.decodeIfPresent([String: [String]].self, forKey: .suites) ?? [:]
        defaults = try container.decodeIfPresent(Defaults.self, forKey: .defaults)
        try validate()
    }

    static func load(from url: URL) throws -> StageCasePlan {
        try JSONDecoder().decode(StageCasePlan.self, from: Data(contentsOf: url))
    }

    func resolvedPath(_ path: String, relativeTo configURL: URL) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, relativeTo: configURL.deletingLastPathComponent())
            .standardizedFileURL.path
    }

    static func select(
        from scenarios: [StageScenarioMetadata],
        using plan: StageCasePlan?,
        kind: Kind,
        suite: String?,
        includes: [String],
        excludes: [String]
    ) throws -> [SelectedCase] {
        if plan == nil && suite != nil { throw StageCasePlanError.suiteRequiresConfiguration }
        return try (plan ?? StageCasePlan()).select(
            from: scenarios,
            kind: kind,
            suite: suite,
            includes: includes,
            excludes: excludes
        )
    }

    func select(
        from scenarios: [StageScenarioMetadata],
        kind: Kind,
        suite requestedSuite: String?,
        includes: [String],
        excludes: [String]
    ) throws -> [SelectedCase] {
        var scenariosByID: [String: StageScenarioMetadata] = [:]
        for scenario in scenarios {
            guard scenariosByID.updateValue(scenario, forKey: scenario.id.rawValue) == nil else {
                throw StageCasePlanError.duplicateScenarioID(scenario.id.rawValue)
            }
        }
        try validateTargets(scenariosByID)
        guard includes.allSatisfy({ !$0.isEmpty }), excludes.allSatisfy({ !$0.isEmpty }) else {
            throw StageCasePlanError.emptyFilter
        }

        let orderedCases: [Case]
        if cases.isEmpty && requestedSuite == nil && defaultSuite == nil {
            orderedCases = scenarios.flatMap { scenario in
                switch kind {
                case .scenario:
                    [Case(id: scenario.id.rawValue, scenarioID: scenario.id.rawValue, capturePointID: nil)]
                case .capturePoint:
                    scenario.capturePointIDs.map { point in
                        Case(
                            id: "\(scenario.id.rawValue.utf8.count):\(scenario.id.rawValue)\(point.rawValue.utf8.count):\(point.rawValue)",
                            scenarioID: scenario.id.rawValue,
                            capturePointID: point.rawValue
                        )
                    }
                }
            }
        } else {
            let selectedSuite = requestedSuite ?? defaultSuite
            if let selectedSuite {
                guard let ids = suites[selectedSuite] else { throw StageCasePlanError.unknownSuite(selectedSuite) }
                let casesByID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
                orderedCases = try ids.map { id in
                    guard let testCase = casesByID[id] else { throw StageCasePlanError.unknownCase(id) }
                    return testCase
                }
            } else {
                orderedCases = cases
            }
        }

        let filtered = orderedCases.filter { testCase in
            (includes.isEmpty || includes.contains { Self.matches($0, testCase.id) })
                && !excludes.contains { Self.matches($0, testCase.id) }
        }
        guard !filtered.isEmpty else { throw StageCasePlanError.noMatchingCases }

        let expectedCapturePoint: Bool
        switch kind {
        case .scenario: expectedCapturePoint = false
        case .capturePoint: expectedCapturePoint = true
        }
        for testCase in filtered where (testCase.capturePointID != nil) != expectedCapturePoint {
            throw StageCasePlanError.incompatibleCase(testCase.id, expected: expectedCapturePoint ? "capture point" : "scenario")
        }

        return try filtered.map { testCase in
            guard let scenario = scenariosByID[testCase.scenarioID] else {
                throw StageCasePlanError.unknownScenario(testCase.id, testCase.scenarioID)
            }
            if let capturePointID = testCase.capturePointID {
                guard scenario.capturePointIDs.contains(where: { $0.rawValue == capturePointID }) else {
                    throw StageCasePlanError.unknownCapturePoint(testCase.id, capturePointID)
                }
                return SelectedCase(
                    id: testCase.id,
                    scenario: scenario,
                    capturePointID: StageCapturePointID(capturePointID)
                )
            }
            return SelectedCase(id: testCase.id, scenario: scenario, capturePointID: nil)
        }
    }

    private func validate() throws {
        guard schemaVersion == 1 else { throw StageCasePlanError.unsupportedSchemaVersion(schemaVersion) }
        var caseIDs = Set<String>()
        var targets = Set<Target>()
        for testCase in cases {
            guard !testCase.id.isEmpty else { throw StageCasePlanError.emptyIdentifier("case") }
            guard !testCase.scenarioID.isEmpty else { throw StageCasePlanError.emptyIdentifier("scenario") }
            if let capturePointID = testCase.capturePointID, capturePointID.isEmpty {
                throw StageCasePlanError.emptyIdentifier("capture point")
            }
            guard caseIDs.insert(testCase.id).inserted else { throw StageCasePlanError.duplicateCaseID(testCase.id) }
            let target: Target
            let targetDescription: String
            if let capturePointID = testCase.capturePointID {
                target = .capturePoint(scenarioID: testCase.scenarioID, capturePointID: capturePointID)
                targetDescription = "\(testCase.scenarioID)/\(capturePointID)"
            } else {
                target = .scenario(testCase.scenarioID)
                targetDescription = testCase.scenarioID
            }
            guard targets.insert(target).inserted else {
                throw StageCasePlanError.duplicateTarget(targetDescription)
            }
        }

        for (suite, ids) in suites {
            guard !suite.isEmpty else { throw StageCasePlanError.emptyIdentifier("suite") }
            var suiteCaseIDs = Set<String>()
            for id in ids {
                guard suiteCaseIDs.insert(id).inserted else { throw StageCasePlanError.duplicateSuiteCase(suite, id) }
                guard caseIDs.contains(id) else { throw StageCasePlanError.unknownCase(id) }
            }
        }
        if let defaultSuite, suites[defaultSuite] == nil {
            throw StageCasePlanError.unknownSuite(defaultSuite)
        }
        try defaults?.validate()
    }

    private func validateTargets(_ scenariosByID: [String: StageScenarioMetadata]) throws {
        for testCase in cases {
            guard let scenario = scenariosByID[testCase.scenarioID] else {
                throw StageCasePlanError.unknownScenario(testCase.id, testCase.scenarioID)
            }
            if let capturePointID = testCase.capturePointID,
               !scenario.capturePointIDs.contains(where: { $0.rawValue == capturePointID }) {
                throw StageCasePlanError.unknownCapturePoint(testCase.id, capturePointID)
            }
        }
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        let patternCharacters = Array(pattern)
        let valueCharacters = Array(value)
        var previous = Array(repeating: false, count: valueCharacters.count + 1)
        previous[0] = true

        for character in patternCharacters {
            var current = Array(repeating: false, count: valueCharacters.count + 1)
            if character == "*" {
                current[0] = previous[0]
                for (offset, _) in valueCharacters.enumerated() {
                    let column = offset + 1
                    current[column] = previous[column] || current[column - 1]
                }
            } else {
                for (offset, valueCharacter) in valueCharacters.enumerated() {
                    current[offset + 1] = previous[offset]
                        && (character == "?" || character == valueCharacter)
                }
            }
            previous = current
        }
        return previous[valueCharacters.count]
    }
}

extension StageCasePlan.Defaults {
    func validate() throws {
        if let captureAll {
            try validate(timeoutSeconds: captureAll.timeoutSeconds, horizontalMargin: captureAll.horizontalMargin, verticalMargin: captureAll.verticalMargin)
            if let frameRate = captureAll.frameRate, !(1...240).contains(frameRate) {
                throw StageCasePlanError.invalidDefault("captureAll.frameRate must be between 1 and 240")
            }
            try validateOutputDirectory(captureAll.outputDirectory, key: "captureAll.outputDirectory")
        }
        if let captureAllSnapshots {
            try validate(timeoutSeconds: captureAllSnapshots.timeoutSeconds, horizontalMargin: captureAllSnapshots.horizontalMargin, verticalMargin: captureAllSnapshots.verticalMargin)
            try validateOutputDirectory(captureAllSnapshots.outputDirectory, key: "captureAllSnapshots.outputDirectory")
        }
        if let verify {
            if let timeout = verify.timeoutSeconds, !(1...600).contains(timeout) {
                throw StageCasePlanError.invalidDefault("verify.timeoutSeconds must be between 1 and 600")
            }
            if let iterations = verify.iterations, !(1...1_000).contains(iterations) {
                throw StageCasePlanError.invalidDefault("verify.iterations must be between 1 and 1000")
            }
            if let retainMovies = verify.retainMovies, !["failures", "all", "none"].contains(retainMovies) {
                throw StageCasePlanError.invalidDefault("verify.retainMovies must be failures, all, or none")
            }
            try validateOutputDirectory(verify.outputDirectory, key: "verify.outputDirectory")
        }
    }

    private func validate(timeoutSeconds: Int?, horizontalMargin: Double?, verticalMargin: Double?) throws {
        if let timeoutSeconds, !(1...600).contains(timeoutSeconds) {
            throw StageCasePlanError.invalidDefault("timeoutSeconds must be between 1 and 600")
        }
        for (name, margin) in [("horizontalMargin", horizontalMargin), ("verticalMargin", verticalMargin)] {
            if let margin, !margin.isFinite || margin < 0 {
                throw StageCasePlanError.invalidDefault("\(name) must be finite and non-negative")
            }
        }
    }

    private func validateOutputDirectory(_ path: String?, key: String) throws {
        if let path, path.isEmpty { throw StageCasePlanError.invalidDefault("\(key) must not be empty") }
    }
}

enum StageCasePlanError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case emptyIdentifier(String)
    case duplicateCaseID(String)
    case duplicateScenarioID(String)
    case duplicateTarget(String)
    case duplicateSuiteCase(String, String)
    case unknownSuite(String)
    case unknownCase(String)
    case unknownScenario(String, String)
    case unknownCapturePoint(String, String)
    case incompatibleCase(String, expected: String)
    case suiteRequiresConfiguration
    case emptyFilter
    case noMatchingCases
    case invalidDefault(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version): "Unsupported AppStage case plan schema version: \(version)"
        case let .emptyIdentifier(kind): "AppStage case plan \(kind) ID must not be empty."
        case let .duplicateCaseID(id): "Duplicate case ID in AppStage case plan: \(id)"
        case let .duplicateScenarioID(id): "Host discovery returned duplicate Scenario ID: \(id)"
        case let .duplicateTarget(target): "Multiple AppStage cases reference the same Host target: \(target)"
        case let .duplicateSuiteCase(suite, id): "Suite \(suite) lists case \(id) more than once."
        case let .unknownSuite(suite): "Unknown AppStage suite: \(suite)"
        case let .unknownCase(id): "Unknown AppStage case ID: \(id)"
        case let .unknownScenario(caseID, scenarioID): "Case \(caseID) references unknown Host Scenario \(scenarioID)."
        case let .unknownCapturePoint(caseID, pointID): "Case \(caseID) references unknown capture point \(pointID)."
        case let .incompatibleCase(id, expected): "Case \(id) is not a \(expected) case for this command."
        case .suiteRequiresConfiguration: "--suite requires --config."
        case .emptyFilter: "Case filter patterns must not be empty."
        case .noMatchingCases: "No cases matched the selected suite and filters."
        case let .invalidDefault(message): "Invalid AppStage case plan default: \(message)"
        }
    }
}

struct StageCaseSelectionArguments: ParsableArguments {
    @Option(name: .long, help: "Path to an AppStage JSON case plan.")
    var config: String?

    @Option(name: .long, help: "Named suite to run from the case plan.")
    var suite: String?

    @Option(name: .long, help: "Include case IDs matching this glob. May be repeated.")
    var filter: [String] = []

    @Option(name: .long, help: "Exclude case IDs matching this glob. May be repeated.")
    var exclude: [String] = []

    func loadPlan() throws -> (plan: StageCasePlan?, url: URL?) {
        guard let config else {
            if suite != nil { throw StageCasePlanError.suiteRequiresConfiguration }
            return (nil, nil)
        }
        let url = URL(fileURLWithPath: (config as NSString).expandingTildeInPath).standardizedFileURL
        do {
            return (try StageCasePlan.load(from: url), url)
        } catch {
            throw ValidationError("Could not load AppStage case plan at \(url.path): \(error.localizedDescription)")
        }
    }

    func select(
        scenarios: [StageScenarioMetadata],
        kind: StageCasePlan.Kind,
        plan: StageCasePlan?
    ) throws -> [StageCasePlan.SelectedCase] {
        try StageCasePlan.select(
            from: scenarios,
            using: plan,
            kind: kind,
            suite: suite,
            includes: filter,
            excludes: exclude
        )
    }
}
