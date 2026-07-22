import AudioCommon
import Foundation
import MLX
import MLXFFT

public enum WhisperLogMel {
    public static let sampleRate = 16_000
    public static let sampleCount = sampleRate * 8
    public static let melCount = 80
    public static let frameCount = 800

    public static func features(samples: [Float], sampleRate inputSampleRate: Int) -> [Float] {
        let resampled = inputSampleRate == sampleRate
            ? samples
            : AudioFileLoader.resample(samples, from: inputSampleRate, to: sampleRate)
        var audio: [Float]
        if resampled.count >= sampleCount {
            audio = Array(resampled.suffix(sampleCount))
        } else {
            audio = [Float](repeating: 0, count: sampleCount - resampled.count) + resampled
        }

        let mean = audio.reduce(Float.zero, +) / Float(audio.count)
        var variance: Float = 0
        for sample in audio {
            let centered = sample - mean
            variance += centered * centered
        }
        variance /= Float(audio.count)
        let scale = 1 / sqrt(variance + 1e-7)
        for index in audio.indices {
            audio[index] = (audio[index] - mean) * scale
        }

        let padded = reflectPad(audio, count: nFFT / 2)
        let frames = (padded.count - nFFT) / hopLength + 1
        let window = periodicHann(length: nFFT)
        var framed = [Float](repeating: 0, count: frames * nFFT)
        for frame in 0..<frames {
            let start = frame * hopLength
            for sample in 0..<nFFT {
                framed[frame * nFFT + sample] = padded[start + sample] * window[sample]
            }
        }

        let frameArray = MLXArray(framed, [frames, nFFT])
        let spectrum = rfft(frameArray, axis: -1)
        let power = MLX.pow(MLX.abs(spectrum), MLXArray(Float(2)))
        let filters = MLXArray(melFilterbank(), [melCount, nFFT / 2 + 1])
        var mel = matmul(power, filters.transposed())
        mel = mel[0..<frameCount, 0...].transposed(1, 0)
        var logSpec = MLX.log10(maximum(mel, MLXArray(Float(1e-10))))
        logSpec = maximum(logSpec, logSpec.max() - MLXArray(Float(8)))
        logSpec = (logSpec + MLXArray(Float(4))) / MLXArray(Float(4))
        eval(logSpec)
        return logSpec.asType(.float32).asArray(Float.self)
    }

    private static func reflectPad(_ input: [Float], count: Int) -> [Float] {
        precondition(input.count > count)
        var output = [Float](repeating: 0, count: input.count + count * 2)
        for index in input.indices { output[count + index] = input[index] }
        for index in 0..<count { output[index] = input[count - index] }
        let last = input.count - 1
        for index in 0..<count { output[count + input.count + index] = input[last - 1 - index] }
        return output
    }

    private static func periodicHann(length: Int) -> [Float] {
        (0..<length).map { index in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(index) / Double(length))))
        }
    }

    private static func melFilterbank() -> [Float] {
        let frequencyBins = nFFT / 2 + 1
        let melMinimum = hertzToMel(0)
        let melMaximum = hertzToMel(Double(sampleRate) / 2)
        let melPoints = (0..<(melCount + 2)).map { index in
            melMinimum + Double(index) / Double(melCount + 1) * (melMaximum - melMinimum)
        }
        let filterFrequencies = melPoints.map(melToHertz)
        var filters = [Float](repeating: 0, count: melCount * frequencyBins)
        for mel in 0..<melCount {
            let lower = filterFrequencies[mel]
            let center = filterFrequencies[mel + 1]
            let upper = filterFrequencies[mel + 2]
            let normalization = 2 / max(upper - lower, 1e-12)
            for bin in 0..<frequencyBins {
                let frequency = Double(bin) * Double(sampleRate) / Double(nFFT)
                let value: Double
                if frequency < lower || frequency > upper {
                    value = 0
                } else if frequency <= center {
                    value = (frequency - lower) / max(center - lower, 1e-12)
                } else {
                    value = (upper - frequency) / max(upper - center, 1e-12)
                }
                filters[mel * frequencyBins + bin] = Float(max(0, value) * normalization)
            }
        }
        return filters
    }

    private static func hertzToMel(_ frequency: Double) -> Double {
        let minimumLogHertz = 1000.0
        let minimumLogMel = 15.0
        let logStep = 27.0 / log(6.4)
        return frequency >= minimumLogHertz
            ? minimumLogMel + log(frequency / minimumLogHertz) * logStep
            : 3 * frequency / 200
    }

    private static func melToHertz(_ mel: Double) -> Double {
        let minimumLogHertz = 1000.0
        let minimumLogMel = 15.0
        let logStep = log(6.4) / 27.0
        return mel >= minimumLogMel
            ? minimumLogHertz * exp(logStep * (mel - minimumLogMel))
            : 200 * mel / 3
    }

    private static let nFFT = 400
    private static let hopLength = 160
}
