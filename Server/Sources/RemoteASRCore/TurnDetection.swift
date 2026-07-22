import AudioCommon
import Foundation
import SpeechVAD

public enum TurnDetectionMode: String, Codable, Sendable {
    case manual
    case serverVAD = "server_vad"
    case serverVADSmartTurn = "server_vad_smart_turn"
}

public enum TurnDetectionSignal: Equatable, Sendable {
    case speechStarted(time: Float)
    case speechEnded(startTime: Float, endTime: Float)
}

public protocol StreamingTurnDetecting: Sendable {
    func acquire(sessionID: String) async -> Bool
    func process(sessionID: String, samples: [Float], sampleRate: Int) async throws -> [TurnDetectionSignal]
    func reset(sessionID: String) async
    func release(sessionID: String) async
}

public actor SileroVADCoordinator: StreamingTurnDetecting {
    public static let modelID = SileroVADModel.defaultCoreMLModelId

    private let model: SileroVADModel
    private let configuration: VADConfig
    private var ownerSessionID: String?
    private var processor: StreamingVADProcessor?

    public init(model: SileroVADModel, configuration: VADConfig = .sileroDefault) {
        self.model = model
        self.configuration = configuration
    }

    public static func load(
        offlineMode: Bool = false,
        configuration: VADConfig = .sileroDefault
    ) async throws -> SileroVADCoordinator {
        let model = try await SileroVADModel.fromPretrained(
            modelId: modelID,
            engine: .coreml,
            offlineMode: offlineMode
        ) { progress, status in
            let percent = Int((progress * 100).rounded())
            FileHandle.standardError.write(Data("[vad-model] \(percent)% \(status)\n".utf8))
        }
        return SileroVADCoordinator(model: model, configuration: configuration)
    }

    public func acquire(sessionID: String) -> Bool {
        guard ownerSessionID == nil || ownerSessionID == sessionID else { return false }
        ownerSessionID = sessionID
        if processor == nil {
            processor = StreamingVADProcessor(model: model, config: configuration)
        } else {
            processor?.reset()
        }
        return true
    }

    public func process(
        sessionID: String,
        samples: [Float],
        sampleRate: Int
    ) throws -> [TurnDetectionSignal] {
        guard ownerSessionID == sessionID, let processor else {
            throw TurnDetectionError.notAcquired
        }
        let samples16k = sampleRate == SileroVADModel.sampleRate
            ? samples
            : AudioFileLoader.resample(samples, from: sampleRate, to: SileroVADModel.sampleRate)
        return processor.process(samples: samples16k).map { event in
            switch event {
            case .speechStarted(let time):
                return .speechStarted(time: time)
            case .speechEnded(let segment):
                return .speechEnded(startTime: segment.startTime, endTime: segment.endTime)
            }
        }
    }

    public func reset(sessionID: String) {
        guard ownerSessionID == sessionID else { return }
        processor?.reset()
    }

    public func release(sessionID: String) {
        guard ownerSessionID == sessionID else { return }
        processor?.reset()
        processor = nil
        ownerSessionID = nil
    }
}

public enum TurnDetectionError: Error, Equatable {
    case notAcquired
}
