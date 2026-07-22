import Foundation

public enum RemoteASRError: Error, Equatable {
    case busy
    case inference(String)
}

public protocol ASRTranscribing: Sendable {
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String
}

public struct RealtimeProtocolConfiguration: Sendable {
    public static let protocolVersion = 1
    public static let modelName = "qwen3-asr"

    public let inputSampleRate: Int
    public let maxDurationSeconds: Int
    public let smartTurnSilenceTimeoutSeconds: Double

    public init(
        inputSampleRate: Int = 24_000,
        maxDurationSeconds: Int = 30,
        smartTurnSilenceTimeoutSeconds: Double = 3
    ) {
        self.inputSampleRate = inputSampleRate
        self.maxDurationSeconds = maxDurationSeconds
        self.smartTurnSilenceTimeoutSeconds = smartTurnSilenceTimeoutSeconds
    }

    public var maxAudioBytes: Int {
        inputSampleRate * MemoryLayout<Int16>.size * maxDurationSeconds
    }
}

public struct OutboundEvent: Sendable {
    public let type: String
    public let json: String

    init(type: String, payload: [String: Any]) {
        self.type = type
        self.json = Self.formatJSON(payload)
    }

    static func formatJSON(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public final class RealtimeSessionEngine: @unchecked Sendable {
    private let transcriber: any ASRTranscribing
    private let configuration: RealtimeProtocolConfiguration
    private let turnDetector: (any StreamingTurnDetecting)?
    private let smartTurnAnalyzer: (any SmartTurnAnalyzing)?
    private let sessionId = UUID().uuidString
    private var inputAudio = Data()
    private var turnDetectionMode = TurnDetectionMode.manual
    private var turnInProgress = false
    private var speechActive = false
    private var smartTurnPendingSilenceSeconds: Double?
    private var inputAudioStartSeconds: Double = 0

    public init(
        transcriber: any ASRTranscribing,
        configuration: RealtimeProtocolConfiguration = .init(),
        turnDetector: (any StreamingTurnDetecting)? = nil,
        smartTurnAnalyzer: (any SmartTurnAnalyzing)? = nil
    ) {
        self.transcriber = transcriber
        self.configuration = configuration
        self.turnDetector = turnDetector
        self.smartTurnAnalyzer = smartTurnAnalyzer
    }

    public func createdEvent() -> OutboundEvent {
        sessionEvent(type: "session.created")
    }

    public func handle(text: String) async -> [OutboundEvent] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return [errorEvent(code: "invalid_request_error", message: "Invalid message format")]
        }

        switch type {
        case "session.update":
            return await handleSessionUpdate(json)
        case "input_audio_buffer.clear":
            inputAudio.removeAll(keepingCapacity: true)
            turnInProgress = false
            speechActive = false
            smartTurnPendingSilenceSeconds = nil
            inputAudioStartSeconds = 0
            await turnDetector?.reset(sessionID: sessionId)
            return [event(type: "input_audio_buffer.cleared")]
        case "input_audio_buffer.append":
            return await handleAppend(json)
        case "input_audio_buffer.commit":
            return await handleCommit()
        default:
            return [errorEvent(
                code: "invalid_request_error",
                message: "Unknown event type: \(type)"
            )]
        }
    }

    public func discardAudio() async {
        inputAudio.removeAll()
        smartTurnPendingSilenceSeconds = nil
        inputAudioStartSeconds = 0
        await turnDetector?.release(sessionID: sessionId)
    }

    private func handleSessionUpdate(_ json: [String: Any]) async -> [OutboundEvent] {
        let session = json["session"] as? [String: Any]
        let requestedModel = ((session?["input_audio_transcription"] as? [String: Any])?["model"] as? String)
            ?? (session?["model"] as? String)
            ?? RealtimeProtocolConfiguration.modelName
        let aliases = ["qwen3-asr", "qwen3", "qwen3-asr-0.6b-mlx-4bit"]
        guard aliases.contains(requestedModel.lowercased()) else {
            return [errorEvent(
                code: "unsupported_model",
                message: "Only qwen3-asr is available"
            )]
        }
        let requestedTurnMode = parseTurnDetectionMode(session?["turn_detection"])
        if requestedTurnMode == .serverVADSmartTurn && smartTurnAnalyzer == nil {
            return [errorEvent(
                code: "unsupported_turn_detection",
                message: "Smart Turn is unavailable"
            )]
        }
        if requestedTurnMode != turnDetectionMode {
            if requestedTurnMode == .manual {
                await turnDetector?.release(sessionID: sessionId)
            } else {
                guard let turnDetector else {
                    return [errorEvent(
                        code: "unsupported_turn_detection",
                        message: "Server-side turn detection is unavailable"
                    )]
                }
                guard await turnDetector.acquire(sessionID: sessionId) else {
                    return [errorEvent(
                        code: "server_busy",
                        message: "Server-side turn detection is used by another connection"
                    )]
                }
            }
            inputAudio.removeAll(keepingCapacity: true)
            turnInProgress = false
            speechActive = false
            smartTurnPendingSilenceSeconds = nil
            inputAudioStartSeconds = 0
            turnDetectionMode = requestedTurnMode
        }
        return [sessionEvent(type: "session.updated")]
    }

    private func handleAppend(_ json: [String: Any]) async -> [OutboundEvent] {
        guard let encoded = json["audio"] as? String,
              let audio = Data(base64Encoded: encoded),
              !audio.isEmpty,
              audio.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            return [errorEvent(code: "invalid_audio", message: "Missing or invalid PCM16 audio")]
        }
        guard turnDetectionMode != .manual || inputAudio.count + audio.count <= configuration.maxAudioBytes else {
            inputAudio.removeAll()
            return [errorEvent(
                code: "audio_too_long",
                message: "Audio exceeds \(configuration.maxDurationSeconds) seconds"
            )]
        }
        inputAudio.append(audio)
        guard turnDetectionMode != .manual, let turnDetector else { return [] }

        if !turnInProgress {
            let prefixBytes = configuration.inputSampleRate * MemoryLayout<Int16>.size / 2
            if inputAudio.count > prefixBytes {
                let droppedBytes = inputAudio.count - prefixBytes
                inputAudioStartSeconds += Double(droppedBytes)
                    / Double(configuration.inputSampleRate * MemoryLayout<Int16>.size)
                inputAudio = Data(inputAudio.suffix(prefixBytes))
            }
        }
        guard inputAudio.count <= configuration.maxAudioBytes else {
            inputAudio.removeAll()
            turnInProgress = false
            speechActive = false
            await turnDetector.reset(sessionID: sessionId)
            return [errorEvent(
                code: "audio_too_long",
                message: "Audio exceeds \(configuration.maxDurationSeconds) seconds"
            )]
        }

        do {
            let samples = pcm16LEToFloat(audio)
            let signals = try await turnDetector.process(
                sessionID: sessionId,
                samples: samples,
                sampleRate: configuration.inputSampleRate
            )
            var events = [OutboundEvent]()
            for signal in signals {
                switch signal {
                case .speechStarted(let time):
                    speechActive = true
                    turnInProgress = true
                    smartTurnPendingSilenceSeconds = nil
                    events.append(OutboundEvent(type: "input_audio_buffer.speech_started", payload: [
                        "type": "input_audio_buffer.speech_started",
                        "audio_start_ms": Int((time * 1000).rounded()),
                    ]))
                case .speechEnded(_, let endTime):
                    speechActive = false
                    events.append(OutboundEvent(type: "input_audio_buffer.speech_stopped", payload: [
                        "type": "input_audio_buffer.speech_stopped",
                        "audio_end_ms": Int((endTime * 1000).rounded()),
                    ]))
                    if turnDetectionMode == .serverVAD {
                        events.append(contentsOf: await handleCommit())
                    } else if turnDetectionMode == .serverVADSmartTurn,
                              let smartTurnAnalyzer
                    {
                        let result = try await smartTurnAnalyzer.analyze(
                            samples: smartTurnSamples(endingAt: endTime),
                            sampleRate: configuration.inputSampleRate
                        )
                        events.append(smartTurnResultEvent(result, reason: "model"))
                        if result.isComplete {
                            events.append(contentsOf: await handleCommit())
                        } else {
                            smartTurnPendingSilenceSeconds = 0
                        }
                    }
                }
            }

            if turnDetectionMode == .serverVADSmartTurn,
               let pending = smartTurnPendingSilenceSeconds,
               !speechActive
            {
                let chunkSeconds = Double(audio.count)
                    / Double(configuration.inputSampleRate * MemoryLayout<Int16>.size)
                let updated = pending + chunkSeconds
                smartTurnPendingSilenceSeconds = updated
                if updated >= configuration.smartTurnSilenceTimeoutSeconds {
                    events.append(OutboundEvent(type: "turn_detection.result", payload: [
                        "type": "turn_detection.result",
                        "mode": TurnDetectionMode.serverVADSmartTurn.rawValue,
                        "complete": true,
                        "reason": "silence_timeout",
                        "silence_seconds": updated,
                    ]))
                    events.append(contentsOf: await handleCommit())
                }
            }
            return events
        } catch {
            return [errorEvent(code: "turn_detection_error", message: String(describing: error))]
        }
    }

    private func handleCommit() async -> [OutboundEvent] {
        guard !inputAudio.isEmpty else {
            return [errorEvent(code: "invalid_request_error", message: "Audio buffer is empty")]
        }

        let audio = inputAudio
        inputAudio.removeAll()
        turnInProgress = false
        speechActive = false
        smartTurnPendingSilenceSeconds = nil
        inputAudioStartSeconds = 0
        await turnDetector?.reset(sessionID: sessionId)
        let itemId = UUID().uuidString
        var events = [OutboundEvent(type: "input_audio_buffer.committed", payload: [
            "type": "input_audio_buffer.committed",
            "item_id": itemId,
        ])]

        do {
            let samples24k = pcm16LEToFloat(audio)
            let text = try await transcriber.transcribe(
                samples: samples24k,
                sampleRate: configuration.inputSampleRate
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let responseId = UUID().uuidString
            events.append(OutboundEvent(
                type: "conversation.item.input_audio_transcription.completed",
                payload: [
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": itemId,
                    "transcript": text,
                ]
            ))
            events.append(OutboundEvent(type: "response.created", payload: [
                "type": "response.created",
                "response": ["id": responseId, "status": "in_progress"],
            ]))
            events.append(OutboundEvent(type: "response.audio_transcript.delta", payload: [
                "type": "response.audio_transcript.delta",
                "response_id": responseId,
                "delta": text,
            ]))
            events.append(OutboundEvent(type: "response.audio_transcript.done", payload: [
                "type": "response.audio_transcript.done",
                "response_id": responseId,
                "transcript": text,
            ]))
            events.append(OutboundEvent(type: "response.done", payload: [
                "type": "response.done",
                "response": ["id": responseId, "status": "completed"],
            ]))
            return events
        } catch RemoteASRError.busy {
            return events + [errorEvent(code: "server_busy", message: "ASR is processing another request")]
        } catch {
            return events + [errorEvent(code: "inference_error", message: String(describing: error))]
        }
    }

    private func sessionEvent(type: String) -> OutboundEvent {
        OutboundEvent(type: type, payload: [
            "type": type,
            "session": [
                "id": sessionId,
                "protocol_version": RealtimeProtocolConfiguration.protocolVersion,
                "model": RealtimeProtocolConfiguration.modelName,
                "asr_engine": RealtimeProtocolConfiguration.modelName,
                "asr_model": "qwen3-asr-0.6b-mlx-4bit",
                "input_audio_format": "pcm16",
                "input_sample_rate": configuration.inputSampleRate,
                "max_duration_seconds": configuration.maxDurationSeconds,
                "turn_detection": turnDetectionMode.rawValue,
                "turn_detection_modes": [
                    TurnDetectionMode.manual.rawValue,
                    TurnDetectionMode.serverVAD.rawValue,
                    TurnDetectionMode.serverVADSmartTurn.rawValue,
                ],
                "modalities": ["text"],
            ] as [String: Any],
        ])
    }

    private func parseTurnDetectionMode(_ value: Any?) -> TurnDetectionMode {
        guard let value else { return turnDetectionMode }
        if value is NSNull { return .manual }
        if let name = value as? String, let mode = TurnDetectionMode(rawValue: name) {
            return mode
        }
        if let object = value as? [String: Any],
           let name = object["type"] as? String,
           let mode = TurnDetectionMode(rawValue: name)
        {
            return mode
        }
        return turnDetectionMode
    }

    private func event(type: String) -> OutboundEvent {
        OutboundEvent(type: type, payload: ["type": type])
    }

    private func smartTurnResultEvent(_ result: SmartTurnResult, reason: String) -> OutboundEvent {
        OutboundEvent(type: "turn_detection.result", payload: [
            "type": "turn_detection.result",
            "mode": TurnDetectionMode.serverVADSmartTurn.rawValue,
            "complete": result.isComplete,
            "probability": result.probability,
            "inference_ms": result.inferenceMilliseconds,
            "reason": reason,
        ])
    }

    private func smartTurnSamples(endingAt detectorTime: Float) -> [Float] {
        let relativeEnd = max(0, Double(detectorTime) - inputAudioStartSeconds)
        let requestedBytes = Int(
            relativeEnd * Double(configuration.inputSampleRate * MemoryLayout<Int16>.size)
        )
        let evenBytes = min(inputAudio.count, requestedBytes) & ~1
        guard evenBytes > 0 else { return pcm16LEToFloat(inputAudio) }
        return pcm16LEToFloat(Data(inputAudio.prefix(evenBytes)))
    }

    private func errorEvent(code: String, message: String) -> OutboundEvent {
        OutboundEvent(type: "error", payload: [
            "type": "error",
            "error": [
                "type": code,
                "message": message,
            ],
        ])
    }
}

public func pcm16LEToFloat(_ data: Data) -> [Float] {
    let count = data.count / MemoryLayout<Int16>.size
    var samples = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
        let values = raw.bindMemory(to: Int16.self)
        for index in 0..<count {
            samples[index] = Float(Int16(littleEndian: values[index])) / 32_768
        }
    }
    return samples
}

public func validBearerAuthorization(_ header: String?, token: String) -> Bool {
    guard let header, header.hasPrefix("Bearer ") else { return false }
    let supplied = String(header.dropFirst("Bearer ".count))
    let lhs = Array(supplied.utf8)
    let rhs = Array(token.utf8)
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
        difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
}
