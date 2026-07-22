import Foundation

enum RealtimeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready
}

enum RealtimeEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case audioCleared
    case audioCommitted(itemID: String?)
    case transcript(String)
    case keepalive
    case error(code: String, message: String)
    case ignored(String)
}

enum RealtimeProtocolCodec {
    static func sessionUpdate() throws -> String {
        try encode([
            "type": "session.update",
            "session": [
                "model": "qwen3-asr",
                "input_audio_format": "pcm16",
                "input_audio_transcription": ["model": "qwen3-asr"],
                "turn_detection": NSNull(),
            ] as [String: Any],
        ])
    }

    static func clearAudio() throws -> String {
        try encode(["type": "input_audio_buffer.clear"])
    }

    static func appendAudio(_ pcm16: Data) throws -> String {
        try encode([
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ])
    }

    static func commitAudio() throws -> String {
        try encode(["type": "input_audio_buffer.commit"])
    }

    static func parse(_ text: String) -> RealtimeEvent {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return .error(code: "invalid_response", message: "Server returned invalid JSON")
        }

        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.cleared":
            return .audioCleared
        case "input_audio_buffer.committed":
            return .audioCommitted(itemID: object["item_id"] as? String)
        case "conversation.item.input_audio_transcription.completed":
            return .transcript(object["transcript"] as? String ?? "")
        case "realtime.keepalive":
            return .keepalive
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(
                code: error?["type"] as? String ?? "server_error",
                message: error?["message"] as? String ?? "Unknown server error"
            )
        default:
            return .ignored(type)
        }
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeClientError.invalidEncoding
        }
        return text
    }
}

enum RealtimeClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidEncoding
    case disconnected
    case unauthorized
    case sendQueueOverflow
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: "Could not encode realtime message."
        case .disconnected: "Realtime connection is not ready."
        case .unauthorized: "The local server rejected the bearer token."
        case .sendQueueOverflow: "The realtime connection is too slow; audio was not submitted."
        case .transport(let message): message
        }
    }
}
