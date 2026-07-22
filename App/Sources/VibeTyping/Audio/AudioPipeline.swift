import Foundation

enum PCM16Encoder {
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = min(1, max(-1, sample))
            let scaled: Int16
            if clamped >= 1 {
                scaled = Int16.max
            } else if clamped <= -1 {
                scaled = Int16.min
            } else {
                scaled = Int16((clamped * 32_768).rounded())
            }
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

struct AudioChunkAccumulator: Sendable {
    let samplesPerChunk: Int
    private var pending: [Float] = []

    init(sampleRate: Int = 24_000, chunkMilliseconds: Int = 100) {
        samplesPerChunk = sampleRate * chunkMilliseconds / 1_000
        pending.reserveCapacity(samplesPerChunk * 2)
    }

    mutating func append(_ samples: [Float]) -> [Data] {
        pending.append(contentsOf: samples)
        var chunks: [Data] = []
        while pending.count >= samplesPerChunk {
            chunks.append(PCM16Encoder.encode(Array(pending.prefix(samplesPerChunk))))
            pending.removeFirst(samplesPerChunk)
        }
        return chunks
    }

    mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        let data = PCM16Encoder.encode(pending)
        pending.removeAll(keepingCapacity: true)
        return data
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}

final class AudioSendQueue: @unchecked Sendable {
    typealias Sender = @Sendable (Data) async throws -> Void

    private let lock = NSLock()
    private let maximumPendingBytes: Int
    private let sender: Sender
    private var chunks: [Data] = []
    private var pendingBytes = 0
    private var isDraining = false
    private var failure: Error?
    private var flushWaiters: [CheckedContinuation<Result<Void, Error>, Never>] = []

    init(maximumPendingBytes: Int = 48_000, sender: @escaping Sender) {
        self.maximumPendingBytes = maximumPendingBytes
        self.sender = sender
    }

    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, pendingBytes + data.count <= maximumPendingBytes else {
            return false
        }
        chunks.append(data)
        pendingBytes += data.count
        guard !isDraining else { return true }
        isDraining = true
        Task { await self.drain() }
        return true
    }

    func flush() async throws {
        let result = await withCheckedContinuation { continuation in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(returning: Result<Void, Error>.failure(failure))
            } else if chunks.isEmpty && !isDraining {
                lock.unlock()
                continuation.resume(returning: .success(()))
            } else {
                flushWaiters.append(continuation)
                lock.unlock()
            }
        }
        try result.get()
    }

    func discard() {
        lock.lock()
        let removedBytes = chunks.reduce(0) { $0 + $1.count }
        chunks.removeAll(keepingCapacity: true)
        pendingBytes = max(0, pendingBytes - removedBytes)
        failure = nil
        let shouldFinishWaiters = !isDraining
        lock.unlock()
        if shouldFinishWaiters { finishWaiters() }
    }

    private func drain() async {
        while true {
            let next = dequeue()
            guard let next else {
                finishWaiters()
                return
            }

            do {
                try await sender(next)
                markSent(next.count)
            } catch {
                fail(error)
                return
            }
        }
    }

    private func dequeue() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !chunks.isEmpty else {
            isDraining = false
            return nil
        }
        return chunks.removeFirst()
    }

    private func markSent(_ byteCount: Int) {
        lock.lock()
        pendingBytes = max(0, pendingBytes - byteCount)
        lock.unlock()
    }

    private func fail(_ error: Error) {
        let waiters: [CheckedContinuation<Result<Void, Error>, Never>]
        lock.lock()
        failure = error
        chunks.removeAll(keepingCapacity: true)
        pendingBytes = 0
        isDraining = false
        waiters = flushWaiters
        flushWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: .failure(error)) }
    }

    private func finishWaiters() {
        let waiters: [CheckedContinuation<Result<Void, Error>, Never>]
        let result: Result<Void, Error>
        lock.lock()
        waiters = flushWaiters
        flushWaiters.removeAll()
        result = failure.map(Result.failure) ?? .success(())
        lock.unlock()
        waiters.forEach { $0.resume(returning: result) }
    }
}

final class AudioPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = AudioChunkAccumulator()
    private let sendQueue: AudioSendQueue
    private let sampleLimit: Int
    private let onFailure: @Sendable (Error) -> Void
    private let onLimitReached: @Sendable () -> Void
    private var acceptedSamples = 0
    private var stopped = false

    init(
        sendQueue: AudioSendQueue,
        sampleRate: Int = 24_000,
        maximumSeconds: Int = 30,
        onFailure: @escaping @Sendable (Error) -> Void,
        onLimitReached: @escaping @Sendable () -> Void
    ) {
        self.sendQueue = sendQueue
        sampleLimit = sampleRate * maximumSeconds
        self.onFailure = onFailure
        self.onLimitReached = onLimitReached
    }

    func accept(_ samples: [Float]) {
        var chunks: [Data] = []
        var reachedLimit = false

        lock.lock()
        if !stopped {
            let remaining = max(0, sampleLimit - acceptedSamples)
            let accepted = Array(samples.prefix(remaining))
            acceptedSamples += accepted.count
            chunks = accumulator.append(accepted)
            if acceptedSamples >= sampleLimit {
                stopped = true
                reachedLimit = true
            }
        }
        lock.unlock()

        for chunk in chunks where !sendQueue.enqueue(chunk) {
            onFailure(RealtimeClientError.sendQueueOverflow)
            return
        }
        if reachedLimit { onLimitReached() }
    }

    func finish() async throws {
        let tail = stopAndFlushTail()
        if let tail, !sendQueue.enqueue(tail) {
            throw RealtimeClientError.sendQueueOverflow
        }
        try await sendQueue.flush()
    }

    private func stopAndFlushTail() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        return accumulator.flush()
    }

    func discard() {
        lock.lock()
        stopped = true
        accumulator.reset()
        lock.unlock()
        sendQueue.discard()
    }

    func waitUntilIdle() async throws {
        try await sendQueue.flush()
    }
}
