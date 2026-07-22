import AudioToolbox
import AVFoundation
import Foundation

enum MicrophoneRecorderError: Error, LocalizedError {
    case formatUnavailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .formatUnavailable: "The selected microphone format is unavailable."
        case .converterUnavailable: "The microphone audio converter could not be created."
        }
    }
}

final class MicrophoneRecorder {
    private var engine: AVAudioEngine?

    func start(
        device: AudioInputDevice?,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        stop()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if var deviceID = device?.id, let audioUnit = inputNode.audioUnit {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw MicrophoneRecorderError.formatUnavailable
            }
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
              ) else {
            throw MicrophoneRecorderError.formatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneRecorderError.converterUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(capacity, 1)
            ) else { return }

            var conversionError: NSError?
            var supplied = false
            converter.convert(to: converted, error: &conversionError) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }

            guard conversionError == nil,
                  converted.frameLength > 0,
                  let channel = converted.floatChannelData?[0] else { return }
            let count = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channel, count: count))
            let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
            let rms = sqrt(sum / Float(max(samples.count, 1)))
            onLevel(min(1, rms * 24))
            onSamples(samples)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
