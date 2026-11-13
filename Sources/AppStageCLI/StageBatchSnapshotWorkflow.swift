import AppStage
import Foundation

@MainActor
final class StageBatchSnapshotWorkflow {
    typealias DiscoverScenarios = @MainActor () async throws -> [StageScenarioMetadata]
    typealias CapturePoint = @MainActor (StageScenarioID, StageCapturePointID, URL) async throws -> Void

    private struct Item: Codable {
        let caseID: String
        let scenarioID: String
        let capturePointID: String
        let output: String
        var status: String
        var error: String?
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let bundleIdentifier: String
        let horizontalMargin: Double
        let verticalMargin: Double
        let includesWindowShadow: Bool
        let nativeSize: Bool
        let includesDemoCursor: Bool
        let timeoutSeconds: Int
        let casePlanPath: String?
        let suite: String?
        let filters: [String]
        let exclusions: [String]
        var status: String
        var items: [Item]
    }

    private let discoverScenarios: DiscoverScenarios
    private let capturePoint: CapturePoint
    private let outputDirectory: URL
    private let bundleIdentifier: String
    private let horizontalMargin: Double
    private let verticalMargin: Double
    private let includesWindowShadow: Bool
    private let nativeSize: Bool
    private let includesDemoCursor: Bool
    private let timeoutSeconds: Int
    private let casePlan: StageCasePlan?
    private let casePlanPath: String?
    private let suite: String?
    private let filters: [String]
    private let exclusions: [String]

    init(
        discoverScenarios: @escaping DiscoverScenarios,
        capturePoint: @escaping CapturePoint,
        outputDirectory: URL,
        bundleIdentifier: String,
        horizontalMargin: Double,
        verticalMargin: Double,
        includesWindowShadow: Bool,
        nativeSize: Bool = false,
        includesDemoCursor: Bool,
        timeoutSeconds: Int = 30,
        casePlan: StageCasePlan? = nil,
        casePlanPath: String? = nil,
        suite: String? = nil,
        filters: [String] = [],
        exclusions: [String] = []
    ) {
        self.discoverScenarios = discoverScenarios
        self.capturePoint = capturePoint
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
        self.includesWindowShadow = includesWindowShadow
        self.nativeSize = nativeSize
        self.includesDemoCursor = includesDemoCursor
        self.timeoutSeconds = timeoutSeconds
        self.casePlan = casePlan
        self.casePlanPath = casePlanPath
        self.suite = suite
        self.filters = filters
        self.exclusions = exclusions
    }

    func run() async throws {
        let scenarios = try await discoverScenarios()
        guard scenarios.contains(where: { !$0.capturePointIDs.isEmpty }) else {
            throw StageBatchSnapshotError.noCapturePoints
        }
        let selectedCases = try StageCasePlan.select(
            from: scenarios,
            using: casePlan,
            kind: .capturePoint,
            suite: suite,
            includes: filters,
            excludes: exclusions
        )
        let entries = try selectedCases.map { selectedCase in
            let scenarioBase = try StageCaptureOutputNaming.fileName(for: selectedCase.scenario.id)
                .replacingOccurrences(of: ".mov", with: "")
            let pointID = selectedCase.capturePointID!
            let pointBase = try StageCaptureOutputNaming.fileName(for: StageScenarioID(pointID.rawValue))
                .replacingOccurrences(of: ".mov", with: "")
            return (selectedCase, "\(scenarioBase)--\(pointBase).png")
        }
        try prepareOutputDirectory()
        var collisionKeys = Set<String>()
        for (_, fileName) in entries {
            guard collisionKeys.insert(StageCaptureOutputNaming.collisionKey(for: fileName)).inserted else {
                throw StageBatchRecordError.filenameCollision(fileName)
            }
        }

        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        var manifest = Manifest(
            schemaVersion: 2,
            bundleIdentifier: bundleIdentifier,
            horizontalMargin: horizontalMargin,
            verticalMargin: verticalMargin,
            includesWindowShadow: includesWindowShadow,
            nativeSize: nativeSize,
            includesDemoCursor: includesDemoCursor,
            timeoutSeconds: timeoutSeconds,
            casePlanPath: casePlanPath,
            suite: suite ?? casePlan?.defaultSuite,
            filters: filters,
            exclusions: exclusions,
            status: "running",
            items: entries.map { selectedCase, fileName in
                Item(
                    caseID: selectedCase.id,
                    scenarioID: selectedCase.scenario.id.rawValue,
                    capturePointID: selectedCase.capturePointID!.rawValue,
                    output: fileName,
                    status: "pending",
                    error: nil
                )
            }
        )
        try write(manifest, to: manifestURL)

        var failures = 0
        for (index, entry) in entries.enumerated() {
            manifest.items[index].status = "capturing"
            try write(manifest, to: manifestURL)
            let outputURL = outputDirectory.appendingPathComponent(entry.1)
            do {
                try Task.checkCancellation()
                try await capturePoint(entry.0.scenario.id, entry.0.capturePointID!, outputURL)
                manifest.items[index].status = "completed"
                print("Completed: \(entry.1)")
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputURL)
                manifest.items[index].status = "cancelled"
                manifest.status = "cancelled"
                try write(manifest, to: manifestURL)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                failures += 1
                manifest.items[index].status = "failed"
                manifest.items[index].error = error.localizedDescription
                print("Failed: \(entry.0.scenario.id.rawValue) / \(entry.0.capturePointID!.rawValue): \(error.localizedDescription)")
            }
            try write(manifest, to: manifestURL)
        }
        manifest.status = failures == 0 ? "completed" : "failed"
        try write(manifest, to: manifestURL)
        print("Snapshot batch \(manifest.status). Manifest: \(manifestURL.path)")
        if failures > 0 { throw StageBatchSnapshotError.itemsFailed(failures) }
    }

    private func prepareOutputDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).isEmpty else {
                throw StageBatchRecordError.outputDirectoryMustBeEmpty
            }
        } else {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw StageBatchRecordError.outputDirectoryNotWritable
        }
    }

    private func write(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

enum StageBatchSnapshotError: Error, Equatable, LocalizedError {
    case noCapturePoints
    case itemsFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noCapturePoints: "No static capture points are advertised by the Host."
        case let .itemsFailed(count): "\(count) static capture point(s) failed. See manifest.json for details."
        }
    }
}
