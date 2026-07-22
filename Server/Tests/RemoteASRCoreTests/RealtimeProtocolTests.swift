import Foundation
import Synchronization
import XCTest
@testable import RemoteASRCore

final class RealtimeProtocolTests: XCTestCase {
    func testBearerAuthorization() {
        XCTAssertTrue(validBearerAuthorization("Bearer secret", token: "secret"))
        XCTAssertFalse(validBearerAuthorization("Bearer wrong", token: "secret"))
        XCTAssertFalse(validBearerAuthorization(nil, token: "secret"))
    }

    func testSessionCreatedAdvertisesProtocol() throws {
        let session = RealtimeSessionEngine(transcriber: StubTranscriber(text: "hello"))
        let json = try decode(session.createdEvent())
        XCTAssertEqual(json["type"] as? String, "session.created")
        let body = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(body["protocol_version"] as? Int, 1)
        XCTAssertEqual(body["input_sample_rate"] as? Int, 24_000)
        XCTAssertEqual(body["max_duration_seconds"] as? Int, 30)
    }

    func testAppendCommitEmitsRealtimeSequence() async throws {
        let session = RealtimeSessionEngine(transcriber: StubTranscriber(text: "你好 world"))
        _ = await session.handle(text: json(["type": "input_audio_buffer.append", "audio": pcmData().base64EncodedString()]))
        let events = await session.handle(text: json(["type": "input_audio_buffer.commit"]))
        XCTAssertEqual(events.map(\.type), [
            "input_audio_buffer.committed",
            "conversation.item.input_audio_transcription.completed",
            "response.created",
            "response.audio_transcript.delta",
            "response.audio_transcript.done",
            "response.done",
        ])
        let completed = try decode(events[1])
        XCTAssertEqual(completed["transcript"] as? String, "你好 world")
    }

    func testClearMakesCommitFail() async {
        let session = RealtimeSessionEngine(transcriber: StubTranscriber(text: "unused"))
        _ = await session.handle(text: json(["type": "input_audio_buffer.append", "audio": pcmData().base64EncodedString()]))
        _ = await session.handle(text: json(["type": "input_audio_buffer.clear"]))
        let events = await session.handle(text: json(["type": "input_audio_buffer.commit"]))
        XCTAssertEqual(events.map(\.type), ["error"])
    }

    func testRejectsAudioBeyondLimitAndDiscardsBuffer() async throws {
        let config = RealtimeProtocolConfiguration(inputSampleRate: 10, maxDurationSeconds: 1)
        let session = RealtimeSessionEngine(transcriber: StubTranscriber(text: "unused"), configuration: config)
        let oversized = Data(repeating: 1, count: 22)
        let events = await session.handle(text: json([
            "type": "input_audio_buffer.append",
            "audio": oversized.base64EncodedString(),
        ]))
        XCTAssertEqual(try errorCode(events[0]), "audio_too_long")
        let commit = await session.handle(text: json(["type": "input_audio_buffer.commit"]))
        XCTAssertEqual(try errorCode(commit[0]), "invalid_request_error")
    }

    func testMapsBusyError() async throws {
        let session = RealtimeSessionEngine(transcriber: BusyTranscriber())
        _ = await session.handle(text: json(["type": "input_audio_buffer.append", "audio": pcmData().base64EncodedString()]))
        let events = await session.handle(text: json(["type": "input_audio_buffer.commit"]))
        XCTAssertEqual(events.first?.type, "input_audio_buffer.committed")
        XCTAssertEqual(try errorCode(events.last!), "server_busy")
    }

    func testRejectsUnsupportedModel() async throws {
        let session = RealtimeSessionEngine(transcriber: StubTranscriber(text: "unused"))
        let events = await session.handle(text: json([
            "type": "session.update",
            "session": ["input_audio_transcription": ["model": "nemotron"]],
        ]))
        XCTAssertEqual(try errorCode(events[0]), "unsupported_model")
    }

    func testServerVADAutomaticallyCommitsAtSpeechEnd() async throws {
        let detector = StubTurnDetector(signals: [
            .speechStarted(time: 0.1),
            .speechEnded(startTime: 0.1, endTime: 0.8),
        ])
        let session = RealtimeSessionEngine(
            transcriber: StubTranscriber(text: "automatic"),
            turnDetector: detector
        )
        let update = await session.handle(text: json([
            "type": "session.update",
            "session": ["turn_detection": ["type": "server_vad"]],
        ]))
        XCTAssertEqual(update.map(\.type), ["session.updated"])

        let events = await session.handle(text: json([
            "type": "input_audio_buffer.append",
            "audio": pcmData().base64EncodedString(),
        ]))
        XCTAssertEqual(events.map(\.type), [
            "input_audio_buffer.speech_started",
            "input_audio_buffer.speech_stopped",
            "input_audio_buffer.committed",
            "conversation.item.input_audio_transcription.completed",
            "response.created",
            "response.audio_transcript.delta",
            "response.audio_transcript.done",
            "response.done",
        ])
        let resetCount = await detector.resetCount
        XCTAssertEqual(resetCount, 1)
    }

    func testTurnDetectorBusyIsReported() async throws {
        let detector = StubTurnDetector(signals: [], acquireResult: false)
        let session = RealtimeSessionEngine(
            transcriber: StubTranscriber(text: "unused"),
            turnDetector: detector
        )
        let events = await session.handle(text: json([
            "type": "session.update",
            "session": ["turn_detection": ["type": "server_vad"]],
        ]))
        XCTAssertEqual(try errorCode(events[0]), "server_busy")
    }

    func testSmartTurnCompleteCommitsAndPublishesProbability() async throws {
        let detector = StubTurnDetector(signals: [
            .speechStarted(time: 0),
            .speechEnded(startTime: 0, endTime: 0.7),
        ])
        let analyzer = StubSmartTurnAnalyzer(result: SmartTurnResult(
            probability: 0.98,
            isComplete: true,
            inferenceMilliseconds: 35
        ))
        let session = RealtimeSessionEngine(
            transcriber: StubTranscriber(text: "complete"),
            turnDetector: detector,
            smartTurnAnalyzer: analyzer
        )
        _ = await session.handle(text: json([
            "type": "session.update",
            "session": ["turn_detection": ["type": "server_vad_smart_turn"]],
        ]))
        let events = await session.handle(text: json([
            "type": "input_audio_buffer.append",
            "audio": pcmData().base64EncodedString(),
        ]))
        XCTAssertEqual(events.map(\.type), [
            "input_audio_buffer.speech_started",
            "input_audio_buffer.speech_stopped",
            "turn_detection.result",
            "input_audio_buffer.committed",
            "conversation.item.input_audio_transcription.completed",
            "response.created",
            "response.audio_transcript.delta",
            "response.audio_transcript.done",
            "response.done",
        ])
        let turn = try decode(events[2])
        XCTAssertEqual(turn["complete"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(turn["probability"] as? Double), 0.98, accuracy: 0.001)
    }

    func testSmartTurnIncompleteWaitsForMoreSpeech() async throws {
        let detector = StubTurnDetector(signals: [
            .speechStarted(time: 0),
            .speechEnded(startTime: 0, endTime: 0.7),
        ])
        let analyzer = StubSmartTurnAnalyzer(result: SmartTurnResult(
            probability: 0.05,
            isComplete: false,
            inferenceMilliseconds: 34
        ))
        let session = RealtimeSessionEngine(
            transcriber: StubTranscriber(text: "unused"),
            turnDetector: detector,
            smartTurnAnalyzer: analyzer
        )
        _ = await session.handle(text: json([
            "type": "session.update",
            "session": ["turn_detection": ["type": "server_vad_smart_turn"]],
        ]))
        let events = await session.handle(text: json([
            "type": "input_audio_buffer.append",
            "audio": pcmData().base64EncodedString(),
        ]))
        XCTAssertEqual(events.map(\.type), [
            "input_audio_buffer.speech_started",
            "input_audio_buffer.speech_stopped",
            "turn_detection.result",
        ])
        let turn = try decode(events[2])
        XCTAssertEqual(turn["complete"] as? Bool, false)
    }

    func testSmartTurnSilenceTimeoutForcesCommit() async throws {
        let detector = StubTurnDetector(signalBatches: [[
            .speechStarted(time: 0),
            .speechEnded(startTime: 0, endTime: 0.2),
        ]])
        let analyzer = StubSmartTurnAnalyzer(result: SmartTurnResult(
            probability: 0.05,
            isComplete: false,
            inferenceMilliseconds: 34
        ))
        let session = RealtimeSessionEngine(
            transcriber: StubTranscriber(text: "forced"),
            configuration: RealtimeProtocolConfiguration(
                inputSampleRate: 10,
                maxDurationSeconds: 30,
                smartTurnSilenceTimeoutSeconds: 0.1
            ),
            turnDetector: detector,
            smartTurnAnalyzer: analyzer
        )
        _ = await session.handle(text: json([
            "type": "session.update",
            "session": ["turn_detection": ["type": "server_vad_smart_turn"]],
        ]))
        let events = await session.handle(text: json([
            "type": "input_audio_buffer.append",
            "audio": pcmData().base64EncodedString(),
        ]))
        XCTAssertEqual(events.map(\.type), [
            "input_audio_buffer.speech_started",
            "input_audio_buffer.speech_stopped",
            "turn_detection.result",
            "turn_detection.result",
            "input_audio_buffer.committed",
            "conversation.item.input_audio_transcription.completed",
            "response.created",
            "response.audio_transcript.delta",
            "response.audio_transcript.done",
            "response.done",
        ])
        let timeout = try decode(events[3])
        XCTAssertEqual(timeout["reason"] as? String, "silence_timeout")
    }

    func testTelemetryRecordsCompletedInference() throws {
        let samples = Mutex([
            InferenceMemoryMetrics(
                mlxActiveBytes: 100,
                mlxCacheBytes: 20,
                mlxPeakBytes: 120,
                processResidentBytes: 200
            ),
            InferenceMemoryMetrics(
                mlxActiveBytes: 150,
                mlxCacheBytes: 40,
                mlxPeakBytes: 180,
                processResidentBytes: 260
            ),
        ])
        let telemetry = InferenceTelemetry(enabled: false) {
            samples.withLock { values in
                values.count > 1 ? values.removeFirst() : values[0]
            }
        }
        let requestId = telemetry.begin(audioDurationSeconds: 2)
        telemetry.finish(
            requestId: requestId,
            resampleSeconds: 0.1,
            inferenceSeconds: 0.5,
            outputCharacters: 10
        )

        let status = telemetry.statusSnapshot()
        XCTAssertEqual(status.status, "idle")
        let latest = try XCTUnwrap(status.latest)
        XCTAssertEqual(latest.requestId, requestId)
        XCTAssertEqual(latest.audioDurationSeconds, 2)
        XCTAssertEqual(latest.outputCharacters, 10)
        XCTAssertEqual(latest.charactersPerSecond, 20, accuracy: 0.001)
        XCTAssertEqual(latest.maxObservedMemory.mlxActiveBytes, 150)
        XCTAssertEqual(latest.maxObservedMemory.processResidentBytes, 260)
    }

    func testBenchmarkScoringUsesChineseCERAndEnglishWER() {
        let chinese = BenchmarkScoring.score(
            reference: "你好，世界！",
            hypothesis: "你好世界",
            language: "zh"
        )
        XCTAssertEqual(chinese.metric, "CER")
        XCTAssertEqual(chinese.normalizedReference, "你好世界")
        XCTAssertEqual(chinese.breakdown.errorRate, 0)

        let english = BenchmarkScoring.score(
            reference: "Hello, local ASR!",
            hypothesis: "hello local",
            language: "en"
        )
        XCTAssertEqual(english.metric, "WER")
        XCTAssertEqual(english.breakdown.deletions, 1)
        XCTAssertEqual(english.breakdown.errorRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    private func pcmData() -> Data {
        let values: [Int16] = [0, 1_000, -1_000]
        return values.withUnsafeBytes { Data($0) }
    }

    private func json(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8)!
    }

    private func decode(_ event: OutboundEvent) throws -> [String: Any] {
        let data = try XCTUnwrap(event.json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ event: OutboundEvent) throws -> String? {
        let payload = try decode(event)
        return (payload["error"] as? [String: Any])?["type"] as? String
    }
}

private struct StubTranscriber: ASRTranscribing {
    let text: String

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        text
    }
}

private struct BusyTranscriber: ASRTranscribing {
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        throw RemoteASRError.busy
    }
}

private actor StubTurnDetector: StreamingTurnDetecting {
    var signalBatches: [[TurnDetectionSignal]]
    let acquireResult: Bool
    var resetCount = 0

    init(signals: [TurnDetectionSignal], acquireResult: Bool = true) {
        self.signalBatches = [signals]
        self.acquireResult = acquireResult
    }

    init(signalBatches: [[TurnDetectionSignal]], acquireResult: Bool = true) {
        self.signalBatches = signalBatches
        self.acquireResult = acquireResult
    }

    func acquire(sessionID: String) -> Bool { acquireResult }

    func process(
        sessionID: String,
        samples: [Float],
        sampleRate: Int
    ) -> [TurnDetectionSignal] {
        signalBatches.isEmpty ? [] : signalBatches.removeFirst()
    }

    func reset(sessionID: String) { resetCount += 1 }
    func release(sessionID: String) {}
}

private actor StubSmartTurnAnalyzer: SmartTurnAnalyzing {
    let result: SmartTurnResult
    init(result: SmartTurnResult) { self.result = result }
    func analyze(samples: [Float], sampleRate: Int) -> SmartTurnResult { result }
}
