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
        subcommands: [ListCommand.self, SnapshotCommand.self, RecordCommand.self]
    )
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

        let captureConfiguration = try StageCaptureConfiguration(
            frameRate: frameRate,
            cursor: .hidden,
            framing: .desktopAroundWindow(
                horizontalMargin: CGFloat(horizontalMargin),
                verticalMargin: CGFloat(verticalMargin)
            )
        )

        let captureTask = Task { @MainActor in
            let token = try StageControlToken.generate()
            let sessionID = UUID()
            let workflow = StageRecordWorkflow(
                controller: StageSystemRecordController(
                    underlying: StageControlController(
                        token: token, sessionID: sessionID, bundleIdentifier: applicationBundleID
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
                makeRecorder: { pid, bundleID in
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
                existingApplicationPolicy: replaceExisting ? .replace : .reject
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
