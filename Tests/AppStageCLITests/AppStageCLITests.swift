import Foundation
import XCTest
@testable import AppStageCLI

final class AppStageCLITests: XCTestCase {
    func testRootHelpListsTheThreePhaseOneCommands() throws {
        let result = try runCLI(["--help"])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("list"))
        XCTAssertTrue(result.standardOutput.contains("snapshot"))
        XCTAssertTrue(result.standardOutput.contains("record"))
    }

    func testRecordHelpIncludesTheRequiredScenarioAndOutputOptions() throws {
        let result = try runCLI(["record", "--help"])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("--app"))
        XCTAssertTrue(result.standardOutput.contains("--scenario"))
        XCTAssertTrue(result.standardOutput.contains("--output"))
        XCTAssertTrue(result.standardOutput.contains("--duration"))
    }

    func testRecordHelpExplainsKeepAppRunningAndPreexistingOwnership() throws {
        let result = try runCLI(["record", "--help"])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("--keep-app-running"))
        XCTAssertTrue(result.standardOutput.contains("Keep an application launched by AppStage running"))
        XCTAssertTrue(result.standardOutput.contains("Pre-existing applications are"))
        XCTAssertTrue(result.standardOutput.contains("never terminated."))
    }

    func testRecordHelpExplainsControlledCompletionAndReplacement() throws {
        let result = try runCLI(["record", "--help"])
        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("--timeout"))
        XCTAssertTrue(result.standardOutput.contains("--replace-existing"))
        XCTAssertTrue(result.standardOutput.contains("--duration"))
        XCTAssertTrue(result.standardOutput.contains("finished"))
    }

    func testRecordParsesTimeoutReplacementAndLegacyDuration() throws {
        let command = try RecordCommand.parse([
            "--app", "/Applications/Example.app",
            "--scenario", "example",
            "--output", "/tmp/example.mov",
            "--timeout", "42",
            "--duration", "12",
            "--replace-existing",
        ])
        XCTAssertEqual(command.timeout, 42)
        XCTAssertEqual(command.duration, 12)
        XCTAssertTrue(command.replaceExisting)
    }

    func testSnapshotHelpIncludesBundleIdentifierAndOutputOptions() throws {
        let result = try runCLI(["snapshot", "--help"])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("--bundle-id"))
        XCTAssertTrue(result.standardOutput.contains("--output"))
    }

    func testRecordRejectsMissingRequiredArguments() throws {
        let result = try runCLI(["record"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("--app"))
    }

    func testRecordRejectsBundleIdentifierThatDoesNotMatchTheApp() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info = contentsURL.appending(path: "Info.plist")
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: info)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let result = try runCLI([
            "record",
            "--app", bundleURL.path,
            "--bundle-id", "com.example.other",
            "--scenario", "fixture",
            "--output", FileManager.default.temporaryDirectory.appending(path: "fixture.mov").path,
        ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("must match the app bundle identifier"))
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, standardOutput: String, standardError: String) {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executableURL = packageRoot.appending(path: ".build/debug/appstage")
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
