import AppKit
import AppStage
import AppStageCapture
import AppStageControl
import ArgumentParser
import Foundation

@main
struct AppStageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appstage",
        abstract: "Launch, inspect, and capture macOS app scenarios.",
        subcommands: [
            ListCommand.self, ScenariosCommand.self, RunCommand.self,
            SnapshotCommand.self, RecordCommand.self, CaptureAllCommand.self, VerifyCommand.self,
            DoctorCommand.self,
        ]
    )
}

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a controlled app scenario without recording video."
    )

    @Option(name: .long, help: "Path to the target .app bundle.") var app: String
    @Option(name: .long, help: "Target app bundle identifier. Defaults to the app's bundle identifier.") var bundleID: String?
    @Option(name: .long, help: "Scenario identifier to run.") var scenario: String
    @Option(name: .long, help: "Timeout in seconds for handshake, preparation, and scenario completion.") var timeout: Int = 60
    @Flag(name: .long, help: "Terminate an already running target app and launch a new controlled instance.") var replaceExisting = false

    func run() async throws {
        guard (1...600).contains(timeout) else { throw ValidationError("--timeout must be between 1 and 600 seconds.") }
        let appURL = URL(fileURLWithPath: app).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let appBundleID = Bundle(url: appURL)?.bundleIdentifier, !appBundleID.isEmpty else {
            throw ValidationError("--app must point to an app bundle with a bundle identifier.")
        }
        if let bundleID, bundleID != appBundleID {
            throw ValidationError("--bundle-id must match the app bundle identifier (\(appBundleID)).")
        }
        try await runScenario(
            appURL: appURL, bundleIdentifier: appBundleID, scenarioID: StageScenarioID(scenario),
            timeout: .seconds(timeout), policy: replaceExisting ? .replace : .reject
        )
    }
}

@MainActor
private func runScenario(
    appURL: URL,
    bundleIdentifier: String,
    scenarioID: StageScenarioID,
    timeout: Duration,
    policy: StageExistingApplicationPolicy
) async throws {
    let token = try StageControlToken.generate()
    let sessionID = UUID()
    let controller = StageControlController(
        token: token, sessionID: sessionID, bundleIdentifier: bundleIdentifier,
        accessibilityHandler: { operation, pid in StageAccessibilityController.handle(operation, pid: pid) }
    )
    var session: StageAppSession?
    do {
        let port = try await controller.start()
        let opened = try await StageAppSession.open(
            appURL: appURL, bundleIdentifier: bundleIdentifier,
            arguments: [
                "--appstage-scenario", scenarioID.rawValue,
                "--appstage-window", "1100x760",
                "--appstage-control-host", "127.0.0.1",
                "--appstage-control-port", String(port),
                "--appstage-control-token", token,
                "--appstage-control-session", sessionID.uuidString,
            ],
            existingApplicationPolicy: policy
        )
        session = opened
        await controller.bindExpectedPID(opened.processIdentifier)
        try await controller.waitForHandshake(timeout: timeout)
        _ = try await controller.request(.loadScenario(scenarioID), timeout: timeout)
        _ = try await controller.request(.prepare, timeout: timeout)
        _ = try await controller.waitForEvent(.ready, timeout: timeout)
        _ = try await controller.request(.play, timeout: timeout)
        _ = try await controller.waitForEvent(.finished, timeout: timeout)
        await controller.close()
        await opened.finish()
        print("Scenario finished: \(scenarioID.rawValue)")
    } catch {
        await controller.close()
        await session?.finish()
        throw error
    }
}

struct ScenariosCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scenarios",
        abstract: "Launch a controlled app session and list its available scenarios."
    )

    @Option(name: .long, help: "Path to the target .app bundle.")
    var app: String

    @Option(name: .long, help: "Target app bundle identifier. Defaults to the app's bundle identifier.")
    var bundleID: String?

    @Option(name: .long, help: "Timeout in seconds for host discovery (default: 30).")
    var timeout: Int = 30

    @Flag(name: .long, help: "Terminate an already running target app and launch a new controlled instance.")
    var replaceExisting = false

    func run() async throws {
        guard (1...600).contains(timeout) else {
            throw ValidationError("--timeout must be between 1 and 600 seconds.")
        }
        let applicationURL = URL(fileURLWithPath: app).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let applicationBundleID = Bundle(url: applicationURL)?.bundleIdentifier,
              !applicationBundleID.isEmpty
        else {
            throw ValidationError("--app must point to an app bundle with a bundle identifier.")
        }
        if let bundleID, bundleID != applicationBundleID {
            throw ValidationError("--bundle-id must match the app bundle identifier (\(applicationBundleID)).")
        }

        try await discoverScenarios(
            appURL: applicationURL,
            bundleIdentifier: applicationBundleID,
            timeout: .seconds(timeout),
            policy: replaceExisting ? .replace : .reject
        )
    }
}

@MainActor
private func discoverScenarios(
    appURL: URL,
    bundleIdentifier: String,
    timeout: Duration,
    policy: StageExistingApplicationPolicy
) async throws {
    let token = try StageControlToken.generate()
    let sessionID = UUID()
    let controller = StageControlController(
        token: token, sessionID: sessionID, bundleIdentifier: bundleIdentifier,
        accessibilityHandler: { operation, pid in StageAccessibilityController.handle(operation, pid: pid) }
    )
    var appSession: StageAppSession?
    do {
        let port = try await controller.start()
        let opened = try await StageAppSession.open(
            appURL: appURL,
            bundleIdentifier: bundleIdentifier,
            arguments: [
                "--appstage-discover-scenarios",
                "--appstage-control-host", "127.0.0.1",
                "--appstage-control-port", String(port),
                "--appstage-control-token", token,
                "--appstage-control-session", sessionID.uuidString,
            ],
            existingApplicationPolicy: policy
        )
        appSession = opened
        await controller.bindExpectedPID(opened.processIdentifier)
        try await controller.waitForHandshake(timeout: timeout)
        let result = try await controller.request(.listScenarios, timeout: timeout)
        let scenarios = result.scenarios ?? []
        if scenarios.isEmpty {
            print("No scenarios are available.")
        } else {
            for scenario in scenarios {
                let name = scenario.displayName.map { "\t\($0)" } ?? ""
                let duration = scenario.durationMilliseconds.map { "\t\($0) ms" } ?? ""
                print("\(scenario.id.rawValue)\(name)\(duration)")
            }
        }
        await controller.close()
        await opened.finish()
    } catch {
        await controller.close()
        await appSession?.finish()
        throw error
    }
}

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List running applications available to ScreenCaptureKit."
    )

    func run() async throws {
        let applications = try await StageCaptureDiscovery.applications()
        guard !applications.isEmpty else {
            print("No shareable applications found.")
            return
        }

        for application in applications {
            print("\(application.applicationName)\t\(application.bundleIdentifier)")
        }
    }
}

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture a PNG of a running app window with desktop around it."
    )

    @Option(name: .long, help: "Bundle identifier of the running app.")
    var bundleID: String

    @Option(name: .long, help: "PNG output path.")
    var output: String

    @Option(name: .long, help: "Horizontal desktop margin in points.")
    var horizontalMargin: Double = 220

    @Option(name: .long, help: "Vertical desktop margin in points.")
    var verticalMargin: Double = 120

    func run() async throws {
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        guard outputURL.pathExtension.lowercased() == "png" else {
            throw ValidationError("--output must use a .png extension.")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ValidationError("The output file already exists: \(outputURL.path)")
        }

        let (window, display) = try await captureTarget(bundleIdentifier: bundleID)
        let image = try await StageScreenshot.capture(
            window: window,
            display: display,
            framing: .desktopAroundWindow(
                horizontalMargin: CGFloat(horizontalMargin),
                verticalMargin: CGFloat(verticalMargin)
            )
        )
        try StageScreenshot.writePNG(image, to: outputURL)
        print("Wrote \(image.width)×\(image.height) PNG to \(outputURL.path)")
    }
}

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Launch an app scenario and record it to a QuickTime MOV."
    )

    @Option(name: .long, help: "Path to the target .app bundle.")
    var app: String

    @Option(name: .long, help: "Target app bundle identifier. Defaults to the app's bundle identifier.")
    var bundleID: String?

    @Option(name: .long, help: "Scenario identifier passed to the target app.")
    var scenario: String

    @Option(name: .long, help: "Deprecated; ignored for controlled scenarios, which end on the host finished event.")
    var duration: Int = 10

    @Option(name: .long, help: "Timeout in seconds for handshake, prepare, and scenario completion (default: 30).")
    var timeout: Int = 30

    @Option(name: .long, help: "MOV output path.")
    var output: String

    @Option(name: .long, help: "Background image used as the final video canvas.")
    var backgroundImage: String?

    @Option(name: .long, help: "Horizontal desktop margin in points.")
    var horizontalMargin: Double = 220

    @Option(name: .long, help: "Vertical desktop margin in points.")
    var verticalMargin: Double = 120

    @Option(name: .long, help: "Output frame rate.")
    var frameRate: Int = 60

    @Flag(name: .long, help: "Keep an application launched by AppStage running after capture finishes. Pre-existing applications are never terminated.")
    var keepAppRunning = false

    @Flag(name: .long, help: "Terminate an already running target app and launch a new controlled instance.")
    var replaceExisting = false

    func run() async throws {
        guard (1...600).contains(duration) else {
            throw ValidationError("--duration must be between 1 and 600 seconds.")
        }
        guard (1...600).contains(timeout) else {
            throw ValidationError("--timeout must be between 1 and 600 seconds.")
        }
        guard horizontalMargin.isFinite, verticalMargin.isFinite,
              horizontalMargin >= 0, verticalMargin >= 0
        else {
            throw ValidationError("Capture margins must be finite, non-negative numbers.")
        }
        guard !scenario.isEmpty else {
            throw ValidationError("--scenario must not be empty.")
        }

        let applicationURL = URL(fileURLWithPath: app).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ValidationError("--app must point to an existing .app bundle.")
        }
        guard let applicationBundleID = Bundle(url: applicationURL)?.bundleIdentifier,
              !applicationBundleID.isEmpty else {
            throw ValidationError("Could not read the app bundle identifier; provide --bundle-id.")
        }
        if let bundleID, bundleID != applicationBundleID {
            throw ValidationError("--bundle-id must match the app bundle identifier (\(applicationBundleID)).")
        }

        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        guard outputURL.pathExtension.lowercased() == "mov" else {
            throw ValidationError("--output must use a .mov extension.")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ValidationError("The output file already exists: \(outputURL.path)")
        }

        let canvas: StageCanvasConfiguration?
        if let backgroundImage {
            let backgroundURL = URL(fileURLWithPath: backgroundImage).standardizedFileURL
            do {
                canvas = try StageCanvasConfiguration(backgroundImageURL: backgroundURL)
            } catch let error as LocalizedError {
                throw ValidationError(error.errorDescription ?? "Background image could not be decoded.")
            }
        } else {
            canvas = nil
        }

        let captureConfiguration = try StageCaptureConfiguration(
            resolution: canvas?.resolution,
            frameRate: frameRate,
            cursor: .hidden,
            framing: .desktopAroundWindow(
                horizontalMargin: CGFloat(horizontalMargin),
                verticalMargin: CGFloat(verticalMargin)
            ),
            includesApplicationWindows: true,
            canvas: canvas
        )

        let captureTask = Task { @MainActor in
            let token = try StageControlToken.generate()
            let sessionID = UUID()
            let workflow = StageRecordWorkflow(
                controller: StageSystemRecordController(
                    underlying: StageControlController(
                        token: token, sessionID: sessionID, bundleIdentifier: applicationBundleID,
                        accessibilityHandler: { operation, pid in StageAccessibilityController.handle(operation, pid: pid) }
                    )
                ),
                openSession: { arguments, policy in
                    try await StageAppSession.open(
                        appURL: applicationURL,
                        bundleIdentifier: applicationBundleID,
                        arguments: arguments,
                        keepAppRunning: keepAppRunning,
                        existingApplicationPolicy: policy
                    )
                },
                makeRecorder: { pid, bundleID, outputURL in
                    let window = try await waitForWindow(
                        bundleIdentifier: bundleID,
                        processIdentifier: pid,
                        timeout: .seconds(timeout)
                    )
                    let targetDisplay = try await display(for: window)
                    return StageSystemRecordRecorder(underlying: StageVideoRecorder(
                        window: window,
                        display: targetDisplay,
                        configuration: captureConfiguration,
                        outputURL: outputURL
                    ))
                }
            )
            try await workflow.run(
                scenarioID: StageScenarioID(scenario), bundleIdentifier: applicationBundleID,
                token: token, sessionID: sessionID, timeout: .seconds(timeout),
                existingApplicationPolicy: replaceExisting ? .replace : .reject,
                outputURL: outputURL
            )
        }
        let signalCancellation = StageRecordSignalCancellation(task: captureTask)
        defer { signalCancellation.cancel() }
        do {
            try await captureTask.value
        } catch is CancellationError {
            throw ValidationError("Recording cancelled.")
        }

        print("Wrote MOV to \(outputURL.path)")
    }
}

struct CaptureAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-all",
        abstract: "Record each scenario in a fresh controlled app process, sequentially."
    )

    @Option(name: .long, help: "Path to the target .app bundle.")
    var app: String

    @Option(name: .long, help: "Target app bundle identifier. Defaults to the app's bundle identifier.")
    var bundleID: String?

    @Option(name: .customLong("output-dir"), help: "Directory for scenario MOVs and manifest.json.")
    var outputDirectory: String

    @Option(name: .long, help: "Background image used as the final video canvas.")
    var backgroundImage: String?

    @Option(name: .long, help: "Timeout in seconds for handshake, preparation, and each scenario (default: 30).")
    var timeout: Int = 30

    @Option(name: .long, help: "Horizontal desktop margin in points.")
    var horizontalMargin: Double = 220

    @Option(name: .long, help: "Vertical desktop margin in points.")
    var verticalMargin: Double = 120

    @Option(name: .long, help: "Output frame rate.")
    var frameRate: Int = 60

    @Flag(name: .long, help: "Terminate an already running target app and launch a new controlled instance.")
    var replaceExisting = false

    func run() async throws {
        guard (1...600).contains(timeout) else {
            throw ValidationError("--timeout must be between 1 and 600 seconds.")
        }
        guard horizontalMargin.isFinite, verticalMargin.isFinite,
              horizontalMargin >= 0, verticalMargin >= 0
        else {
            throw ValidationError("Capture margins must be finite, non-negative numbers.")
        }

        let applicationURL = URL(fileURLWithPath: app).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ValidationError("--app must point to an existing .app bundle.")
        }
        guard let applicationBundleID = Bundle(url: applicationURL)?.bundleIdentifier,
              !applicationBundleID.isEmpty else {
            throw ValidationError("Could not read the app bundle identifier; provide --bundle-id.")
        }
        if let bundleID, bundleID != applicationBundleID {
            throw ValidationError("--bundle-id must match the app bundle identifier (\(applicationBundleID)).")
        }

        let canvas: StageCanvasConfiguration?
        if let backgroundImage {
            let backgroundURL = URL(fileURLWithPath: backgroundImage).standardizedFileURL
            do {
                canvas = try StageCanvasConfiguration(backgroundImageURL: backgroundURL)
            } catch let error as LocalizedError {
                throw ValidationError(error.errorDescription ?? "Background image could not be decoded.")
            }
        } else {
            canvas = nil
        }
        let captureConfiguration: StageCaptureConfiguration
        do {
            captureConfiguration = try StageCaptureConfiguration(
                resolution: canvas?.resolution,
                frameRate: frameRate,
                cursor: .hidden,
                framing: .desktopAroundWindow(
                    horizontalMargin: CGFloat(horizontalMargin),
                    verticalMargin: CGFloat(verticalMargin)
                ),
                includesApplicationWindows: true,
                canvas: canvas
            )
        } catch {
            throw ValidationError("Invalid capture configuration: \(error.localizedDescription)")
        }

        let captureTask = Task { @MainActor in
            let workflow = StageBatchRecordWorkflow(
                discoverScenarios: {
                    let (recordWorkflow, token, sessionID) = try makeBatchRoundWorkflow(
                        appURL: applicationURL,
                        bundleIdentifier: applicationBundleID,
                        captureConfiguration: captureConfiguration,
                        timeout: .seconds(timeout)
                    )
                    return try await recordWorkflow.runDiscovery(
                        bundleIdentifier: applicationBundleID,
                        token: token,
                        sessionID: sessionID,
                        timeout: .seconds(timeout),
                        existingApplicationPolicy: replaceExisting ? .replace : .reject
                    )
                },
                recordScenario: { scenarioID, movieURL in
                    let (recordWorkflow, token, sessionID) = try makeBatchRoundWorkflow(
                        appURL: applicationURL,
                        bundleIdentifier: applicationBundleID,
                        captureConfiguration: captureConfiguration,
                        timeout: .seconds(timeout)
                    )
                    try await recordWorkflow.run(
                        scenarioID: scenarioID,
                        bundleIdentifier: applicationBundleID,
                        token: token,
                        sessionID: sessionID,
                        timeout: .seconds(timeout),
                        existingApplicationPolicy: replaceExisting ? .replace : .reject,
                        outputURL: movieURL
                    )
                },
                outputDirectory: URL(fileURLWithPath: outputDirectory).standardizedFileURL,
                bundleIdentifier: applicationBundleID,
                captureConfiguration: captureConfiguration,
                horizontalMargin: horizontalMargin,
                verticalMargin: verticalMargin
            )
            try await workflow.run()
        }
        let signalCancellation = StageRecordSignalCancellation(task: captureTask)
        defer { signalCancellation.cancel() }
        do {
            try await captureTask.value
        } catch is CancellationError {
            throw ValidationError("Batch capture cancelled.")
        }
    }
}

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Reliability-verify every discovered scenario using fresh app processes."
    )

    @Option(name: .long, help: "Path to the target .app bundle.") var app: String
    @Option(name: .long, help: "Target app bundle identifier; defaults to the app bundle identifier.") var bundleID: String?
    @Option(name: .long, help: "Independent recordings per scenario (default: 20).") var iterations = 20
    @Option(name: .long, help: "Root output directory for this verification run.") var output: String = "~/Desktop/AppStage-Verify"
    @Option(name: .long, help: "Timeout in seconds per Control/lifecycle phase (default: 60).") var timeout = 60
    @Option(name: .long, help: "Movie retention policy: failures, all, or none (default: failures).") var retainMovies = "failures"

    func run() async throws {
        guard (1...1_000).contains(iterations) else { throw ValidationError("--iterations must be between 1 and 1000.") }
        guard (1...600).contains(timeout) else { throw ValidationError("--timeout must be between 1 and 600 seconds.") }
        guard ["failures", "all", "none"].contains(retainMovies) else {
            throw ValidationError("--retain-movies must be failures, all, or none.")
        }
        let appURL = URL(fileURLWithPath: (app as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let applicationBundleID = Bundle(url: appURL)?.bundleIdentifier, !applicationBundleID.isEmpty else {
            throw ValidationError("--app must point to an app bundle with a bundle identifier.")
        }
        if let bundleID, bundleID != applicationBundleID {
            throw ValidationError("--bundle-id must match the app bundle identifier (\(applicationBundleID)).")
        }
        try await performVerification(
            appURL: appURL, bundleIdentifier: applicationBundleID,
            iterations: iterations, output: output, timeout: timeout, retainMovies: retainMovies
        )
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check whether this Mac can run AppStage GUI verification."
    )

    @Option(name: .long, help: "Path to the target .app bundle.") var app: String
    @Flag(name: .long, help: "Print the full environment report as JSON.") var json = false
    @Option(name: .long, help: "Write the full environment report to this JSON file.") var output: String?

    func run() async throws {
        let appURL = URL(fileURLWithPath: (app as NSString).expandingTildeInPath).standardizedFileURL
        let outputURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        if let outputURL {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        let report = StageDoctor.inspect(appURL: appURL, outputURL: outputURL)
        if let outputURL {
            try writeJSON(report, to: outputURL)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("AppStage doctor: \(report.passed ? "PASS" : "FAIL")")
            for check in report.checks {
                print("\(check.passed ? "PASS" : "FAIL")  \(check.name): \(check.detail)")
            }
            if let outputURL { print("Report: \(outputURL.path)") }
        }
        if !report.passed { throw ExitCode.failure }
    }
}

@MainActor
private func performVerification(
    appURL: URL,
    bundleIdentifier applicationBundleID: String,
    iterations: Int,
    output: String,
    timeout: Int,
    retainMovies: String
) async throws {
        let root = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let runDirectory = root.appendingPathComponent("run-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        let captureConfiguration = try StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: 100, verticalMargin: 50),
            includesApplicationWindows: true
        )
        let (discovery, token, sessionID) = try makeBatchRoundWorkflow(
            appURL: appURL, bundleIdentifier: applicationBundleID,
            captureConfiguration: captureConfiguration, timeout: .seconds(timeout)
        )
        let scenarios: [StageScenarioMetadata]
        do {
            scenarios = try await discovery.runDiscovery(
                bundleIdentifier: applicationBundleID, token: token, sessionID: sessionID,
                timeout: .seconds(timeout), existingApplicationPolicy: .reject
            )
        } catch {
            let setupFailure = error.localizedDescription
            let summary = StageVerifySummary(
                generatedAt: Date(), iterationsRequested: iterations, attemptsTotal: 0,
                passed: 0, failed: 0, perScenario: [:], failureCountsByPhase: ["scenarioDiscovery": 1],
                maxControlConnectDuration: nil, maxPrepareDuration: nil, maxFinalizeDuration: nil,
                orphanProcessCount: 0, cleanupFailureCount: 0, determinismWarnings: [],
                telemetryNotes: [
                    "Condition IDs and AX element snapshots are unavailable in Control Protocol v3; no Host-side telemetry is inferred.",
                    "NSWorkspace does not expose the launched GUI process exit code; process exit is verified, but the code is unavailable."
                ], attempts: [], setupFailurePhase: "scenarioDiscovery", setupFailure: setupFailure
            )
            try writeJSON(summary, to: runDirectory.appendingPathComponent("summary.json"))
            try summaryText(summary).write(to: runDirectory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            throw ValidationError("Scenario discovery failed: \(error.localizedDescription)")
        }

        var attempts: [StageVerifyAttempt] = []
        var semanticSequences: [String: [String]] = [:]
        for iteration in 1...iterations {
            for scenario in scenarios {
                let scenarioName = scenario.id.rawValue.replacingOccurrences(of: "/", with: "-")
                let scenarioDirectory = runDirectory.appendingPathComponent(scenarioName, isDirectory: true)
                try FileManager.default.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
                let attemptDirectory = scenarioDirectory.appendingPathComponent(String(format: "attempt-%03d", iteration), isDirectory: true)
                try FileManager.default.createDirectory(at: attemptDirectory, withIntermediateDirectories: true)
                let movieURL = attemptDirectory.appendingPathComponent("recording.mov")
                var attempt = StageVerifyAttempt(scenarioID: scenario.id.rawValue, iteration: iteration, startedAt: Date())
                var latestPhase = StageRecordWorkflow.Phase.launch
                let (workflow, attemptToken, attemptSessionID) = try makeBatchRoundWorkflow(
                    appURL: appURL, bundleIdentifier: applicationBundleID,
                    captureConfiguration: captureConfiguration, timeout: .seconds(timeout),
                    eventHandler: { phase, message, pid, duration in
                        if message.hasPrefix("failure:") { latestPhase = phase }
                        if phase == .launch { attempt.pid = pid }
                        if phase == .recordingFinalize {
                            attempt.writerFinalizeState = message.hasPrefix("failure:") ? "failed" : "completed"
                        }
                        if phase == .recordingCleanup, message == "recorder cleanup completed" {
                            attempt.writerFinalizeState = "abortedOrReleased"
                        }
                        if let duration {
                            let seconds = Double(duration) / 1_000
                            switch phase {
                            case .controlConnect: attempt.controlConnectDuration = seconds
                            case .loadScenario: attempt.loadDuration = seconds
                            case .prepareScenario: attempt.prepareDuration = seconds
                            case .scenarioRuntime:
                                attempt.playDuration = seconds
                                attempt.finishDuration = seconds
                                attempt.recordDuration = seconds
                            default: break
                            }
                        }
                        if phase == .processTermination {
                            attempt.processExitCode = pid
                            attempt.processExitedCleanly = message == "child exited"
                        }
                        attempt.events.append(StageVerifyEvent(timestamp: Date(), phase: phase.rawValue, message: message, pid: phase == .launch ? pid : nil, durationMilliseconds: duration))
                    }
                )
                attempt.controlSessionID = attemptSessionID
                func recorderCleanupVerified() -> Bool {
                    let recorderStarted = attempt.events.contains(where: {
                        $0.phase == StageRecordWorkflow.Phase.recordingStart.rawValue && $0.message == "recording started"
                    })
                    guard recorderStarted else { return true }
                    return attempt.events.contains(where: {
                        ($0.phase == StageRecordWorkflow.Phase.recordingFinalize.rawValue && $0.message == "recording finalized")
                            || ($0.phase == StageRecordWorkflow.Phase.recordingCleanup.rawValue && $0.message == "recorder cleanup completed")
                    })
                }
                do {
                    try await workflow.run(
                        scenarioID: scenario.id, bundleIdentifier: applicationBundleID,
                        token: attemptToken, sessionID: attemptSessionID, timeout: .seconds(timeout),
                        existingApplicationPolicy: .reject, outputURL: movieURL
                    )
                    guard attempt.pid != nil else {
                        latestPhase = .launch
                        throw StageVerifyError.invalidMovie("No child PID was recorded")
                    }
                    guard attempt.events.contains(where: { $0.phase == StageRecordWorkflow.Phase.processTermination.rawValue && $0.message == "child exited" }) else {
                        latestPhase = .processTermination
                        throw StageVerifyError.invalidMovie("Child process did not exit cleanly")
                    }
                    if let exitCode = attempt.processExitCode, exitCode != 0 {
                        latestPhase = .processTermination
                        throw StageVerifyError.invalidMovie("Child process exit code was \(exitCode)")
                    }
                    latestPhase = .movieValidation
                    let movie = try await StageVerifyWorkflow.validateMovie(
                        at: movieURL, expectedDurationMilliseconds: scenario.durationMilliseconds
                    )
                    attempt.frameCount = movie.frames
                    attempt.firstFrameTimestamp = movie.firstPTS
                    attempt.lastFrameTimestamp = movie.lastPTS
                    attempt.videoDuration = movie.duration
                    attempt.videoWidth = movie.width
                    attempt.videoHeight = movie.height
                    attempt.fileSize = movie.size
                    attempt.status = "pass"
                    attempt.cleanupPassed = attempt.processExitedCleanly
                        && attempt.events.contains(where: { $0.phase == StageRecordWorkflow.Phase.controlDisconnect.rawValue })
                        && recorderCleanupVerified()
                    if !attempt.cleanupPassed {
                        attempt.status = "fail"
                        attempt.failedPhase = StageRecordWorkflow.Phase.cleanup.rawValue
                        attempt.error = "Control connection cleanup could not be verified"
                    }
                } catch {
                    attempt.failedPhase = latestPhase.rawValue
                    attempt.error = error.localizedDescription
                    let disconnected = attempt.events.contains(where: { $0.phase == StageRecordWorkflow.Phase.controlDisconnect.rawValue })
                    attempt.cleanupPassed = (attempt.pid == nil || attempt.processExitedCleanly)
                        && disconnected && recorderCleanupVerified()
                }
                attempt.finishedAt = Date()
                attempt.totalDuration = attempt.finishedAt!.timeIntervalSince(attempt.startedAt)
                let sequence = attempt.events.map(\.phase).filter { ["controlConnect", "loadScenario", "prepareScenario", "recordingStart", "playScenario", "scenarioRuntime", "recordingFinalize", "controlDisconnect", "processTermination"].contains($0) }
                if let previous = semanticSequences[scenario.id.rawValue], previous != sequence {
                    attempt.events.append(StageVerifyEvent(timestamp: Date(), phase: "determinismWarning", message: "Semantic event sequence differs from an earlier attempt", pid: attempt.pid, durationMilliseconds: nil))
                } else {
                    semanticSequences[scenario.id.rawValue] = sequence
                }
                try writeJSON(attempt, to: attemptDirectory.appendingPathComponent("result.json"))
                try writeJSON(attempt.events, to: attemptDirectory.appendingPathComponent("trace.json"))
                if attempt.status == "fail" {
                    try writeJSON(attempt, to: attemptDirectory.appendingPathComponent("diagnostics.json"))
                }
                let shouldRetainMovie = retainMovies == "all"
                    || (retainMovies == "failures" && attempt.status == "fail")
                if !shouldRetainMovie, FileManager.default.fileExists(atPath: movieURL.path) {
                    do {
                        try FileManager.default.removeItem(at: movieURL)
                    } catch {
                        attempt.status = "fail"
                        attempt.failedPhase = StageRecordWorkflow.Phase.cleanup.rawValue
                        attempt.error = "Could not remove unretained MOV: \(error.localizedDescription)"
                        attempt.cleanupPassed = false
                        try writeJSON(attempt, to: attemptDirectory.appendingPathComponent("result.json"))
                        try writeJSON(attempt, to: attemptDirectory.appendingPathComponent("diagnostics.json"))
                    }
                }
                attempts.append(attempt)
                print("[\(scenario.id.rawValue) #\(iteration)] \(attempt.status.uppercased())\(attempt.failedPhase.map { " phase=\($0)" } ?? "")")
            }
        }

        var perScenario: [String: StageVerifyScenarioSummary] = [:]
        for scenario in scenarios {
            let subset = attempts.filter { $0.scenarioID == scenario.id.rawValue }
            let passed = subset.filter { $0.status == "pass" }.count
            perScenario[scenario.id.rawValue] = StageVerifyScenarioSummary(attempts: subset.count, passed: passed, failed: subset.count - passed)
        }
        let failures = Dictionary(grouping: attempts.compactMap(\.failedPhase), by: { $0 }).mapValues(\.count)
        func maxDuration(_ phase: String) -> Double? {
            attempts.flatMap(\.events).filter { $0.phase == phase }.compactMap(\.durationMilliseconds).map { Double($0) / 1_000 }.max()
        }
        let summary = StageVerifySummary(
            generatedAt: Date(), iterationsRequested: iterations, attemptsTotal: attempts.count,
            passed: attempts.filter { $0.status == "pass" }.count,
            failed: attempts.filter { $0.status == "fail" }.count,
            perScenario: perScenario, failureCountsByPhase: failures,
            maxControlConnectDuration: maxDuration("controlConnect"),
            maxPrepareDuration: maxDuration("prepareScenario"),
            maxFinalizeDuration: maxDuration("recordingFinalize"),
            orphanProcessCount: attempts.filter { $0.pid != nil && !$0.processExitedCleanly }.count,
            cleanupFailureCount: attempts.filter { !$0.cleanupPassed }.count,
            determinismWarnings: attempts.filter { $0.events.contains(where: { $0.phase == "determinismWarning" }) }.map { "\($0.scenarioID) #\($0.iteration)" },
            telemetryNotes: [
                "Condition IDs and AX element snapshots are unavailable in Control Protocol v3; no Host-side telemetry is inferred.",
                "NSWorkspace does not expose the launched GUI process exit code; process exit is verified, but the code is unavailable."
            ], attempts: attempts, setupFailurePhase: nil, setupFailure: nil
        )
        try writeJSON(summary, to: runDirectory.appendingPathComponent("summary.json"))
        try summaryText(summary).write(to: runDirectory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print("\nAppStage Reliability Verification\n\(summary.attemptsTotal) attempts — \(summary.passed) PASS, \(summary.failed) FAIL\nOrphan process: \(summary.orphanProcessCount)\nCleanup failure: \(summary.cleanupFailureCount)\nOutput: \(runDirectory.path)")
        if summary.failed > 0 { throw ExitCode.failure }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func summaryText(_ summary: StageVerifySummary) -> String {
    let finalizeFailures = summary.attempts.filter { $0.writerFinalizeState == "failed" }.count
    let invalidMovies = summary.failureCountsByPhase[StageRecordWorkflow.Phase.movieValidation.rawValue] ?? 0
    var lines = [
        "AppStage Reliability Verification",
        "",
        "Scenarios: \(summary.perScenario.count)",
        "Rounds: \(summary.iterationsRequested)",
        "Attempts: \(summary.attemptsTotal)",
        "PASS: \(summary.passed)",
        "FAIL: \(summary.failed)",
        "Invalid MOV: \(invalidMovies)",
        "Recording finalize failures: \(finalizeFailures)",
        "Max control connect: \(summary.maxControlConnectDuration.map { String(format: "%.3f s", $0) } ?? "n/a")",
        "Max prepare: \(summary.maxPrepareDuration.map { String(format: "%.3f s", $0) } ?? "n/a")",
        "Max finalize: \(summary.maxFinalizeDuration.map { String(format: "%.3f s", $0) } ?? "n/a")",
        ""
    ]
    for (scenario, result) in summary.perScenario.sorted(by: { $0.key < $1.key }) {
        lines.append("\(scenario): \(result.passed)/\(result.attempts) PASS (\(Int(result.passRate * 100))%)")
    }
    lines.append("")
    for attempt in summary.attempts where attempt.status == "fail" {
        lines += ["Failure:", "\(attempt.scenarioID) #\(attempt.iteration)", "phase: \(attempt.failedPhase ?? "unknown")", "reason: \(attempt.error ?? "unknown")", ""]
    }
    if let setupFailure = summary.setupFailure {
        lines += ["Setup failure:", "phase: \(summary.setupFailurePhase ?? "unknown")", "reason: \(setupFailure)", ""]
    }
    lines += ["Orphan process: \(summary.orphanProcessCount)", "Cleanup failure: \(summary.cleanupFailureCount)"]
    lines += ["", "Telemetry gap: Control Protocol v3 does not expose Host condition IDs or AX snapshots."]
    if !summary.determinismWarnings.isEmpty { lines += ["", "Determinism warnings:"] + summary.determinismWarnings }
    return lines.joined(separator: "\n") + "\n"
}

@MainActor
private func makeBatchRoundWorkflow(
    appURL: URL,
    bundleIdentifier: String,
    captureConfiguration: StageCaptureConfiguration,
    timeout: Duration,
    eventHandler: @escaping StageRecordWorkflow.EventHandler = { _, _, _, _ in }
) throws -> (workflow: StageRecordWorkflow, token: String, sessionID: UUID) {
    let token = try StageControlToken.generate()
    let sessionID = UUID()
    let controller = StageSystemRecordController(
        underlying: StageControlController(
            token: token,
            sessionID: sessionID,
            bundleIdentifier: bundleIdentifier,
            accessibilityHandler: { operation, pid in
                StageAccessibilityController.handle(operation, pid: pid)
            }
        )
    )
    let workflow = StageRecordWorkflow(
        controller: controller,
        openSession: { arguments, policy in
            try await StageAppSession.open(
                appURL: appURL,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments,
                existingApplicationPolicy: policy
            )
        },
        makeRecorder: { pid, bundleID, outputURL in
            let window = try await waitForWindow(
                bundleIdentifier: bundleID,
                processIdentifier: pid,
                timeout: timeout
            )
            let targetDisplay = try await display(for: window)
            return StageSystemRecordRecorder(underlying: StageVideoRecorder(
                window: window,
                display: targetDisplay,
                configuration: captureConfiguration,
                outputURL: outputURL
            ))
        },
        eventHandler: eventHandler
    )
    return (workflow, token, sessionID)
}

private func captureTarget(bundleIdentifier: String) async throws -> (StageCaptureWindow, StageCaptureDisplay) {
    let window = try await StageCaptureDiscovery.window(bundleIdentifier: bundleIdentifier)
    return (window, try await display(for: window))
}

private func display(for window: StageCaptureWindow) async throws -> StageCaptureDisplay {
    let displays = try await StageCaptureDiscovery.displays()
    let selected = displays.max { lhs, rhs in
        let lhsIntersection = lhs.frame.intersection(window.frame)
        let rhsIntersection = rhs.frame.intersection(window.frame)
        let lhsArea = lhsIntersection.isNull ? 0 : lhsIntersection.width * lhsIntersection.height
        let rhsArea = rhsIntersection.isNull ? 0 : rhsIntersection.width * rhsIntersection.height
        if lhsArea == rhsArea {
            return lhs.displayID > rhs.displayID
        }
        return lhsArea < rhsArea
    }
    guard let selected,
          !selected.frame.intersection(window.frame).isNull,
          !selected.frame.intersection(window.frame).isEmpty
    else {
        throw ValidationError("Could not find a display containing the target app window.")
    }
    return selected
}

private func waitForWindow(
    bundleIdentifier: String,
    processIdentifier: pid_t,
    timeout: Duration
) async throws -> StageCaptureWindow {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        do {
            return try await StageCaptureDiscovery.window(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
        } catch StageCaptureDiscoveryError.windowNotFound {
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    throw ValidationError("Timed out waiting for a visible window from \(bundleIdentifier).")
}
