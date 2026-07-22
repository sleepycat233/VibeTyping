import AudioCommon
import Foundation
import Qwen3ASR
import Synchronization

public final class QwenTranscriber: ASRTranscribing, @unchecked Sendable {
    public static let modelId = Qwen3ASRModel.defaultModelId

    private let model: Qwen3ASRModel
    private let busy = Mutex(false)
    private let telemetry: InferenceTelemetry

    public init(model: Qwen3ASRModel, telemetry: InferenceTelemetry = .init()) {
        self.model = model
        self.telemetry = telemetry
    }

    public static func load(
        offlineMode: Bool = false,
        telemetry: InferenceTelemetry = .init()
    ) async throws -> QwenTranscriber {
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            offlineMode: offlineMode
        ) { progress, status in
            let percent = Int((progress * 100).rounded())
            FileHandle.standardError.write(Data("[model] \(percent)% \(status)\n".utf8))
        }
        return QwenTranscriber(model: model, telemetry: telemetry)
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        let acquired = busy.withLock { isBusy in
            guard !isBusy else { return false }
            isBusy = true
            return true
        }
        guard acquired else { throw RemoteASRError.busy }

        defer {
            busy.withLock { $0 = false }
        }

        let audioDuration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        let requestId = telemetry.begin(audioDurationSeconds: audioDuration)
        let monitor = telemetry.startMonitoring(requestId: requestId)

        let resampleStarted = DispatchTime.now().uptimeNanoseconds
        let normalized = sampleRate == 16_000
            ? samples
            : AudioFileLoader.resample(samples, from: sampleRate, to: 16_000)
        let resampleSeconds = Self.elapsedSeconds(since: resampleStarted)
        let model = self.model
        let inferenceStarted = DispatchTime.now().uptimeNanoseconds
        let text = await Task.detached(priority: .userInitiated) {
            model.transcribe(audio: normalized, sampleRate: 16_000, language: nil)
        }.value
        let inferenceSeconds = Self.elapsedSeconds(since: inferenceStarted)
        monitor?.cancel()
        telemetry.finish(
            requestId: requestId,
            resampleSeconds: resampleSeconds,
            inferenceSeconds: inferenceSeconds,
            outputCharacters: text.count
        )
        return text
    }

    private static func elapsedSeconds(since started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }
}
