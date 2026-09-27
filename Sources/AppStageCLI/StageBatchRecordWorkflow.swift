import AppStage
import AppStageCapture
import AppStageControl
import Foundation

@MainActor
final class StageBatchRecordWorkflow {
    private let recordWorkflow: StageRecordWorkflow
    private let outputDirectory: URL
    private let manifestURL: URL
    private let bundleIdentifier: String
    private let captureConfiguration: StageCaptureConfiguration
    private let horizontalMargin: Double
    private let verticalMargin: Double
    private let timeout: Duration
    private let token: String
    private let sessionID: UUID
    private let existingApplicationPolicy: StageExistingApplicationPolicy

    init(
        recordWorkflow: StageRecordWorkflow,
        outputDirectory: URL,
        bundleIdentifier: String,
        captureConfiguration: StageCaptureConfiguration,
        horizontalMargin: Double,
        verticalMargin: Double,
        timeout: Duration,
        token: String,
        sessionID: UUID,
        existingApplicationPolicy: StageExistingApplicationPolicy
    ) {
        self.recordWorkflow = recordWorkflow
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.manifestURL = outputDirectory.standardizedFileURL.appendingPathComponent("manifest.json")
        self.bundleIdentifier = bundleIdentifier
        self.captureConfiguration = captureConfiguration
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
        self.timeout = timeout
        self.token = token
        self.sessionID = sessionID
        self.existingApplicationPolicy = existingApplicationPolicy
    }

    func run() async throws {
        var manifest: StageCaptureManifest?
        var activeScenarioIndex: Int?
        do {
            try prepareOutputDirectory()
            _ = try await recordWorkflow.startSession(
                bundleIdentifier: bundleIdentifier,
                token: token,
                sessionID: sessionID,
                timeout: timeout,
                existingApplicationPolicy: existingApplicationPolicy
            )

            let scenarios = try await recordWorkflow.discoverScenarios(timeout: timeout)
            let preflight = try preflight(scenarios)
            manifest = StageCaptureManifest(
                bundleIdentifier: bundleIdentifier,
                captureConfiguration: captureConfiguration,
                horizontalMargin: horizontalMargin,
                verticalMargin: verticalMargin,
                scenarios: preflight.map { metadata, fileName in
                    StageCaptureManifest.Scenario(
                        id: metadata.id.rawValue,
                        displayName: metadata.displayName,
                        declaredDurationMilliseconds: metadata.durationMilliseconds,
                        output: fileName,
                        status: .pending,
                        error: nil
                    )
                }
            )
            try manifest?.write(to: manifestURL)
            print("Found \(scenarios.count) scenarios.")

            for (index, item) in preflight.enumerated() {
                activeScenarioIndex = index
                manifest?.scenarios[index].status = .recording
                try manifest?.write(to: manifestURL)
                print("[\(index + 1)/\(preflight.count)] \(item.metadata.id.rawValue)")
                print("Recording...")
                let movieURL = outputDirectory.appendingPathComponent(item.fileName)
                try await recordWorkflow.recordScenario(
                    item.metadata.id,
                    bundleIdentifier: bundleIdentifier,
                    timeout: timeout,
                    outputURL: movieURL
                )
                manifest?.scenarios[index].status = .completed
                manifest?.scenarios[index].error = nil
                try manifest?.write(to: manifestURL)
                activeScenarioIndex = nil
                print("Completed: \(item.fileName)")
            }

            manifest?.finish(.completed)
            try manifest?.write(to: manifestURL)
            await recordWorkflow.close()
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
            await recordWorkflow.close()
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
        _ scenarios: [StageScenarioMetadata]
    ) throws -> [(metadata: StageScenarioMetadata, fileName: String)] {
        var identifiers = Set<StageScenarioID>()
        var collisionKeys = Set<String>()
        var results: [(StageScenarioMetadata, String)] = []
        for metadata in scenarios {
            guard identifiers.insert(metadata.id).inserted else {
                throw StageBatchRecordError.duplicateScenarioID(metadata.id.rawValue)
            }
            let fileName = try StageCaptureOutputNaming.fileName(for: metadata.id)
            let collisionKey = StageCaptureOutputNaming.collisionKey(for: fileName)
            guard collisionKeys.insert(collisionKey).inserted else {
                throw StageBatchRecordError.filenameCollision(fileName)
            }
            let outputURL = outputDirectory.appendingPathComponent(fileName)
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw StageBatchRecordError.outputAlreadyExists(fileName)
            }
            results.append((metadata, fileName))
        }
        return results
    }
}
