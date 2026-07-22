import Foundation

enum SessionPhase: String, Equatable, Sendable {
    case startingServer
    case idle
    case listening
    case transcribing
    case applying
    case ready
    case error
}

enum SessionEvent: Equatable, Sendable {
    case serverStarting
    case serverReady
    case press(Date)
    case release(Date)
    case autoLimitReached
    case transcript(String)
    case applyCompleted
    case readyExpired
    case cancel
    case fail(String)
    case retry
}

enum SessionEffect: Equatable, Sendable {
    case beginCapture
    case stopAndClear
    case stopAndCommit
    case applyTranscript(String)
    case scheduleReadyReset
    case reportError(String)
}

struct SessionStateMachine: Equatable, Sendable {
    private(set) var phase: SessionPhase = .startingServer
    private(set) var listeningStartedAt: Date?
    private(set) var lastError: String?
    let minimumHoldDuration: TimeInterval

    init(minimumHoldDuration: TimeInterval = 0.5) {
        self.minimumHoldDuration = minimumHoldDuration
    }

    @discardableResult
    mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        switch (phase, event) {
        case (_, .serverStarting):
            phase = .startingServer
            listeningStartedAt = nil
            return []

        case (.startingServer, .serverReady), (.error, .retry):
            phase = .idle
            lastError = nil
            return []

        case (.ready, .press(let date)), (.idle, .press(let date)):
            phase = .listening
            listeningStartedAt = date
            lastError = nil
            return [.beginCapture]

        case (.listening, .release(let date)):
            let startedAt = listeningStartedAt ?? date
            listeningStartedAt = nil
            if date.timeIntervalSince(startedAt) < minimumHoldDuration {
                phase = .idle
                return [.stopAndClear]
            }
            phase = .transcribing
            return [.stopAndCommit]

        case (.listening, .autoLimitReached):
            listeningStartedAt = nil
            phase = .transcribing
            return [.stopAndCommit]

        case (.listening, .cancel), (.transcribing, .cancel):
            listeningStartedAt = nil
            phase = .idle
            return [.stopAndClear]

        case (.transcribing, .transcript(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                phase = .idle
                return []
            }
            phase = .applying
            return [.applyTranscript(trimmed)]

        case (.applying, .applyCompleted):
            phase = .ready
            return [.scheduleReadyReset]

        case (.ready, .readyExpired):
            phase = .idle
            return []

        case (_, .fail(let message)):
            listeningStartedAt = nil
            lastError = message
            phase = .error
            return [.reportError(message)]

        default:
            return []
        }
    }
}
