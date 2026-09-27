import AppStage
import AppStageCapture
import AppStageControl
import Foundation

@MainActor
protocol StageRecordControlling {
    func start() async throws -> UInt16
    func bindExpectedPID(_ pid: Int32) async
    func waitForHandshake(timeout: Duration) async throws
    func request(_ command: StageControlCommand, timeout: Duration) async throws
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws
    func close() async
}

@MainActor
protocol StageRecordSessioning {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String { get }
    func finish() async
}

@MainActor
protocol StageRecordRecording {
    func start() async throws
    func stop() async throws
    func discardOutputIfOwned() async
}

extension StageAppSession: StageRecordSessioning {}

@MainActor
final class StageRecordWorkflow {
    private let controller: any StageRecordControlling
    private let openSession: @MainActor ([String], StageExistingApplicationPolicy) async throws -> any StageRecordSessioning
    private let makeRecorder: @MainActor (pid_t, String) async throws -> any StageRecordRecording

    init(
        controller: any StageRecordControlling,
        openSession: @escaping @MainActor ([String], StageExistingApplicationPolicy) async throws -> any StageRecordSessioning,
        makeRecorder: @escaping @MainActor (pid_t, String) async throws -> any StageRecordRecording
    ) {
        self.controller = controller
        self.openSession = openSession
        self.makeRecorder = makeRecorder
    }

    func run(
        scenarioID: StageScenarioID,
        bundleIdentifier: String,
        token: String,
        sessionID: UUID,
        timeout: Duration,
        existingApplicationPolicy: StageExistingApplicationPolicy
    ) async throws {
        var session: (any StageRecordSessioning)?
        var recorder: (any StageRecordRecording)?
        var recording = false
        var outputOwnedByWorkflow = false
        do {
            let port = try await controller.start()
            try Task.checkCancellation()
            let arguments = [
                "--appstage-scenario", scenarioID.rawValue,
                "--appstage-window", "1100x760",
                "--appstage-control-host", "127.0.0.1",
                "--appstage-control-port", String(port),
                "--appstage-control-token", token,
                "--appstage-control-session", sessionID.uuidString,
            ]
            let opened = try await openSession(arguments, existingApplicationPolicy)
            session = opened
            await controller.bindExpectedPID(opened.processIdentifier)
            try await controller.waitForHandshake(timeout: timeout)
            try await controller.request(.loadScenario(scenarioID), timeout: timeout)
            try await controller.request(.prepare, timeout: timeout)
            try await controller.waitForEvent(.ready, timeout: timeout)
            try Task.checkCancellation()
            let capture = try await makeRecorder(opened.processIdentifier, bundleIdentifier)
            recorder = capture
            try await capture.start()
            recording = true
            outputOwnedByWorkflow = true
            try Task.checkCancellation()
            try await controller.request(.play, timeout: timeout)
            try await controller.waitForEvent(.finished, timeout: timeout)
            recording = false
            try await capture.stop()
            try Task.checkCancellation()
            outputOwnedByWorkflow = false
            await controller.close()
            await opened.finish()
        } catch {
            if recording { try? await recorder?.stop() }
            if outputOwnedByWorkflow { await recorder?.discardOutputIfOwned() }
            await controller.close()
            await session?.finish()
            throw error
        }
    }
}

@MainActor
struct StageSystemRecordController: StageRecordControlling {
    let underlying: StageControlController
    func start() async throws -> UInt16 { try await underlying.start() }
    func bindExpectedPID(_ pid: Int32) async { await underlying.bindExpectedPID(pid) }
    func waitForHandshake(timeout: Duration) async throws { try await underlying.waitForHandshake(timeout: timeout) }
    func request(_ command: StageControlCommand, timeout: Duration) async throws {
        _ = try await underlying.request(command, timeout: timeout)
    }
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws {
        _ = try await underlying.waitForEvent(kind, timeout: timeout)
    }
    func close() async { await underlying.close() }
}

@MainActor
struct StageSystemRecordRecorder: StageRecordRecording {
    let underlying: StageVideoRecorder
    func start() async throws { try await underlying.start() }
    func stop() async throws { try await underlying.stop() }
    func discardOutputIfOwned() async { await underlying.discardOutputIfOwned() }
}
