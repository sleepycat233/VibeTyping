import AudioCommon
import Foundation
import RemoteASRCore

@main
struct RemoteASRTurnBenchmarkCommand {
    static func main() async throws {
        let options = try Options.parse(CommandLine.arguments)
        if options.showHelp {
            print(Options.help)
            return
        }

        let audioDirectory = URL(fileURLWithPath: options.audioDirectory).standardizedFileURL
        print("Loading \(SileroVADCoordinator.modelID)...")
        let vad = try await SileroVADCoordinator.load(offlineMode: options.offline)
        print("Loading \(SmartTurnAnalyzer.modelName)...")
        let smartTurn = try SmartTurnAnalyzer.loadBundled()
        let warmup = try await smartTurn.analyze(samples: [], sampleRate: WhisperLogMel.sampleRate)
        print(String(format: "Smart Turn warmup: %.1fms", warmup.inferenceMilliseconds))

        var results = [TurnBenchmarkItem]()
        for sample in samples {
            let url = audioDirectory.appendingPathComponent(sample.file)
            let audio = try AudioFileLoader.loadWAV(url: url)
            let sessionID = UUID().uuidString
            guard await vad.acquire(sessionID: sessionID) else {
                throw TurnBenchmarkError.invalid("Could not acquire VAD")
            }
            let vadStarted = DispatchTime.now().uptimeNanoseconds
            var signals = [TurnDetectionSignal]()
            let chunkSize = max(1, audio.sampleRate * 32 / 1_000)
            let withSilence = audio.samples + [Float](repeating: 0, count: audio.sampleRate / 2)
            var offset = 0
            while offset < withSilence.count {
                let end = min(offset + chunkSize, withSilence.count)
                signals.append(contentsOf: try await vad.process(
                    sessionID: sessionID,
                    samples: Array(withSilence[offset..<end]),
                    sampleRate: audio.sampleRate
                ))
                offset = end
            }
            let vadMilliseconds = elapsedMilliseconds(since: vadStarted)
            await vad.release(sessionID: sessionID)

            let turn = try await smartTurn.analyze(
                samples: audio.samples,
                sampleRate: audio.sampleRate
            )
            let speechStart = signals.compactMap { signal -> Float? in
                if case .speechStarted(let time) = signal { return time }
                return nil
            }.first
            let speechEnd = signals.compactMap { signal -> Float? in
                if case .speechEnded(_, let time) = signal { return time }
                return nil
            }.last
            let item = TurnBenchmarkItem(
                category: sample.category,
                file: sample.file,
                expectedComplete: sample.expectedComplete,
                predictedComplete: turn.isComplete,
                correct: turn.isComplete == sample.expectedComplete,
                probability: turn.probability,
                smartTurnMilliseconds: turn.inferenceMilliseconds,
                audioDurationSeconds: Double(audio.samples.count) / Double(audio.sampleRate),
                vadSpeechStarted: speechStart != nil,
                vadSpeechStopped: speechEnd != nil,
                vadSpeechStartSeconds: speechStart.map(Double.init),
                vadSpeechEndSeconds: speechEnd.map(Double.init),
                vadProcessingMilliseconds: vadMilliseconds
            )
            results.append(item)
            print(String(
                format: "%-24@ expected=%@ predicted=%@ p=%.3f smart=%.1fms vad=%.1fms",
                sample.file as NSString,
                sample.expectedComplete ? "COMPLETE" : "INCOMPLETE",
                turn.isComplete ? "COMPLETE" : "INCOMPLETE",
                turn.probability,
                turn.inferenceMilliseconds,
                vadMilliseconds
            ))
        }

        let report = TurnBenchmarkReport(
            schemaVersion: 1,
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            vadModel: SileroVADCoordinator.modelID,
            smartTurnModel: SmartTurnAnalyzer.modelName,
            warmupMilliseconds: warmup.inferenceMilliseconds,
            threshold: 0.5,
            itemCount: results.count,
            correctCount: results.filter(\.correct).count,
            accuracy: Double(results.filter(\.correct).count) / Double(results.count),
            vadSpeechDetectionRate: Double(results.filter(\.vadSpeechStarted).count) / Double(results.count),
            vadStopDetectionRate: Double(results.filter(\.vadSpeechStopped).count) / Double(results.count),
            meanSmartTurnMilliseconds: mean(results.map(\.smartTurnMilliseconds)),
            meanVADProcessingMilliseconds: mean(results.map(\.vadProcessingMilliseconds)),
            categorySummaries: Dictionary(grouping: results, by: \TurnBenchmarkItem.category)
                .map { category, items in
                    TurnCategorySummary(
                        category: category,
                        itemCount: items.count,
                        correctCount: items.filter(\.correct).count,
                        accuracy: Double(items.filter(\.correct).count) / Double(items.count),
                        meanProbability: mean(items.map { Double($0.probability) })
                    )
                }
                .sorted { $0.category < $1.category },
            items: results
        )

        let output = URL(fileURLWithPath: options.output).standardizedFileURL
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
        print(String(
            format: "accuracy=%.1f%% vad_start=%.1f%% vad_stop=%.1f%% smart_mean=%.1fms",
            report.accuracy * 100,
            report.vadSpeechDetectionRate * 100,
            report.vadStopDetectionRate * 100,
            report.meanSmartTurnMilliseconds
        ))
        print("Wrote \(output.path)")
    }
}

private struct Sample {
    let category: String
    let file: String
    let expectedComplete: Bool
}

private let samples = [
    Sample(category: "complete", file: "test_input.wav", expectedComplete: true),
    Sample(category: "complete", file: "full_game.wav", expectedComplete: true),
    Sample(category: "complete", file: "full_joke.wav", expectedComplete: true),
    Sample(category: "complete", file: "full_weather.wav", expectedComplete: true),
    Sample(category: "tts_partial", file: "test_input_partial.wav", expectedComplete: false),
    Sample(category: "tts_partial", file: "partial_thinking.wav", expectedComplete: false),
    Sample(category: "tts_partial", file: "partial_canyou.wav", expectedComplete: false),
    Sample(category: "hard_cut", file: "cut_france_60.wav", expectedComplete: false),
    Sample(category: "hard_cut", file: "cut_france_40.wav", expectedComplete: false),
    Sample(category: "hard_cut", file: "cut_game_50.wav", expectedComplete: false),
]

private struct TurnBenchmarkItem: Codable {
    let category: String
    let file: String
    let expectedComplete: Bool
    let predictedComplete: Bool
    let correct: Bool
    let probability: Float
    let smartTurnMilliseconds: Double
    let audioDurationSeconds: Double
    let vadSpeechStarted: Bool
    let vadSpeechStopped: Bool
    let vadSpeechStartSeconds: Double?
    let vadSpeechEndSeconds: Double?
    let vadProcessingMilliseconds: Double
}

private struct TurnCategorySummary: Codable {
    let category: String
    let itemCount: Int
    let correctCount: Int
    let accuracy: Double
    let meanProbability: Double
}

private struct TurnBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAtUTC: String
    let vadModel: String
    let smartTurnModel: String
    let warmupMilliseconds: Double
    let threshold: Double
    let itemCount: Int
    let correctCount: Int
    let accuracy: Double
    let vadSpeechDetectionRate: Double
    let vadStopDetectionRate: Double
    let meanSmartTurnMilliseconds: Double
    let meanVADProcessingMilliseconds: Double
    let categorySummaries: [TurnCategorySummary]
    let items: [TurnBenchmarkItem]
}

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

private func elapsedMilliseconds(since started: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
}

private struct Options {
    var audioDirectory = ""
    var output = "turn-benchmark-results.json"
    var offline = false
    var showHelp = false

    static let help = """
    Usage: remote-asr-turn-benchmark --audio-dir <directory> [options]
      --audio-dir <path>  Directory containing the 10 Smart Turn WAV samples
      --output <path>     JSON output path
      --offline           Require Silero weights to be cached
      --help              Show this help
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--audio-dir": result.audioDirectory = try value(arguments, &index)
            case "--output": result.output = try value(arguments, &index)
            case "--offline": result.offline = true
            case "--help", "-h": result.showHelp = true
            default: throw TurnBenchmarkError.invalid("Unknown option: \(arguments[index])")
            }
            index += 1
        }
        if !result.showHelp && result.audioDirectory.isEmpty {
            throw TurnBenchmarkError.invalid("--audio-dir is required")
        }
        return result
    }

    private static func value(_ arguments: [String], _ index: inout Int) throws -> String {
        index += 1
        guard index < arguments.count else { throw TurnBenchmarkError.invalid("Missing option value") }
        return arguments[index]
    }
}

private enum TurnBenchmarkError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): message }
    }
}
