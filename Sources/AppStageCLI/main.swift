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
            SnapshotCommand.self, RecordCommand.self, CaptureAllCommand.self,
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

@MainActor
private func makeBatchRoundWorkflow(
    appURL: URL,
    bundleIdentifier: String,
    captureConfiguration: StageCaptureConfiguration,
    timeout: Duration
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
        }
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
