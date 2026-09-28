import AppKit
import Foundation

enum StageAppOwnership: Sendable, Equatable {
    case launchedByAppStage
    case preexisting
}

enum StageExistingApplicationPolicy: Sendable {
    case attach
    case reject
    case replace
}

@MainActor
protocol StageApplicationHandle: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var isTerminated: Bool { get }

    func terminate()
    func forceTerminate()
    func waitUntilTerminated(gracePeriod: Duration) async -> Bool
}

@MainActor
protocol StageApplicationManaging {
    func runningApplications(bundleIdentifier: String) -> [any StageApplicationHandle]
    func launchApplication(at url: URL, arguments: [String]) async throws -> any StageApplicationHandle
}

@MainActor
final class StageAppSession {
    static let defaultTerminationGracePeriod: Duration = .seconds(3)

    let ownership: StageAppOwnership
    let processIdentifier: pid_t
    let bundleIdentifier: String
    var isTerminated: Bool { application.isTerminated }

    private let application: any StageApplicationHandle
    private let keepAppRunning: Bool
    private let terminationGracePeriod: Duration
    private var isFinished = false

    private init(
        application: any StageApplicationHandle,
        bundleIdentifier: String,
        ownership: StageAppOwnership,
        keepAppRunning: Bool,
        terminationGracePeriod: Duration
    ) {
        self.application = application
        self.processIdentifier = application.processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.ownership = ownership
        self.keepAppRunning = keepAppRunning
        self.terminationGracePeriod = terminationGracePeriod
    }

    static func open(
        appURL: URL,
        bundleIdentifier: String,
        arguments: [String],
        keepAppRunning: Bool = false,
        existingApplicationPolicy: StageExistingApplicationPolicy = .attach,
        terminationGracePeriod: Duration = defaultTerminationGracePeriod,
        applicationManager: any StageApplicationManaging = SystemStageApplicationManager()
    ) async throws -> StageAppSession {
        let existing = applicationManager.runningApplications(bundleIdentifier: bundleIdentifier)
            .filter { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated }
        if !existing.isEmpty {
            switch existingApplicationPolicy {
            case .attach:
                return StageAppSession(
                    application: existing[0], bundleIdentifier: bundleIdentifier,
                    ownership: .preexisting, keepAppRunning: keepAppRunning,
                    terminationGracePeriod: terminationGracePeriod
                )
            case .reject:
                throw StageAppSessionError.targetAlreadyRunning
            case .replace:
                for application in existing {
                    let pid = application.processIdentifier
                    application.terminate()
                    if await application.waitUntilTerminated(gracePeriod: terminationGracePeriod) { continue }
                    guard application.processIdentifier == pid,
                          application.bundleIdentifier == bundleIdentifier,
                          !application.isTerminated else { continue }
                    application.forceTerminate()
                    guard await application.waitUntilTerminated(gracePeriod: terminationGracePeriod) else {
                        throw StageAppSessionError.couldNotReplace(pid)
                    }
                }
                try Task.checkCancellation()
            }
        }

        let application = try await applicationManager.launchApplication(at: appURL, arguments: arguments)
        guard application.bundleIdentifier == bundleIdentifier else {
            let launchedPID = application.processIdentifier
            let launchedBundleIdentifier = application.bundleIdentifier
            await terminateExactInstance(
                application,
                processIdentifier: launchedPID,
                bundleIdentifier: launchedBundleIdentifier,
                gracePeriod: terminationGracePeriod
            )
            throw StageAppSessionError.launchedBundleIdentifierMismatch(
                expected: bundleIdentifier,
                actual: application.bundleIdentifier
            )
        }
        let session = StageAppSession(
            application: application,
            bundleIdentifier: bundleIdentifier,
            ownership: .launchedByAppStage,
            keepAppRunning: keepAppRunning,
            terminationGracePeriod: terminationGracePeriod
        )
        if Task.isCancelled {
            await session.finish()
            throw CancellationError()
        }
        return session
    }

    func finish() async {
        guard !isFinished else { return }
        isFinished = true
        guard ownership == .launchedByAppStage,
              !keepAppRunning,
              ownsExactLiveInstance
        else { return }

        application.terminate()
        let exited = await application.waitUntilTerminated(gracePeriod: terminationGracePeriod)
        guard !exited, ownsExactLiveInstance else { return }
        application.forceTerminate()
        _ = await application.waitUntilTerminated(gracePeriod: terminationGracePeriod)
    }

    func performCapture<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            await finish()
            return result
        } catch {
            await finish()
            throw error
        }
    }

    private var ownsExactLiveInstance: Bool {
        application.processIdentifier == processIdentifier
            && application.bundleIdentifier == bundleIdentifier
            && !application.isTerminated
    }

    private static func terminateExactInstance(
        _ application: any StageApplicationHandle,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        gracePeriod: Duration
    ) async {
        guard application.processIdentifier == processIdentifier,
              application.bundleIdentifier == bundleIdentifier,
              !application.isTerminated else { return }
        application.terminate()
        guard !(await application.waitUntilTerminated(gracePeriod: gracePeriod)),
              application.processIdentifier == processIdentifier,
              application.bundleIdentifier == bundleIdentifier,
              !application.isTerminated else { return }
        application.forceTerminate()
        _ = await application.waitUntilTerminated(gracePeriod: gracePeriod)
    }
}

enum StageAppSessionError: LocalizedError {
    case launchedBundleIdentifierMismatch(expected: String, actual: String?)
    case targetAlreadyRunning
    case couldNotReplace(pid_t)

    var errorDescription: String? {
        switch self {
        case .targetAlreadyRunning:
            return "Target application is already running outside this AppStage control session. Quit it first or use --replace-existing."
        case let .couldNotReplace(pid):
            return "Could not stop existing target application (PID \(pid))."
        case let .launchedBundleIdentifierMismatch(expected, actual):
            return "Launched app bundle identifier did not match target (expected \(expected), got \(actual ?? "none"))."
        }
    }
}

@MainActor
private struct SystemStageApplicationManager: StageApplicationManaging {
    func runningApplications(bundleIdentifier: String) -> [any StageApplicationHandle] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated }
            .map(SystemStageApplicationHandle.init)
    }

    func launchApplication(at url: URL, arguments: [String]) async throws -> any StageApplicationHandle {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return SystemStageApplicationHandle(application)
    }
}

@MainActor
private final class SystemStageApplicationHandle: StageApplicationHandle {
    private let application: NSRunningApplication

    init(_ application: NSRunningApplication) {
        self.application = application
    }

    var processIdentifier: pid_t { application.processIdentifier }
    var bundleIdentifier: String? { application.bundleIdentifier }
    var isTerminated: Bool { application.isTerminated }

    func terminate() {
        _ = application.terminate()
    }

    func forceTerminate() {
        _ = application.forceTerminate()
    }

    func waitUntilTerminated(gracePeriod: Duration) async -> Bool {
        let waitTask = Task { @MainActor [application] in
            let deadline = ContinuousClock.now.advanced(by: gracePeriod)
            while !application.isTerminated && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return application.isTerminated
        }
        return await waitTask.value
    }
}
