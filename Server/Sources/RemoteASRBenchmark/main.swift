import AudioCommon
import Foundation
import RemoteASRCore

@main
struct RemoteASRBenchmarkCommand {
    static func main() async throws {
        let options = try Options.parse(CommandLine.arguments)
        if options.showHelp {
            print(Options.help)
            return
        }

        let manifestURL = URL(fileURLWithPath: options.manifest).standardizedFileURL
        var rows = try loadManifest(manifestURL)
        if let limit = options.limit { rows = Array(rows.prefix(limit)) }
        guard !rows.isEmpty else { throw BenchmarkError.invalid("Manifest contains no samples") }

        print("Loading \(QwenTranscriber.modelId)...")
        let transcriber = try await QwenTranscriber.load(offlineMode: options.offline)
        if !options.skipWarmup {
            let first = rows[0]
            let audio = try loadAudio(first, manifestURL: manifestURL)
            print("Warming up with \(first.id)...")
            _ = try await transcriber.transcribe(samples: audio.samples, sampleRate: audio.sampleRate)
        }

        let startedAt = ISO8601DateFormatter().string(from: Date())
        var items = [BenchmarkItemResult]()
        for (index, row) in rows.enumerated() {
            do {
                let audio = try loadAudio(row, manifestURL: manifestURL)
                let audioDuration = Double(audio.samples.count) / Double(audio.sampleRate)
                let started = DispatchTime.now().uptimeNanoseconds
                let transcript = try await transcriber.transcribe(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsed = seconds(since: started)
                let scoring = BenchmarkScoring.score(
                    reference: row.reference,
                    hypothesis: transcript,
                    language: row.language
                )
                items.append(BenchmarkItemResult(
                    id: row.id,
                    language: row.language,
                    source: row.source,
                    audioPath: row.audio,
                    audioDurationSeconds: audioDuration,
                    reference: row.reference,
                    transcript: transcript,
                    normalizedReference: scoring.normalizedReference,
                    normalizedTranscript: scoring.normalizedHypothesis,
                    metric: scoring.metric,
                    substitutions: scoring.breakdown.substitutions,
                    insertions: scoring.breakdown.insertions,
                    deletions: scoring.breakdown.deletions,
                    referenceUnits: scoring.breakdown.referenceUnits,
                    errorRate: scoring.breakdown.errorRate,
                    elapsedSeconds: elapsed,
                    realTimeFactor: audioDuration > 0 ? elapsed / audioDuration : 0,
                    audioXRealtime: elapsed > 0 ? audioDuration / elapsed : 0,
                    success: true,
                    error: nil
                ))
                print(String(
                    format: "[%02d/%02d] %@ %@=%.2f%% time=%.2fs speed=%.2fx",
                    index + 1,
                    rows.count,
                    row.id,
                    scoring.metric,
                    scoring.breakdown.errorRate * 100,
                    elapsed,
                    elapsed > 0 ? audioDuration / elapsed : 0
                ))
            } catch {
                items.append(BenchmarkItemResult.failed(row: row, error: String(describing: error)))
                print("[\(index + 1)/\(rows.count)] \(row.id) FAILED: \(error)")
            }
        }

        let report = BenchmarkReport(
            schemaVersion: 1,
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            startedAtUTC: startedAt,
            model: QwenTranscriber.modelId,
            backend: "MLX/GPU",
            manifest: options.manifest,
            warmupEnabled: !options.skipWarmup,
            itemCount: items.count,
            successCount: items.filter(\.success).count,
            failureCount: items.filter { !$0.success }.count,
            totalAudioSeconds: items.reduce(0) { $0 + $1.audioDurationSeconds },
            totalElapsedSeconds: items.reduce(0) { $0 + $1.elapsedSeconds },
            summaries: summarize(items),
            items: items
        )

        let outputURL = URL(fileURLWithPath: options.output).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        printSummary(report)
        print("Wrote \(outputURL.path)")

        if report.failureCount > 0 { exit(1) }
    }
}

private struct ManifestRow: Decodable {
    let id: String
    let audio: String
    let reference: String
    let language: String
    let source: String
    let durationSec: Double?

    enum CodingKeys: String, CodingKey {
        case id, audio, reference, language, source
        case durationSec = "duration_sec"
    }
}

private struct BenchmarkItemResult: Codable {
    let id: String
    let language: String
    let source: String
    let audioPath: String
    let audioDurationSeconds: Double
    let reference: String
    let transcript: String
    let normalizedReference: String
    let normalizedTranscript: String
    let metric: String
    let substitutions: Int
    let insertions: Int
    let deletions: Int
    let referenceUnits: Int
    let errorRate: Double
    let elapsedSeconds: Double
    let realTimeFactor: Double
    let audioXRealtime: Double
    let success: Bool
    let error: String?

    static func failed(row: ManifestRow, error: String) -> BenchmarkItemResult {
        BenchmarkItemResult(
            id: row.id,
            language: row.language,
            source: row.source,
            audioPath: row.audio,
            audioDurationSeconds: row.durationSec ?? 0,
            reference: row.reference,
            transcript: "",
            normalizedReference: "",
            normalizedTranscript: "",
            metric: BenchmarkScoring.isChinese(row.language) ? "CER" : "WER",
            substitutions: 0,
            insertions: 0,
            deletions: 0,
            referenceUnits: 0,
            errorRate: 0,
            elapsedSeconds: 0,
            realTimeFactor: 0,
            audioXRealtime: 0,
            success: false,
            error: error
        )
    }
}

private struct BenchmarkSummary: Codable {
    let language: String
    let metric: String
    let itemCount: Int
    let substitutions: Int
    let insertions: Int
    let deletions: Int
    let referenceUnits: Int
    let aggregateErrorRate: Double
    let meanErrorRate: Double
    let medianErrorRate: Double
    let totalAudioSeconds: Double
    let totalElapsedSeconds: Double
    let overallRealTimeFactor: Double
    let overallAudioXRealtime: Double
}

private struct BenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAtUTC: String
    let startedAtUTC: String
    let model: String
    let backend: String
    let manifest: String
    let warmupEnabled: Bool
    let itemCount: Int
    let successCount: Int
    let failureCount: Int
    let totalAudioSeconds: Double
    let totalElapsedSeconds: Double
    let summaries: [BenchmarkSummary]
    let items: [BenchmarkItemResult]
}

private func loadManifest(_ url: URL) throws -> [ManifestRow] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(whereSeparator: \Character.isNewline).map { line in
        try decoder.decode(ManifestRow.self, from: Data(line.utf8))
    }
}

private func loadAudio(_ row: ManifestRow, manifestURL: URL) throws -> (samples: [Float], sampleRate: Int) {
    let audioURL = URL(fileURLWithPath: row.audio, relativeTo: manifestURL.deletingLastPathComponent())
        .standardizedFileURL
    return try AudioFileLoader.loadWAV(url: audioURL)
}

private func summarize(_ items: [BenchmarkItemResult]) -> [BenchmarkSummary] {
    Dictionary(grouping: items.filter(\.success), by: { $0.language }).map { language, group in
        let substitutions = group.reduce(0) { $0 + $1.substitutions }
        let insertions = group.reduce(0) { $0 + $1.insertions }
        let deletions = group.reduce(0) { $0 + $1.deletions }
        let referenceUnits = group.reduce(0) { $0 + $1.referenceUnits }
        let audio = group.reduce(0) { $0 + $1.audioDurationSeconds }
        let elapsed = group.reduce(0) { $0 + $1.elapsedSeconds }
        let rates = group.map(\.errorRate).sorted()
        return BenchmarkSummary(
            language: language,
            metric: group.first?.metric ?? "",
            itemCount: group.count,
            substitutions: substitutions,
            insertions: insertions,
            deletions: deletions,
            referenceUnits: referenceUnits,
            aggregateErrorRate: referenceUnits > 0
                ? Double(substitutions + insertions + deletions) / Double(referenceUnits)
                : 0,
            meanErrorRate: rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count),
            medianErrorRate: median(rates),
            totalAudioSeconds: audio,
            totalElapsedSeconds: elapsed,
            overallRealTimeFactor: audio > 0 ? elapsed / audio : 0,
            overallAudioXRealtime: elapsed > 0 ? audio / elapsed : 0
        )
    }.sorted { $0.language < $1.language }
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let middle = values.count / 2
    return values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2
        : values[middle]
}

private func printSummary(_ report: BenchmarkReport) {
    print("\nBenchmark summary")
    for summary in report.summaries {
        print(String(
            format: "%@ %@ aggregate=%.3f%% mean=%.3f%% median=%.3f%% speed=%.2fx n=%d",
            summary.language,
            summary.metric,
            summary.aggregateErrorRate * 100,
            summary.meanErrorRate * 100,
            summary.medianErrorRate * 100,
            summary.overallAudioXRealtime,
            summary.itemCount
        ))
    }
    print(String(
        format: "total audio=%.2fs elapsed=%.2fs speed=%.2fx failures=%d",
        report.totalAudioSeconds,
        report.totalElapsedSeconds,
        report.totalElapsedSeconds > 0 ? report.totalAudioSeconds / report.totalElapsedSeconds : 0,
        report.failureCount
    ))
}

private func seconds(since started: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
}

private struct Options {
    var manifest = ""
    var output = "benchmark-results.json"
    var limit: Int?
    var offline = false
    var skipWarmup = false
    var showHelp = false

    static let help = """
    Usage: remote-asr-benchmark --manifest <manifest.jsonl> [options]
      --manifest <path>   FLEURS-style JSONL manifest
      --output <path>     JSON report path (default: benchmark-results.json)
      --limit <count>     Run only the first N samples
      --offline           Require model files to exist in local cache
      --skip-warmup       Include first-use MLX compilation in item timings
      --help              Show this help
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--manifest": result.manifest = try value(arguments, &index)
            case "--output": result.output = try value(arguments, &index)
            case "--limit":
                let raw = try value(arguments, &index)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw BenchmarkError.invalid("Invalid limit: \(raw)")
                }
                result.limit = parsed
            case "--offline": result.offline = true
            case "--skip-warmup": result.skipWarmup = true
            case "--help", "-h": result.showHelp = true
            default: throw BenchmarkError.invalid("Unknown option: \(arguments[index])")
            }
            index += 1
        }
        if !result.showHelp && result.manifest.isEmpty {
            throw BenchmarkError.invalid("--manifest is required")
        }
        return result
    }

    private static func value(_ arguments: [String], _ index: inout Int) throws -> String {
        index += 1
        guard index < arguments.count else { throw BenchmarkError.invalid("Missing option value") }
        return arguments[index]
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): message }
    }
}
