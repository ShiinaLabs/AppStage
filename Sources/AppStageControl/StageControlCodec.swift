import Foundation

public enum StageControlCodec {
    public static func encode(_ message: StageControlMessage) throws -> [UInt8] {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty else { throw StageControlError.invalidFrameLength }
        guard payload.count <= StageControlProtocol.maximumMessageSize else { throw StageControlError.messageTooLarge }
        let length = UInt32(payload.count)
        return [UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)] + payload
    }
}

public struct StageControlFrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [StageControlMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [StageControlMessage] = []
        while buffer.count >= 4 {
            let length = (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16) | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
            guard length > 0 else { throw StageControlError.invalidFrameLength }
            guard length <= StageControlProtocol.maximumMessageSize else { throw StageControlError.messageTooLarge }
            let frameEnd = 4 + Int(length)
            guard buffer.count >= frameEnd else { break }
            let payload = Data(buffer[4..<frameEnd])
            do {
                messages.append(try JSONDecoder().decode(StageControlMessage.self, from: payload))
            } catch {
                if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                   let kind = object.keys.first,
                   !["hello", "accepted", "rejected", "request", "response", "event", "accessibilityRequest", "accessibilityResponse"].contains(kind) {
                    throw StageControlError.unknownMessageKind
                }
                throw StageControlError.invalidJSON
            }
            buffer.removeFirst(frameEnd)
        }
        return messages
    }
}
