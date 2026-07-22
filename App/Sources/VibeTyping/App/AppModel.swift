import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .startingServer
    @Published private(set) var connectionState: RealtimeConnectionState = .disconnected
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastTranscript = ""
    @Published private(set) var statusMessage = "Starting local server"
    @Published private(set) var lastAction = ""
    @Published private(set) var microphonePermission = Permissions.microphone
    @Published var petVisible: Bool {
        didSet { UserDefaults.standard.set(petVisible, forKey: "pet.visible") }
    }
    @Published var selectedMicrophoneUID: String? {
        didSet { UserDefaults.standard.set(selectedMicrophoneUID, forKey: "microphone.uid") }
    }

    let serverManager = ServerProcessManager()
    private(set) var microphones: [AudioInputDevice] = []

    private var machine = SessionStateMachine()
    private let recorder = MicrophoneRecorder()
    private var realtime: RealtimeClient!
    private var audioPipeline: AudioPipeline?
    private var petController: PetPanelController?
    private var readyResetTask: Task<Void, Never>?
    private var serverObservation: AnyCancellable?
    private var stoppingRecording = false

    init() {
        let defaults = UserDefaults.standard
        petVisible = defaults.object(forKey: "pet.visible") as? Bool ?? true
        selectedMicrophoneUID = defaults.string(forKey: "microphone.uid")
        microphones = AudioDeviceManager.inputDevices()

        realtime = RealtimeClient(
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleRealtimeEvent(event) }
            },
            onState: { [weak self] state in
                Task { @MainActor in self?.handleConnectionState(state) }
            }
        )
        serverManager.canAutomaticallyRestart = { [weak self] in
            self?.phase == .idle
        }
        serverObservation = serverManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var menuBarIconName: String {
        switch phase {
        case .startingServer: "hourglass"
        case .idle: "waveform"
        case .listening: "mic.fill"
        case .transcribing, .applying: "ellipsis.circle"
        case .ready: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var selectedMicrophone: AudioInputDevice? {
        AudioDeviceManager.device(matchingUID: selectedMicrophoneUID)
    }

    func start() {
        attachPetIfNeeded()
        if petVisible { petController?.show() }
        Task { await startServerAndConnect() }
    }

    func shutdown() {
        readyResetTask?.cancel()
        recorder.stop()
        audioPipeline?.discard()
        Task { await realtime.disconnect() }
        serverManager.shutdown()
    }

    func pushToTalkPressed() {
        let pressedAt = Date()
        Task { await beginListening(at: pressedAt) }
    }

    func pushToTalkReleased() {
        perform(machine.handle(.release(Date())))
    }

    func toggleFromPet() {
        switch phase {
        case .idle, .ready: pushToTalkPressed()
        case .listening: pushToTalkReleased()
        default: break
        }
    }

    func restartServer() {
        Task {
            recorder.stop()
            audioPipeline?.discard()
            await realtime.disconnect()
            perform(machine.handle(.serverStarting))
            statusMessage = "Restarting local server"
            do {
                let token = try await serverManager.restart()
                connect(token: token)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func requestAccessibility() {
        FocusedElementInspector.requestAccessibilityAccess()
    }

    func openAccessibilitySettings() { FocusedElementInspector.openAccessibilitySettings() }
    func openMicrophoneSettings() { Permissions.openMicrophoneSettings() }

    func setPetVisible(_ visible: Bool) {
        petVisible = visible
        visible ? petController?.show() : petController?.hide()
    }

    func resetPetPosition() { petController?.resetPosition() }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        lastAction = "Copied latest transcript"
    }

    func refreshMicrophones() {
        microphones = AudioDeviceManager.inputDevices()
        objectWillChange.send()
    }

    private func startServerAndConnect() async {
        perform(machine.handle(.serverStarting))
        do {
            let token = try await serverManager.ensureReady()
            connect(token: token)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func connect(token: String) {
        statusMessage = "Connecting to local server"
        Task {
            await realtime.connect(
                url: URL(string: "ws://127.0.0.1:8080/v1/realtime")!,
                token: token
            )
        }
    }

    private func beginListening(at date: Date) async {
        guard phase == .idle || phase == .ready else { return }
        guard connectionState == .ready else {
            fail("The local ASR connection is not ready.")
            return
        }
        let granted = await Permissions.requestMicrophone()
        microphonePermission = Permissions.microphone
        guard granted else {
            fail("Microphone permission is required for dictation.")
            return
        }
        if FocusedElementInspector.isAccessibilityTrusted,
           FocusedElementInspector.isSecureFieldFocused() {
            fail("Voice input is disabled in password fields.")
            return
        }

        readyResetTask?.cancel()
        do {
            try await realtime.clearAudio()
            perform(machine.handle(.press(date)))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func perform(_ effects: [SessionEffect]) {
        syncPhase()
        for effect in effects {
            switch effect {
            case .beginCapture:
                beginCapture()
            case .stopAndClear:
                Task { await stopAndClear() }
            case .stopAndCommit:
                Task { await stopAndCommit() }
            case .applyTranscript(let text):
                Task { await applyTranscript(text) }
            case .scheduleReadyReset:
                scheduleReadyReset()
            case .reportError(let message):
                statusMessage = message
            }
        }
    }

    private func syncPhase() {
        phase = machine.phase
        petController?.setState(PetState.from(session: phase))
        switch phase {
        case .startingServer: statusMessage = "Loading local ASR server"
        case .idle: statusMessage = connectionState == .ready ? "Ready" : "Disconnected"
        case .listening: statusMessage = "Listening"
        case .transcribing: statusMessage = "Transcribing"
        case .applying: statusMessage = "Applying transcript"
        case .ready: statusMessage = "Done"
        case .error: break
        }
    }

    private func beginCapture() {
        let sendQueue = AudioSendQueue { [weak realtime] data in
            guard let realtime else { throw RealtimeClientError.disconnected }
            try await realtime.appendAudio(data)
        }
        let pipeline = AudioPipeline(
            sendQueue: sendQueue,
            onFailure: { [weak self] error in
                Task { @MainActor in self?.failActiveSession(error.localizedDescription) }
            },
            onLimitReached: { [weak self] in
                Task { @MainActor in
                    guard let self, self.phase == .listening else { return }
                    self.perform(self.machine.handle(.autoLimitReached))
                }
            }
        )
        audioPipeline = pipeline
        do {
            try recorder.start(
                device: selectedMicrophone,
                onSamples: { [weak pipeline] samples in pipeline?.accept(samples) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.audioLevel = level }
                }
            )
            lastAction = "Recording started"
        } catch {
            pipeline.discard()
            audioPipeline = nil
            fail(error.localizedDescription)
        }
    }

    private func stopAndClear() async {
        recorder.stop()
        audioLevel = 0
        let pipeline = audioPipeline
        pipeline?.discard()
        audioPipeline = nil
        try? await pipeline?.waitUntilIdle()
        try? await realtime.clearAudio()
        stoppingRecording = false
        lastAction = "Recording cancelled"
    }

    private func stopAndCommit() async {
        guard !stoppingRecording else { return }
        stoppingRecording = true
        recorder.stop()
        audioLevel = 0
        do {
            try await audioPipeline?.finish()
            audioPipeline = nil
            try await realtime.commitAudio()
            lastAction = "Audio submitted"
        } catch {
            audioPipeline?.discard()
            audioPipeline = nil
            try? await realtime.clearAudio()
            fail(error.localizedDescription)
        }
        stoppingRecording = false
    }

    private func applyTranscript(_ text: String) async {
        lastTranscript = text
        let result = await PasteController.apply(text)
        lastAction = result == .pasted ? "Pasted transcript" : "Copied transcript"
        perform(machine.handle(.applyCompleted))
    }

    private func scheduleReadyReset() {
        readyResetTask?.cancel()
        readyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.perform(self.machine.handle(.readyExpired))
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeEvent) {
        switch event {
        case .sessionUpdated:
            perform(machine.handle(.serverReady))
        case .transcript(let text):
            guard phase == .transcribing else { return }
            perform(machine.handle(.transcript(text)))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastAction = "No speech recognized"
            }
        case .error(let code, let message):
            failActiveSession("\(code): \(message)")
        case .sessionCreated, .audioCleared, .audioCommitted, .keepalive, .ignored:
            break
        }
    }

    private func handleConnectionState(_ state: RealtimeConnectionState) {
        connectionState = state
        if state == .disconnected,
           phase != .startingServer,
           phase != .error {
            failActiveSession("The local ASR connection was lost.")
        }
    }

    private func failActiveSession(_ message: String) {
        recorder.stop()
        audioLevel = 0
        let pipeline = audioPipeline
        pipeline?.discard()
        audioPipeline = nil
        Task {
            try? await pipeline?.waitUntilIdle()
            try? await realtime.clearAudio()
        }
        fail(message)
    }

    private func fail(_ message: String) {
        perform(machine.handle(.fail(message)))
        lastAction = "Error"
    }

    private func attachPetIfNeeded() {
        guard petController == nil, let root = PetResourceLocator.defaultPetDirectory() else { return }
        do {
            let atlas = try PetManifestLoader.load(petDirectory: root)
            petController = PetPanelController(atlas: atlas) { [weak self] in
                self?.toggleFromPet()
            }
            petController?.setState(PetState.from(session: phase))
        } catch {
            lastAction = "Pet unavailable: \(error.localizedDescription)"
        }
    }
}

enum PetResourceLocator {
    static func defaultPetDirectory() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Pets/default")
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("pet.json").path) {
                return bundled
            }
        }
        return Bundle.module.resourceURL?.appendingPathComponent("Pets/default")
    }
}
