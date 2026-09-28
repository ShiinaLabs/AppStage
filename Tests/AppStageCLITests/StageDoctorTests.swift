import Foundation
import XCTest
@testable import AppStageCLI

final class StageDoctorTests: XCTestCase {
    func testExistingDirectoryIsItsOwnExistingAncestor() {
        let directory = FileManager.default.temporaryDirectory.standardizedFileURL

        XCTAssertEqual(StageDoctor.existingAncestor(for: directory), directory)
    }

    func testNonexistentNestedDirectoryResolvesToNearestExistingAncestor() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("appstage-test-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let nestedDirectory = root
            .appendingPathComponent("a/b/c", isDirectory: true)
            .standardizedFileURL

        XCTAssertEqual(StageDoctor.existingAncestor(for: nestedDirectory), root)
    }
}
