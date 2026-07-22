import Foundation
import XCTest
@testable import VibeTyping

final class AudioPipelineTests: XCTestCase {
    func testPCM16EncodingClampsAndUsesLittleEndian() {
        let data = PCM16Encoder.encode([-1, -0.5, 0, 0.5, 1])
        let values: [Int16] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
        XCTAssertEqual(values, [Int16.min, -16_384, 0, 16_384, Int16.max])
    }

    func testChunkAccumulatorEmitsHundredMillisecondChunks() {
        var accumulator = AudioChunkAccumulator()
        XCTAssertTrue(accumulator.append([Float](repeating: 0.25, count: 2_399)).isEmpty)
        let chunks = accumulator.append([0.25, 0.25])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 4_800)
        XCTAssertEqual(accumulator.flush()?.count, 2)
    }

    func testSendQueueCountsInFlightBytesForOverflow() async throws {
        let gate = SendGate()
        let queue = AudioSendQueue(maximumPendingBytes: 4) { _ in
            await gate.wait()
        }
        XCTAssertTrue(queue.enqueue(Data(repeating: 1, count: 4)))
        await Task.yield()
        XCTAssertFalse(queue.enqueue(Data([2])))
        await gate.release()
        try await queue.flush()
    }

    func testDiscardWaitsForInFlightSendBeforeBecomingIdle() async throws {
        let gate = SendGate()
        let started = expectation(description: "send started")
        let queue = AudioSendQueue(maximumPendingBytes: 8) { _ in
            started.fulfill()
            await gate.wait()
        }
        XCTAssertTrue(queue.enqueue(Data(repeating: 1, count: 4)))
        XCTAssertTrue(queue.enqueue(Data(repeating: 2, count: 4)))
        await fulfillment(of: [started], timeout: 1)

        queue.discard()
        let completion = CompletionFlag()
        Task {
            try await queue.flush()
            await completion.markComplete()
        }
        try await Task.sleep(for: .milliseconds(20))
        let completedBeforeRelease = await completion.isComplete
        XCTAssertFalse(completedBeforeRelease)

        await gate.release()
        for _ in 0..<50 where !(await completion.isComplete) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completedAfterRelease = await completion.isComplete
        XCTAssertTrue(completedAfterRelease)
    }

    func testAudioPipelineStopsAtThirtySeconds() async throws {
        let recorder = DataRecorder()
        let limit = expectation(description: "limit")
        let queue = AudioSendQueue { data in await recorder.append(data) }
        let pipeline = AudioPipeline(
            sendQueue: queue,
            sampleRate: 10,
            maximumSeconds: 1,
            onFailure: { _ in XCTFail("unexpected failure") },
            onLimitReached: { limit.fulfill() }
        )
        pipeline.accept([Float](repeating: 0, count: 12))
        await fulfillment(of: [limit], timeout: 1)
        try await pipeline.finish()
        let byteCount = await recorder.byteCount
        XCTAssertEqual(byteCount, 20)
    }
}

private actor SendGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DataRecorder {
    private(set) var byteCount = 0
    func append(_ data: Data) { byteCount += data.count }
}

private actor CompletionFlag {
    private(set) var isComplete = false
    func markComplete() { isComplete = true }
}
