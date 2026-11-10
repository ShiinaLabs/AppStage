import AppStage
import Foundation

@MainActor
final class StageBatchSnapshotWorkflow {
    typealias DiscoverScenarios = @MainActor () async throws -> [StageScenarioMetadata]
    typealias CapturePoint = @MainActor (StageScenarioID, StageCapturePointID, URL) async throws -> Void

    private struct Item: Codable {
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
        let includesDemoCursor: Bool
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
    private let includesDemoCursor: Bool

    init(
        discoverScenarios: @escaping DiscoverScenarios,
        capturePoint: @escaping CapturePoint,
        outputDirectory: URL,
        bundleIdentifier: String,
        horizontalMargin: Double,
        verticalMargin: Double,
        includesWindowShadow: Bool,
        includesDemoCursor: Bool
    ) {
        self.discoverScenarios = discoverScenarios
        self.capturePoint = capturePoint
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
        self.includesWindowShadow = includesWindowShadow
        self.includesDemoCursor = includesDemoCursor
    }

    func run() async throws {
        try prepareOutputDirectory()
        let scenarios = try await discoverScenarios()
        let entries = try scenarios.flatMap { scenario in
            try scenario.capturePointIDs.map { pointID in
                let scenarioBase = try StageCaptureOutputNaming.fileName(for: scenario.id)
                    .replacingOccurrences(of: ".mov", with: "")
                let pointBase = try StageCaptureOutputNaming.fileName(for: StageScenarioID(pointID.rawValue))
                    .replacingOccurrences(of: ".mov", with: "")
                return (scenario, pointID, "\(scenarioBase)--\(pointBase).png")
            }
        }
        guard !entries.isEmpty else { throw StageBatchSnapshotError.noCapturePoints }
        var collisionKeys = Set<String>()
        for (_, _, fileName) in entries {
            guard collisionKeys.insert(StageCaptureOutputNaming.collisionKey(for: fileName)).inserted else {
                throw StageBatchRecordError.filenameCollision(fileName)
            }
        }

        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        var manifest = Manifest(
            schemaVersion: 1,
            bundleIdentifier: bundleIdentifier,
            horizontalMargin: horizontalMargin,
            verticalMargin: verticalMargin,
            includesWindowShadow: includesWindowShadow,
            includesDemoCursor: includesDemoCursor,
            status: "running",
            items: entries.map { scenario, pointID, fileName in
                Item(scenarioID: scenario.id.rawValue, capturePointID: pointID.rawValue, output: fileName, status: "pending", error: nil)
            }
        )
        try write(manifest, to: manifestURL)

        var failures = 0
        for (index, entry) in entries.enumerated() {
            manifest.items[index].status = "capturing"
            try write(manifest, to: manifestURL)
            let outputURL = outputDirectory.appendingPathComponent(entry.2)
            do {
                try Task.checkCancellation()
                try await capturePoint(entry.0.id, entry.1, outputURL)
                manifest.items[index].status = "completed"
                print("Completed: \(entry.2)")
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
                print("Failed: \(entry.0.id.rawValue) / \(entry.1.rawValue): \(error.localizedDescription)")
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
