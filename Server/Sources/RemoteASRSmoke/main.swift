import Foundation

@main
struct RemoteASRSmokeCommand {
    static func main() async throws {
        let options = try Options.parse(CommandLine.arguments)
        let wav = try PCM16Wave.load(url: URL(fileURLWithPath: options.wavPath))
        let pcm24k = wav.resampledPCM16(targetSampleRate: 24_000)

        var request = URLRequest(url: options.url)
        request.setValue("Bearer \(options.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await expect(socket, type: "session.created")
        try await send(socket, [
            "type": "session.update",
            "session": [
                "model": "qwen3-asr",
                "input_audio_transcription": ["model": "qwen3-asr"],
                "input_audio_format": "pcm16",
            ],
        ])
        try await expect(socket, type: "session.updated")
        try await send(socket, ["type": "input_audio_buffer.clear"])
        try await expect(socket, type: "input_audio_buffer.cleared")

        let chunkBytes = 24_000 * MemoryLayout<Int16>.size / 10
        var offset = 0
        while offset < pcm24k.count {
            let end = min(offset + chunkBytes, pcm24k.count)
            try await send(socket, [
                "type": "input_audio_buffer.append",
                "audio": pcm24k[offset..<end].base64EncodedString(),
            ])
            offset = end
        }
        try await send(socket, ["type": "input_audio_buffer.commit"])

        while true {
            let event = try await receive(socket)
            let type = event["type"] as? String
            if type == "conversation.item.input_audio_transcription.completed" {
                print(event["transcript"] as? String ?? "")
                return
            }
            if type == "error" {
                let error = event["error"] as? [String: Any]
                throw SmokeError.server(error?["message"] as? String ?? "Unknown server error")
            }
        }
    }

    private static func send(_ socket: URLSessionWebSocketTask, _ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func expect(_ socket: URLSessionWebSocketTask, type: String) async throws {
        let event = try await receive(socket)
        guard event["type"] as? String == type else {
            throw SmokeError.protocolViolation("Expected \(type), received \(event)")
        }
    }

    private static func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmokeError.protocolViolation("Expected JSON text event")
        }
        return json
    }
}

private struct Options {
    let url: URL
    let token: String
    let wavPath: String

    static func parse(_ arguments: [String]) throws -> Options {
        var url: URL?
        var token: String?
        var wavPath: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                throw SmokeError.usage("Missing value after \(argument)")
            }
            switch argument {
            case "--url": url = URL(string: arguments[index + 1])
            case "--token": token = arguments[index + 1]
            case "--wav": wavPath = arguments[index + 1]
            default: throw SmokeError.usage("Unknown option: \(argument)")
            }
            index += 2
        }
        guard let url, let token, let wavPath else {
            throw SmokeError.usage("Usage: remote-asr-smoke --url ws://host:port/v1/realtime --token TOKEN --wav FILE")
        }
        return Options(url: url, token: token, wavPath: wavPath)
    }
}

private struct PCM16Wave {
    let sampleRate: Int
    let samples: [Int16]

    static func load(url: URL) throws -> PCM16Wave {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw SmokeError.invalidWave("Not a RIFF/WAVE file")
        }

        var formatCode: UInt16?
        var channels: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var audioData: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let start = offset + 8
            let end = start + size
            guard end <= data.count else { break }
            if id == "fmt ", size >= 16 {
                formatCode = readUInt16LE(data, at: start)
                channels = readUInt16LE(data, at: start + 2)
                sampleRate = readUInt32LE(data, at: start + 4)
                bitsPerSample = readUInt16LE(data, at: start + 14)
            } else if id == "data" {
                audioData = data[start..<end]
            }
            offset = end + (size.isMultiple(of: 2) ? 0 : 1)
        }

        guard formatCode == 1, channels == 1, bitsPerSample == 16,
              let sampleRate, let audioData else {
            throw SmokeError.invalidWave("Expected mono PCM16 WAV")
        }
        let count = audioData.count / MemoryLayout<Int16>.size
        var samples = [Int16](repeating: 0, count: count)
        audioData.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                samples[index] = Int16(littleEndian: values[index])
            }
        }
        return PCM16Wave(sampleRate: Int(sampleRate), samples: samples)
    }

    func resampledPCM16(targetSampleRate: Int) -> Data {
        let outputCount = Int((Double(samples.count) * Double(targetSampleRate) / Double(sampleRate)).rounded())
        var output = Data(count: outputCount * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<outputCount {
                let source = Double(index) * Double(sampleRate) / Double(targetSampleRate)
                let left = min(Int(source), samples.count - 1)
                let right = min(left + 1, samples.count - 1)
                let fraction = source - Double(left)
                let value = Double(samples[left]) * (1 - fraction) + Double(samples[right]) * fraction
                values[index] = Int16(clamping: Int(value.rounded())).littleEndian
            }
        }
        return output
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case usage(String)
    case invalidWave(String)
    case protocolViolation(String)
    case server(String)

    var description: String {
        switch self {
        case .usage(let message), .invalidWave(let message),
             .protocolViolation(let message), .server(let message): message
        }
    }
}
