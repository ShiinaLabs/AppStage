import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct StageDoctorCheck: Codable {
    let name: String
    let passed: Bool
    let detail: String
}

struct StageDoctorReport: Codable {
    let checkedAt: Date
    let macOSVersion: String
    let architecture: String
    let xcodeVersion: String
    let swiftVersion: String
    let displayResolution: String?
    let screenScale: Double?
    let appStageRevision: String
    let hostBundleID: String?
    let checks: [StageDoctorCheck]

    var passed: Bool { checks.allSatisfy(\.passed) }
}

enum StageDoctor {
    static let minimumFreeBytes: Int64 = 10 * 1_024 * 1_024 * 1_024

    static func inspect(appURL: URL, outputURL: URL?) -> StageDoctorReport {
        var checks: [StageDoctorCheck] = []
        let version = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(.init(
            name: "macOS",
            passed: version.majorVersion >= 14,
            detail: ProcessInfo.processInfo.operatingSystemVersionString
        ))

        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let guiLoggedIn = (session?["kCGSSessionOnConsoleKey"] as? Int) == 1
            && (session?["kCGSSessionUserIDKey"] as? Int ?? 0) > 0
        checks.append(.init(
            name: "guiSession",
            passed: guiLoggedIn,
            detail: guiLoggedIn ? "Console GUI user session is active" : "No active console GUI login session"
        ))

        let accessibilityTrusted = AXIsProcessTrusted()
        checks.append(.init(
            name: "accessibility",
            passed: accessibilityTrusted,
            detail: accessibilityTrusted ? "Accessibility access is granted" : "Grant Accessibility access to appstage"
        ))

        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        checks.append(.init(
            name: "screenRecording",
            passed: screenRecordingGranted,
            detail: screenRecordingGranted ? "Screen Recording access is granted" : "Grant Screen Recording access to appstage"
        ))

        var displayCount: UInt32 = 0
        let displayResult = CGGetActiveDisplayList(0, nil, &displayCount)
        let displaysAvailable = displayResult == .success && displayCount > 0
        let mainScreen = NSScreen.main
        let resolution: String? = mainScreen.map {
            "\(Int($0.frame.width * $0.backingScaleFactor))x\(Int($0.frame.height * $0.backingScaleFactor))"
        }
        checks.append(.init(
            name: "display",
            passed: displaysAvailable && mainScreen != nil,
            detail: resolution.map { "\(displayCount) active display(s), main display \($0)" }
                ?? "No active display is available to the GUI session"
        ))

        var isDirectory: ObjCBool = false
        let appExists = FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let bundle = appExists ? Bundle(url: appURL) : nil
        let bundleID = bundle?.bundleIdentifier
        checks.append(.init(
            name: "hostApp",
            passed: appExists && bundleID?.isEmpty == false,
            detail: bundleID ?? "Target app bundle or bundle identifier is missing"
        ))

        let runningTargets = bundleID.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .filter { !$0.isTerminated }
        } ?? []
        checks.append(.init(
            name: "noResidualHostProcess",
            passed: runningTargets.isEmpty,
            detail: runningTargets.isEmpty
                ? "No target app process is running"
                : "Target app has running PID(s): \(runningTargets.map { String($0.processIdentifier) }.joined(separator: ", "))"
        ))

        let diskURL = (outputURL?.deletingLastPathComponent() ?? appURL.deletingLastPathComponent())
        let availableBytes = try? diskURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let diskEnough = (availableBytes ?? 0) >= minimumFreeBytes
        checks.append(.init(
            name: "diskSpace",
            passed: diskEnough,
            detail: availableBytes.map { "\($0) bytes available" } ?? "Could not determine available disk space"
        ))

        let architecture = commandOutput("/usr/bin/uname", arguments: ["-m"]) ?? "unknown"
        let xcodeVersion = commandOutput("/usr/bin/xcodebuild", arguments: ["-version"]) ?? "unavailable"
        let swiftVersion = commandOutput("/usr/bin/swift", arguments: ["--version"]) ?? "unavailable"
        let revision = commandOutput("/usr/bin/git", arguments: ["rev-parse", "--short", "HEAD"], directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) ?? "unknown"
        checks.append(.init(name: "xcode", passed: xcodeVersion != "unavailable", detail: xcodeVersion.trimmingCharacters(in: .whitespacesAndNewlines)))
        checks.append(.init(name: "swift", passed: swiftVersion != "unavailable", detail: swiftVersion.trimmingCharacters(in: .whitespacesAndNewlines)))

        return StageDoctorReport(
            checkedAt: Date(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture.trimmingCharacters(in: .whitespacesAndNewlines),
            xcodeVersion: xcodeVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            swiftVersion: swiftVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            displayResolution: resolution,
            screenScale: mainScreen.map { Double($0.backingScaleFactor) },
            appStageRevision: revision.trimmingCharacters(in: .whitespacesAndNewlines),
            hostBundleID: bundleID,
            checks: checks
        )
    }

    private static func commandOutput(_ path: String, arguments: [String], directory: URL? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
