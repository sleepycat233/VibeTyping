import Foundation

enum ServerStatus: Equatable, Sendable {
    case stopped
    case checking
    case loading
    case ready(pid: Int32?, owned: Bool)
    case failed(String)
}

enum ServerProcessError: Error, LocalizedError {
    case helperMissing
    case incompatiblePort
    case tokenConflict
    case startupTimeout
    case exited(Int32)

    var errorDescription: String? {
        switch self {
        case .helperMissing: "The bundled remote-asr-server helper is missing."
        case .incompatiblePort: "Port 8080 is occupied by an incompatible process."
        case .tokenConflict: "A compatible server is running on port 8080 with a different token."
        case .startupTimeout: "The local ASR server did not become ready in time."
        case .exited(let status): "The local ASR server exited with status \(status)."
        }
    }
}

@MainActor
final class ServerProcessManager: ObservableObject {
    @Published private(set) var status: ServerStatus = .stopped
    @Published private(set) var recentLogs: [String] = []

    private var process: Process?
    private var shuttingDown = false
    private var automaticRestartUsed = false
    private let healthURL = URL(string: "http://127.0.0.1:8080/health")!
    private let metricsURL = URL(string: "http://127.0.0.1:8080/metrics")!

    var token: String?
    var canAutomaticallyRestart: () -> Bool = { true }

    func ensureReady() async throws -> String {
        status = .checking
        let token = try LocalToken.loadOrCreate(
            in: KeychainStore(service: "io.github.sleepycat233.vibetyping")
        )
        self.token = token

        switch await probe(token: token) {
        case .ready:
            status = .ready(pid: nil, owned: false)
            return token
        case .tokenConflict:
            status = .failed(ServerProcessError.tokenConflict.localizedDescription)
            throw ServerProcessError.tokenConflict
        case .incompatible:
            status = .failed(ServerProcessError.incompatiblePort.localizedDescription)
            throw ServerProcessError.incompatiblePort
        case .absent:
            break
        }

        try launch(token: token)
        status = .loading
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            if let process, !process.isRunning {
                throw ServerProcessError.exited(process.terminationStatus)
            }
            if case .ready = await probe(token: token) {
                automaticRestartUsed = false
                status = .ready(pid: process?.processIdentifier, owned: true)
                return token
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ServerProcessError.startupTimeout
    }

    func restart() async throws -> String {
        terminateOwnedProcess()
        try await Task.sleep(for: .milliseconds(250))
        return try await ensureReady()
    }

    func shutdown() {
        shuttingDown = true
        terminateOwnedProcess()
        status = .stopped
    }

    private func launch(token: String) throws {
        guard process == nil else { return }
        let executable = try helperURL()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--host", "127.0.0.1",
            "--port", "8080",
            "--token", token,
            "--service-name", "VibeTyping Local",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text) }
        }
        process.terminationHandler = { [weak self, weak process] terminated in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                output.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                guard !self.shuttingDown else { return }
                let error = ServerProcessError.exited(terminated.terminationStatus)
                self.status = .failed(error.localizedDescription)
                if !self.automaticRestartUsed, self.canAutomaticallyRestart() {
                    self.automaticRestartUsed = true
                    do {
                        _ = try await self.ensureReady()
                    } catch {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
        try process.run()
        self.process = process
    }

    private func terminateOwnedProcess() {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    private func helperURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["REMOTE_ASR_SERVER_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/remote-asr-server")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let developmentCandidates = [
            workingDirectory
                .appendingPathComponent("Server/.build/arm64-apple-macosx/debug/remote-asr-server"),
            workingDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Server/.build/arm64-apple-macosx/debug/remote-asr-server"),
        ]
        if let development = developmentCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return development
        }
        throw ServerProcessError.helperMissing
    }

    private func appendLog(_ text: String) {
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        recentLogs.append(contentsOf: lines)
        if recentLogs.count > 200 { recentLogs.removeFirst(recentLogs.count - 200) }
    }

    private enum ProbeResult { case absent, ready, tokenConflict, incompatible }

    private func probe(token: String) async -> ProbeResult {
        var healthRequest = URLRequest(url: healthURL)
        healthRequest.timeoutInterval = 1
        do {
            let (data, response) = try await URLSession.shared.data(for: healthRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "ok",
                  json["protocol_version"] as? Int == 1,
                  json["model"] as? String == "qwen3-asr" else {
                return .incompatible
            }
            var metricsRequest = URLRequest(url: metricsURL)
            metricsRequest.timeoutInterval = 1
            metricsRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, metricsResponse) = try await URLSession.shared.data(for: metricsRequest)
            guard let metricsHTTP = metricsResponse as? HTTPURLResponse else { return .incompatible }
            if metricsHTTP.statusCode == 200 { return .ready }
            if metricsHTTP.statusCode == 401 { return .tokenConflict }
            return .incompatible
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost]
                .contains(nsError.code) {
                return .absent
            }
            return .absent
        }
    }
}
