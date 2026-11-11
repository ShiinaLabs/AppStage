import AppStage
import AppStageCapture
import AppStageControl
import Foundation

@MainActor
final class StageBatchRecordWorkflow {
    typealias DiscoverScenarios = @MainActor () async throws -> [StageScenarioMetadata]
    typealias RecordScenario = @MainActor (StageScenarioID, URL) async throws -> Void

    private let discoverScenarios: DiscoverScenarios
    private let recordScenario: RecordScenario
    private let outputDirectory: URL
    private let manifestURL: URL
    private let bundleIdentifier: String
    private let captureConfiguration: StageCaptureConfiguration
    private let timeoutSeconds: Int
    private let horizontalMargin: Double
    private let verticalMargin: Double
    private let casePlan: StageCasePlan?
    private let casePlanPath: String?
    private let suite: String?
    private let filters: [String]
    private let exclusions: [String]

    init(
        discoverScenarios: @escaping DiscoverScenarios,
        recordScenario: @escaping RecordScenario,
        outputDirectory: URL,
        bundleIdentifier: String,
        captureConfiguration: StageCaptureConfiguration,
        timeoutSeconds: Int = 30,
        horizontalMargin: Double,
        verticalMargin: Double,
        casePlan: StageCasePlan? = nil,
        casePlanPath: String? = nil,
        suite: String? = nil,
        filters: [String] = [],
        exclusions: [String] = []
    ) {
        self.discoverScenarios = discoverScenarios
        self.recordScenario = recordScenario
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.manifestURL = outputDirectory.standardizedFileURL.appendingPathComponent("manifest.json")
        self.bundleIdentifier = bundleIdentifier
        self.captureConfiguration = captureConfiguration
        self.timeoutSeconds = timeoutSeconds
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
        self.casePlan = casePlan
        self.casePlanPath = casePlanPath
        self.suite = suite
        self.filters = filters
        self.exclusions = exclusions
    }

    func run() async throws {
        var manifest: StageCaptureManifest?
        var activeScenarioIndex: Int?
        do {
            let discoveredScenarios = try await discoverScenarios()
            let selectedCases = try StageCasePlan.select(
                from: discoveredScenarios,
                using: casePlan,
                kind: .scenario,
                suite: suite,
                includes: filters,
                excludes: exclusions
            )
            let preflight = try preflight(selectedCases)
            try prepareOutputDirectory()
            manifest = StageCaptureManifest(
                bundleIdentifier: bundleIdentifier,
                captureConfiguration: captureConfiguration,
                timeoutSeconds: timeoutSeconds,
                horizontalMargin: horizontalMargin,
                verticalMargin: verticalMargin,
                casePlanPath: casePlanPath,
                suite: suite ?? casePlan?.defaultSuite,
                filters: filters,
                exclusions: exclusions,
                scenarios: preflight.map { selectedCase, fileName in
                    StageCaptureManifest.Scenario(
                        caseID: selectedCase.id,
                        id: selectedCase.scenario.id.rawValue,
                        displayName: selectedCase.scenario.displayName,
                        declaredDurationMilliseconds: selectedCase.scenario.durationMilliseconds,
                        output: fileName,
                        status: .pending,
                        error: nil
                    )
                }
            )
            try manifest?.write(to: manifestURL)
            print("Found \(selectedCases.count) cases.")

            for (index, item) in preflight.enumerated() {
                activeScenarioIndex = index
                manifest?.scenarios[index].status = .recording
                try manifest?.write(to: manifestURL)
                print("[\(index + 1)/\(preflight.count)] \(item.selectedCase.scenario.id.rawValue)")
                print("Recording...")
                let movieURL = outputDirectory.appendingPathComponent(item.fileName)
                try await recordScenario(item.selectedCase.scenario.id, movieURL)
                manifest?.scenarios[index].status = .completed
                manifest?.scenarios[index].error = nil
                try manifest?.write(to: manifestURL)
                activeScenarioIndex = nil
                print("Completed: \(item.fileName)")
            }

            manifest?.finish(.completed)
            try manifest?.write(to: manifestURL)
            print("Batch completed.")
            print("Manifest: \(manifestURL.path)")
        } catch {
            if var current = manifest {
                if let activeScenarioIndex,
                   current.scenarios[activeScenarioIndex].status == .recording {
                    if error is CancellationError {
                        current.scenarios[activeScenarioIndex].status = .cancelled
                        current.scenarios[activeScenarioIndex].error = nil
                    } else {
                        current.scenarios[activeScenarioIndex].status = .failed
                        current.scenarios[activeScenarioIndex].error = error.localizedDescription
                    }
                }
                current.finish(error is CancellationError ? .cancelled : .failed)
                try? current.write(to: manifestURL)
            }
            if let activeScenarioIndex, let manifest {
                let item = manifest.scenarios[activeScenarioIndex]
                print("Failed: \(item.id)")
            }
            print("Batch stopped.")
            if manifest != nil { print("Manifest: \(manifestURL.path)") }
            throw error
        }
    }

    private func prepareOutputDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StageBatchRecordError.outputDirectoryMustBeEmpty }
            let contents = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
            guard contents.isEmpty else { throw StageBatchRecordError.outputDirectoryMustBeEmpty }
        } else {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw StageBatchRecordError.outputDirectoryNotWritable
        }
    }

    private func preflight(
        _ selectedCases: [StageCasePlan.SelectedCase]
    ) throws -> [(selectedCase: StageCasePlan.SelectedCase, fileName: String)] {
        var identifiers = Set<StageScenarioID>()
        var collisionKeys = Set<String>()
        var results: [(StageCasePlan.SelectedCase, String)] = []
        for selectedCase in selectedCases {
            let scenario = selectedCase.scenario
            guard identifiers.insert(scenario.id).inserted else {
                throw StageBatchRecordError.duplicateScenarioID(scenario.id.rawValue)
            }
            let fileName = try StageCaptureOutputNaming.fileName(for: scenario.id)
            let collisionKey = StageCaptureOutputNaming.collisionKey(for: fileName)
            guard collisionKeys.insert(collisionKey).inserted else {
                throw StageBatchRecordError.filenameCollision(fileName)
            }
            let outputURL = outputDirectory.appendingPathComponent(fileName)
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw StageBatchRecordError.outputAlreadyExists(fileName)
            }
            results.append((selectedCase, fileName))
        }
        return results
    }
}
