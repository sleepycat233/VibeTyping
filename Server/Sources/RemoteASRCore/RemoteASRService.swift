import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket

public struct RemoteASRServiceConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let token: String
    public let serviceName: String
    public let protocolConfiguration: RealtimeProtocolConfiguration

    public init(
        host: String = "0.0.0.0",
        port: Int = 8080,
        token: String,
        serviceName: String = Host.current().localizedName ?? "Remote ASR",
        protocolConfiguration: RealtimeProtocolConfiguration = .init()
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.serviceName = serviceName
        self.protocolConfiguration = protocolConfiguration
    }
}

public struct RemoteASRService: Sendable {
    private let configuration: RemoteASRServiceConfiguration
    private let transcriber: any ASRTranscribing
    private let telemetry: InferenceTelemetry
    private let turnDetector: (any StreamingTurnDetecting)?
    private let smartTurnAnalyzer: (any SmartTurnAnalyzing)?

    public init(
        configuration: RemoteASRServiceConfiguration,
        transcriber: any ASRTranscribing,
        telemetry: InferenceTelemetry = .init(),
        turnDetector: (any StreamingTurnDetecting)? = nil,
        smartTurnAnalyzer: (any SmartTurnAnalyzing)? = nil
    ) {
        self.configuration = configuration
        self.transcriber = transcriber
        self.telemetry = telemetry
        self.turnDetector = turnDetector
        self.smartTurnAnalyzer = smartTurnAnalyzer
    }

    public func run() async throws {
        let router = Router()
        let token = configuration.token
        router.get("/health") { _, _ in
            Self.jsonResponse([
                "status": "ok",
                "protocol_version": RealtimeProtocolConfiguration.protocolVersion,
                "model": RealtimeProtocolConfiguration.modelName,
                "turn_detection_modes": ["manual", "server_vad", "server_vad_smart_turn"],
            ])
        }
        let telemetry = self.telemetry
        router.get("/metrics") { request, _ in
            guard validBearerAuthorization(request.headers[.authorization], token: token) else {
                return Self.jsonResponse(
                    ["error": "Missing or invalid bearer token"],
                    status: .unauthorized
                )
            }
            return Self.encodedJSONResponse(telemetry.statusSnapshot())
        }
        router.get("/v1/realtime") { _, _ in
            Self.jsonResponse(
                ["error": "Missing or invalid bearer token"],
                status: .unauthorized
            )
        }

        let transcriber = self.transcriber
        let protocolConfiguration = configuration.protocolConfiguration
        let turnDetector = self.turnDetector
        let smartTurnAnalyzer = self.smartTurnAnalyzer
        let websocketConfiguration = WebSocketServerConfiguration(
            maxFrameSize: 1 << 22,
            autoPing: .disabled
        )
        let server: HTTPServerBuilder = .http1WebSocketUpgrade(configuration: websocketConfiguration) {
            head, _, _ in
            guard head.path == "/v1/realtime",
                  validBearerAuthorization(head.headerFields[.authorization], token: token) else {
                return .dontUpgrade
            }
            return .upgrade([:]) { inbound, outbound, _ in
                let session = RealtimeSessionEngine(
                    transcriber: transcriber,
                    configuration: protocolConfiguration,
                    turnDetector: turnDetector,
                    smartTurnAnalyzer: smartTurnAnalyzer
                )
                defer { Task { await session.discardAudio() } }
                try await outbound.write(.text(session.createdEvent().json))

                let keepalive = Task.detached { [outbound] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 15_000_000_000)
                            try Task.checkCancellation()
                            try await outbound.write(.text(
                                OutboundEvent.formatJSON(["type": "realtime.keepalive"])
                            ))
                        } catch {
                            return
                        }
                    }
                }
                defer { keepalive.cancel() }

                for try await message in inbound.messages(maxSize: 2 << 20) {
                    guard case .text(let text) = message else { continue }
                    for event in await session.handle(text: text) {
                        try await outbound.write(.text(event.json))
                    }
                }
            }
        }

        let bonjour = BonjourPublisher(
            name: configuration.serviceName,
            port: configuration.port
        )
        bonjour.start()
        defer { bonjour.stop() }

        let application = Application(
            router: router,
            server: server,
            configuration: .init(address: .hostname(configuration.host, port: configuration.port))
        )
        try await application.run()
    }

    private static func jsonResponse(
        _ payload: [String: Any],
        status: HTTPResponse.Status = .ok
    ) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private static func encodedJSONResponse<T: Encodable>(_ payload: T) -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }
}

private final class BonjourPublisher: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService

    init(name: String, port: Int) {
        service = NetService(
            domain: "local.",
            type: "_remote-asr._tcp.",
            name: name,
            port: Int32(port)
        )
        super.init()
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "path": Data("/v1/realtime".utf8),
            "protocol": Data(String(RealtimeProtocolConfiguration.protocolVersion).utf8),
        ]))
    }

    func start() {
        DispatchQueue.main.async { [service] in
            service.schedule(in: .main, forMode: .common)
            service.publish()
        }
    }

    func stop() {
        DispatchQueue.main.async { [service] in
            service.stop()
            service.remove(from: .main, forMode: .common)
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        FileHandle.standardError.write(Data("[bonjour] publish failed: \(errorDict)\n".utf8))
    }
}
