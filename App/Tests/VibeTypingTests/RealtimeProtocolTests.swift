import Foundation
import XCTest
@testable import VibeTyping

final class RealtimeProtocolTests: XCTestCase {
    func testSessionUpdateUsesManualMode() throws {
        let text = try RealtimeProtocolCodec.sessionUpdate()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["model"] as? String, "qwen3-asr")
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm16")
        XCTAssertTrue(session["turn_detection"] is NSNull)
    }

    func testAppendEncodesPCMAsBase64() throws {
        let pcm = Data([0, 1, 2, 3])
        let text = try RealtimeProtocolCodec.appendAudio(pcm)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: object["audio"] as? String ?? ""), pcm)
    }

    func testParsesKnownEventsAndIgnoresResponseEvents() {
        XCTAssertEqual(
            RealtimeProtocolCodec.parse(#"{"type":"session.created"}"#),
            .sessionCreated
        )
        XCTAssertEqual(
            RealtimeProtocolCodec.parse(#"{"type":"session.updated"}"#),
            .sessionUpdated
        )
        XCTAssertEqual(
            RealtimeProtocolCodec.parse(
                #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好"}"#
            ),
            .transcript("你好")
        )
        XCTAssertEqual(
            RealtimeProtocolCodec.parse(#"{"type":"realtime.keepalive"}"#),
            .keepalive
        )
        XCTAssertEqual(
            RealtimeProtocolCodec.parse(#"{"type":"response.done"}"#),
            .ignored("response.done")
        )
    }

    func testParsesServerErrorShape() {
        XCTAssertEqual(
            RealtimeProtocolCodec.parse(
                #"{"type":"error","error":{"type":"audio_too_long","message":"too long"}}"#
            ),
            .error(code: "audio_too_long", message: "too long")
        )
    }

    func testInvalidJSONIsReported() {
        XCTAssertEqual(
            RealtimeProtocolCodec.parse("not json"),
            .error(code: "invalid_response", message: "Server returned invalid JSON")
        )
    }
}
