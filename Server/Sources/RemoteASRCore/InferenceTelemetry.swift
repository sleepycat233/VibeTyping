import Darwin
import Foundation
import MLX
import Synchronization

public struct InferenceMemoryMetrics: Codable, Equatable, Sendable {
    public let mlxActiveBytes: Int
    public let mlxCacheBytes: Int
    public let mlxPeakBytes: Int
    public let processResidentBytes: Int

    public init(
        mlxActiveBytes: Int,
        mlxCacheBytes: Int,
        mlxPeakBytes: Int,
        processResidentBytes: Int
    ) {
        self.mlxActiveBytes = mlxActiveBytes
        self.mlxCacheBytes = mlxCacheBytes
        self.mlxPeakBytes = mlxPeakBytes
        self.processResidentBytes = processResidentBytes
    }
}

public struct InferenceProgressMetrics: Codable, Equatable, Sendable {
    public let requestId: String
    public let audioDurationSeconds: Double
    public let elapsedSeconds: Double
    public let audioXRealtime: Double
    public let memory: InferenceMemoryMetrics
    public let maxObservedMemory: InferenceMemoryMetrics
}

public struct InferenceCompletedMetrics: Codable, Equatable, Sendable {
    public let requestId: String
    public let audioDurationSeconds: Double
    public let resampleSeconds: Double
    public let inferenceSeconds: Double
    public let totalSeconds: Double
    public let realTimeFactor: Double
    public let audioXRealtime: Double
    public let outputCharacters: Int
    public let charactersPerSecond: Double
    public let memoryAtStart: InferenceMemoryMetrics
    public let memoryAtEnd: InferenceMemoryMetrics
    public let maxObservedMemory: InferenceMemoryMetrics
}

public struct InferenceTelemetryStatus: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let intervalMilliseconds: Int
    public let status: String
    public let memory: InferenceMemoryMetrics
    public let current: InferenceProgressMetrics?
    public let latest: InferenceCompletedMetrics?
}

public final class InferenceTelemetry: @unchecked Sendable {
    public typealias MemorySampler = @Sendable () -> InferenceMemoryMetrics
    public static let liveMemorySampler: MemorySampler = {
        InferenceTelemetry.sampleLiveMemory()
    }

    public let enabled: Bool
    public let intervalMilliseconds: Int

    private struct CurrentRun: Sendable {
        let requestId: String
        let audioDurationSeconds: Double
        let startedAt: Double
        let memoryAtStart: InferenceMemoryMetrics
        var lastMemory: InferenceMemoryMetrics
        var maxObservedMemory: InferenceMemoryMetrics
    }

    private struct State: Sendable {
        var current: CurrentRun?
        var latest: InferenceCompletedMetrics?
    }

    private let state = Mutex(State())
    private let memorySampler: MemorySampler

    public init(
        enabled: Bool = false,
        intervalMilliseconds: Int = 500,
        memorySampler: @escaping MemorySampler = InferenceTelemetry.liveMemorySampler
    ) {
        self.enabled = enabled
        self.intervalMilliseconds = max(100, intervalMilliseconds)
        self.memorySampler = memorySampler
    }

    @discardableResult
    public func begin(audioDurationSeconds: Double) -> String {
        let requestId = String(UUID().uuidString.prefix(8)).lowercased()
        let memory = memorySampler()
        let current = CurrentRun(
            requestId: requestId,
            audioDurationSeconds: audioDurationSeconds,
            startedAt: Self.uptimeSeconds(),
            memoryAtStart: memory,
            lastMemory: memory,
            maxObservedMemory: memory
        )
        state.withLock { $0.current = current }
        if enabled {
            emit(
                "start request=\(requestId) audio=\(format(audioDurationSeconds))s "
                    + memoryDescription(memory)
            )
        }
        return requestId
    }

    public func startMonitoring(requestId: String) -> Task<Void, Never>? {
        guard enabled else { return nil }
        let interval = UInt64(intervalMilliseconds) * 1_000_000
        return Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                self?.recordProgress(requestId: requestId)
            }
        }
    }

    public func finish(
        requestId: String,
        resampleSeconds: Double,
        inferenceSeconds: Double,
        outputCharacters: Int
    ) {
        let memoryAtEnd = memorySampler()
        let now = Self.uptimeSeconds()
        let completed = state.withLock { state -> InferenceCompletedMetrics? in
            guard let current = state.current, current.requestId == requestId else { return nil }
            let totalSeconds = max(0, now - current.startedAt)
            let audioDuration = current.audioDurationSeconds
            let maximum = Self.maximum(current.maxObservedMemory, memoryAtEnd)
            let metrics = InferenceCompletedMetrics(
                requestId: requestId,
                audioDurationSeconds: audioDuration,
                resampleSeconds: resampleSeconds,
                inferenceSeconds: inferenceSeconds,
                totalSeconds: totalSeconds,
                realTimeFactor: Self.ratio(totalSeconds, audioDuration),
                audioXRealtime: Self.ratio(audioDuration, totalSeconds),
                outputCharacters: outputCharacters,
                charactersPerSecond: Self.ratio(Double(outputCharacters), inferenceSeconds),
                memoryAtStart: current.memoryAtStart,
                memoryAtEnd: memoryAtEnd,
                maxObservedMemory: maximum
            )
            state.current = nil
            state.latest = metrics
            return metrics
        }
        guard enabled, let completed else { return }
        emit(
            "done request=\(requestId) audio=\(format(completed.audioDurationSeconds))s "
                + "total=\(format(completed.totalSeconds))s "
                + "rtf=\(format(completed.realTimeFactor)) "
                + "speed=\(format(completed.audioXRealtime))x "
                + "chars=\(completed.outputCharacters) "
                + "chars_per_sec=\(format(completed.charactersPerSecond)) "
                + memoryDescription(completed.maxObservedMemory, label: "max")
        )
    }

    public func statusSnapshot() -> InferenceTelemetryStatus {
        let now = Self.uptimeSeconds()
        let memory = memorySampler()
        let values = state.withLock { state -> (CurrentRun?, InferenceCompletedMetrics?) in
            (state.current, state.latest)
        }
        let progress = values.0.map { current in
            let elapsed = max(0, now - current.startedAt)
            return InferenceProgressMetrics(
                requestId: current.requestId,
                audioDurationSeconds: current.audioDurationSeconds,
                elapsedSeconds: elapsed,
                audioXRealtime: Self.ratio(current.audioDurationSeconds, elapsed),
                memory: memory,
                maxObservedMemory: Self.maximum(current.maxObservedMemory, memory)
            )
        }
        return InferenceTelemetryStatus(
            enabled: enabled,
            intervalMilliseconds: intervalMilliseconds,
            status: progress == nil ? "idle" : "running",
            memory: memory,
            current: progress,
            latest: values.1
        )
    }

    func recordProgress(requestId: String) {
        let memory = memorySampler()
        let now = Self.uptimeSeconds()
        let progress = state.withLock { state -> InferenceProgressMetrics? in
            guard var current = state.current, current.requestId == requestId else { return nil }
            current.lastMemory = memory
            current.maxObservedMemory = Self.maximum(current.maxObservedMemory, memory)
            state.current = current
            let elapsed = max(0, now - current.startedAt)
            return InferenceProgressMetrics(
                requestId: requestId,
                audioDurationSeconds: current.audioDurationSeconds,
                elapsedSeconds: elapsed,
                audioXRealtime: Self.ratio(current.audioDurationSeconds, elapsed),
                memory: memory,
                maxObservedMemory: current.maxObservedMemory
            )
        }
        guard enabled, let progress else { return }
        emit(
            "live request=\(requestId) elapsed=\(format(progress.elapsedSeconds))s "
                + "speed=\(format(progress.audioXRealtime))x "
                + memoryDescription(progress.memory)
        )
    }

    public static func sampleLiveMemory() -> InferenceMemoryMetrics {
        let snapshot = MLX.Memory.snapshot()
        return InferenceMemoryMetrics(
            mlxActiveBytes: snapshot.activeMemory,
            mlxCacheBytes: snapshot.cacheMemory,
            mlxPeakBytes: snapshot.peakMemory,
            processResidentBytes: processResidentBytes()
        )
    }

    private static func processResidentBytes() -> Int {
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, pointer, expected)
        }
        return result == expected ? Int(info.pti_resident_size) : 0
    }

    private static func uptimeSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func maximum(
        _ lhs: InferenceMemoryMetrics,
        _ rhs: InferenceMemoryMetrics
    ) -> InferenceMemoryMetrics {
        InferenceMemoryMetrics(
            mlxActiveBytes: max(lhs.mlxActiveBytes, rhs.mlxActiveBytes),
            mlxCacheBytes: max(lhs.mlxCacheBytes, rhs.mlxCacheBytes),
            mlxPeakBytes: max(lhs.mlxPeakBytes, rhs.mlxPeakBytes),
            processResidentBytes: max(lhs.processResidentBytes, rhs.processResidentBytes)
        )
    }

    private static func ratio(_ numerator: Double, _ denominator: Double) -> Double {
        denominator > 0 ? numerator / denominator : 0
    }

    private func memoryDescription(
        _ memory: InferenceMemoryMetrics,
        label: String? = nil
    ) -> String {
        let prefix = label.map { "\($0)_" } ?? ""
        return "\(prefix)mlx_active=\(megabytes(memory.mlxActiveBytes))MB "
            + "\(prefix)mlx_cache=\(megabytes(memory.mlxCacheBytes))MB "
            + "\(prefix)mlx_peak=\(megabytes(memory.mlxPeakBytes))MB "
            + "\(prefix)rss=\(megabytes(memory.processResidentBytes))MB"
    }

    private func megabytes(_ bytes: Int) -> String {
        format(Double(bytes) / 1_048_576)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func emit(_ message: String) {
        FileHandle.standardError.write(Data("[telemetry] \(message)\n".utf8))
    }
}
