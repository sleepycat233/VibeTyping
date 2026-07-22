import Foundation
import OnnxRuntimeBindings

public struct SmartTurnResult: Equatable, Sendable {
    public let probability: Float
    public let isComplete: Bool
    public let inferenceMilliseconds: Double

    public init(probability: Float, isComplete: Bool, inferenceMilliseconds: Double) {
        self.probability = probability
        self.isComplete = isComplete
        self.inferenceMilliseconds = inferenceMilliseconds
    }
}

public protocol SmartTurnAnalyzing: Sendable {
    func analyze(samples: [Float], sampleRate: Int) async throws -> SmartTurnResult
}

public actor SmartTurnAnalyzer: SmartTurnAnalyzing {
    public static let modelName = "smart-turn-v3.2-cpu"

    private let environment: ORTEnv
    private let session: ORTSession

    public init(modelURL: URL) throws {
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
    }

    public static func loadBundled() throws -> SmartTurnAnalyzer {
        guard let modelURL = Bundle.module.url(
            forResource: "smart-turn-v3.2-cpu",
            withExtension: "onnx"
        ) else {
            throw SmartTurnError.modelMissing
        }
        return try SmartTurnAnalyzer(modelURL: modelURL)
    }

    public func analyze(samples: [Float], sampleRate: Int) throws -> SmartTurnResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let features = WhisperLogMel.features(samples: samples, sampleRate: sampleRate)
        guard features.count == WhisperLogMel.melCount * WhisperLogMel.frameCount else {
            throw SmartTurnError.invalidFeatures(features.count)
        }
        let data = features.withUnsafeBytes { bytes in
            NSMutableData(bytes: bytes.baseAddress!, length: bytes.count)
        }
        let input = try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: [
                NSNumber(value: 1),
                NSNumber(value: WhisperLogMel.melCount),
                NSNumber(value: WhisperLogMel.frameCount),
            ]
        )
        let outputs = try session.run(
            withInputs: ["input_features": input],
            outputNames: ["logits"],
            runOptions: nil
        )
        guard let output = outputs["logits"] else { throw SmartTurnError.outputMissing }
        let outputData = try output.tensorData()
        guard outputData.length >= MemoryLayout<Float>.size else {
            throw SmartTurnError.outputMissing
        }
        var probability: Float = 0
        memcpy(&probability, outputData.bytes, MemoryLayout<Float>.size)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return SmartTurnResult(
            probability: probability,
            isComplete: probability > 0.5,
            inferenceMilliseconds: elapsed
        )
    }
}

public enum SmartTurnError: Error, Equatable {
    case modelMissing
    case invalidFeatures(Int)
    case outputMissing
}
