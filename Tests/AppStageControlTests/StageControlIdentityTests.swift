import XCTest
import AppStageControl

final class StageControlIdentityTests: XCTestCase {
    private let session = UUID()
    private let token = "secret"

    func testHandshakeChecksEveryIdentityField() throws {
        let expected = StageControlIdentity(token: token, sessionID: session, bundleIdentifier: "example.app", pid: 42)
        try expected.validate(.init(token: token, sessionID: session, bundleIdentifier: "example.app", pid: 42))
        XCTAssertThrowsError(try expected.validate(.init(version: 2, token: token, sessionID: session, bundleIdentifier: "example.app", pid: 42))) {
            XCTAssertEqual($0 as? StageControlError, .protocolVersionMismatch(expected: 1, actual: 2))
        }
        XCTAssertThrowsError(try expected.validate(.init(token: "wrong", sessionID: session, bundleIdentifier: "example.app", pid: 42))) {
            XCTAssertEqual($0 as? StageControlError, .invalidToken)
        }
        XCTAssertThrowsError(try expected.validate(.init(token: token, sessionID: UUID(), bundleIdentifier: "example.app", pid: 42))) {
            XCTAssertEqual($0 as? StageControlError, .wrongSessionID)
        }
        XCTAssertThrowsError(try expected.validate(.init(token: token, sessionID: session, bundleIdentifier: "other.app", pid: 42))) {
            XCTAssertEqual($0 as? StageControlError, .wrongBundleID)
        }
        XCTAssertThrowsError(try expected.validate(.init(token: token, sessionID: session, bundleIdentifier: "example.app", pid: 99))) {
            XCTAssertEqual($0 as? StageControlError, .wrongPID)
        }
    }

    func testSessionTokenIsAtLeast256BitsAndUnique() throws {
        let first = try StageControlToken.generate()
        let second = try StageControlToken.generate()
        XCTAssertGreaterThanOrEqual(first.utf8.count, 64)
        XCTAssertNotEqual(first, second)
    }
}
