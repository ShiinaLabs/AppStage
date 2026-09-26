import XCTest
import AppStage
import AppStageControl

final class StageControlCodecTests: XCTestCase {
    func testRoundTripAndChunkedFrames() throws {
        let first = StageControlMessage.request(.init(id: UUID(), command: .loadScenario(StageScenarioID("example"))))
        let second = StageControlMessage.event(.init(kind: .ready, scenarioID: StageScenarioID("example"), positionMilliseconds: 0))
        let bytes = try StageControlCodec.encode(first) + StageControlCodec.encode(second)
        var decoder = StageControlFrameDecoder()
        XCTAssertEqual(try decoder.append(Array(bytes.prefix(2))), [])
        XCTAssertEqual(try decoder.append(Array(bytes.dropFirst(2).prefix(5))), [])
        XCTAssertEqual(try decoder.append(Array(bytes.dropFirst(7))), [first, second])
    }

    func testRejectsInvalidLengthAndOversize() throws {
        var decoder = StageControlFrameDecoder()
        XCTAssertThrowsError(try decoder.append([0, 0, 0, 0]))
        decoder = StageControlFrameDecoder()
        XCTAssertThrowsError(try decoder.append([0, 16, 0, 1]))
    }

    func testRejectsMalformedJSONAndUnknownKind() throws {
        var decoder = StageControlFrameDecoder()
        XCTAssertThrowsError(try decoder.append([0, 0, 0, 1, 0x7b]))
        decoder = StageControlFrameDecoder()
        let unknown = Array("{\"unknown\":{}}".utf8)
        let prefix = [UInt8(0), 0, 0, UInt8(unknown.count)]
        XCTAssertThrowsError(try decoder.append(prefix + unknown)) {
            XCTAssertEqual($0 as? StageControlError, .unknownMessageKind)
        }
    }
}
