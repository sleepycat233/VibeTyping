import Foundation
import RemoteASRCore

@main
struct RemoteASRServerCommand {
    static func main() async throws {
        let options = try Options.parse(CommandLine.arguments)
        if options.showHelp {
            print(Options.help)
            return
        }
        guard let token = options.token, !token.isEmpty else {
            FileHandle.standardError.write(Data("error: provide --token or REMOTE_ASR_TOKEN\n".utf8))
            exit(2)
        }

        let telemetry = InferenceTelemetry(
            enabled: options.telemetry,
            intervalMilliseconds: options.telemetryIntervalMilliseconds
        )
        print("Loading \(QwenTranscriber.modelId)...")
        let transcriber = try await QwenTranscriber.load(
            offlineMode: options.offline,
            telemetry: telemetry
        )
        print("Loading \(SileroVADCoordinator.modelID)...")
        let turnDetector = try await SileroVADCoordinator.load(offlineMode: options.offline)
        print("Loading \(SmartTurnAnalyzer.modelName)...")
        let smartTurnAnalyzer = try SmartTurnAnalyzer.loadBundled()
        print("Warming up \(SmartTurnAnalyzer.modelName)...")
        _ = try await smartTurnAnalyzer.analyze(samples: [], sampleRate: WhisperLogMel.sampleRate)
        let configuration = RemoteASRServiceConfiguration(
            host: options.host,
            port: options.port,
            token: token,
            serviceName: options.serviceName
        )
        print("Remote ASR ready on ws://\(options.host):\(options.port)/v1/realtime")
        print("Bonjour: \(options.serviceName)._remote-asr._tcp.local")
        if options.telemetry {
            print("Telemetry: every \(options.telemetryIntervalMilliseconds) ms; GET /metrics")
        }
        try await RemoteASRService(
            configuration: configuration,
            transcriber: transcriber,
            telemetry: telemetry,
            turnDetector: turnDetector,
            smartTurnAnalyzer: smartTurnAnalyzer
        ).run()
    }
}

private struct Options {
    var host = "0.0.0.0"
    var port = 8080
    var token = ProcessInfo.processInfo.environment["REMOTE_ASR_TOKEN"]
    var serviceName = Host.current().localizedName ?? "Remote ASR"
    var offline = false
    var telemetry = false
    var telemetryIntervalMilliseconds = 500
    var showHelp = false

    static let help = """
    Usage: remote-asr-server [options]
      --host <host>           Bind host (default: 0.0.0.0)
      --port <port>           Bind port (default: 8080)
      --token <token>         Required bearer token; REMOTE_ASR_TOKEN is also accepted
      --service-name <name>   Bonjour service name
      --offline               Require the model to exist in the local cache
      --telemetry             Print live inference speed and memory metrics
      --telemetry-interval-ms <ms>
                              Polling interval from 100 to 10000 ms (default: 500)
      --help                  Show this help
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host":
                options.host = try value(after: argument, arguments: arguments, index: &index)
            case "--port":
                let raw = try value(after: argument, arguments: arguments, index: &index)
                guard let port = Int(raw), (1...65_535).contains(port) else {
                    throw OptionError.invalid("Invalid port: \(raw)")
                }
                options.port = port
            case "--token":
                options.token = try value(after: argument, arguments: arguments, index: &index)
            case "--service-name":
                options.serviceName = try value(after: argument, arguments: arguments, index: &index)
            case "--offline":
                options.offline = true
            case "--telemetry":
                options.telemetry = true
            case "--telemetry-interval-ms":
                let raw = try value(after: argument, arguments: arguments, index: &index)
                guard let interval = Int(raw), (100...10_000).contains(interval) else {
                    throw OptionError.invalid("Invalid telemetry interval: \(raw)")
                }
                options.telemetryIntervalMilliseconds = interval
            case "--help", "-h":
                options.showHelp = true
            default:
                throw OptionError.invalid("Unknown option: \(argument)")
            }
            index += 1
        }
        return options
    }

    private static func value(
        after option: String,
        arguments: [String],
        index: inout Int
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw OptionError.invalid("Missing value after \(option)")
        }
        return arguments[index]
    }
}

private enum OptionError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}
