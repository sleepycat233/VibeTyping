import Foundation

actor RealtimeClient {
    typealias EventHandler = @Sendable (RealtimeEvent) -> Void
    typealias StateHandler = @Sendable (RealtimeConnectionState) -> Void

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var state: RealtimeConnectionState = .disconnected
    private let onEvent: EventHandler
    private let onState: StateHandler

    init(onEvent: @escaping EventHandler, onState: @escaping StateHandler) {
        self.onEvent = onEvent
        self.onState = onState
    }

    func connect(url: URL, token: String) {
        disconnect()
        generation &+= 1
        let currentGeneration = generation
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        setState(.connecting)
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: currentGeneration)
        }
    }

    func disconnect() {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        setState(.disconnected)
    }

    func clearAudio() async throws {
        try await send(RealtimeProtocolCodec.clearAudio())
    }

    func appendAudio(_ data: Data) async throws {
        try await send(RealtimeProtocolCodec.appendAudio(data))
    }

    func commitAudio() async throws {
        try await send(RealtimeProtocolCodec.commitAudio())
    }

    private func send(_ text: String) async throws {
        guard let task else { throw RealtimeClientError.disconnected }
        do {
            try await task.send(.string(text))
        } catch {
            throw RealtimeClientError.transport(error.localizedDescription)
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, generation currentGeneration: UInt64) async {
        while !Task.isCancelled, currentGeneration == generation {
            do {
                let message = try await socket.receive()
                guard currentGeneration == generation else { return }
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    text = value
                @unknown default:
                    continue
                }

                let event = RealtimeProtocolCodec.parse(text)
                if event == .sessionCreated {
                    do {
                        try await send(RealtimeProtocolCodec.sessionUpdate())
                    } catch {
                        handleFailure(error, httpStatus: nil, generation: currentGeneration)
                        return
                    }
                } else if event == .sessionUpdated {
                    setState(.ready)
                }
                onEvent(event)
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                handleFailure(
                    error,
                    httpStatus: (socket.response as? HTTPURLResponse)?.statusCode,
                    generation: currentGeneration
                )
                return
            }
        }
    }

    private func handleFailure(
        _ error: Error,
        httpStatus: Int?,
        generation currentGeneration: UInt64
    ) {
        guard currentGeneration == generation else { return }
        task = nil
        receiveTask = nil
        setState(.disconnected)
        if httpStatus == 401 {
            onEvent(.error(code: "unauthorized", message: RealtimeClientError.unauthorized.localizedDescription))
        } else {
            onEvent(.error(code: "connection_error", message: error.localizedDescription))
        }
    }

    private func setState(_ next: RealtimeConnectionState) {
        guard next != state else { return }
        state = next
        onState(next)
    }
}
