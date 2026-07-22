import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.statusMessage, systemImage: model.menuBarIconName)
                    .font(.headline)
                Spacer()
                if model.phase == .startingServer || model.connectionState == .connecting {
                    ProgressView().controlSize(.small)
                }
            }

            HStack {
                Button {
                    model.phase == .listening ? model.pushToTalkReleased() : model.pushToTalkPressed()
                } label: {
                    Label(
                        model.phase == .listening ? "Stop" : "Dictate",
                        systemImage: model.phase == .listening ? "stop.fill" : "mic.fill"
                    )
                }
                .disabled(![SessionPhase.idle, .ready, .listening].contains(model.phase))

                Button { model.copyLastTranscript() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.lastTranscript.isEmpty)
            }

            if !model.lastTranscript.isEmpty {
                Divider()
                ScrollView {
                    Text(model.lastTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Microphone").font(.caption).foregroundStyle(.secondary)
                Picker("Microphone", selection: $model.selectedMicrophoneUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(model.microphones) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .onAppear { model.refreshMicrophones() }
            }

            permissionSection

            Divider()
            Toggle("Show desktop companion", isOn: Binding(
                get: { model.petVisible },
                set: { model.setPetVisible($0) }
            ))
            Button { model.resetPetPosition() } label: {
                Label("Reset companion position", systemImage: "arrow.counterclockwise")
            }

            Divider()
            serverSection

            if !model.lastAction.isEmpty {
                Text(model.lastAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Hold Control+Option+Space to dictate")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Button("Quit VibeTyping") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    @ViewBuilder
    private var permissionSection: some View {
        if !FocusedElementInspector.isAccessibilityTrusted || model.microphonePermission != .granted {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if !FocusedElementInspector.isAccessibilityTrusted {
                    Button { model.requestAccessibility() } label: {
                        Label("Enable paste permission", systemImage: "accessibility")
                    }
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                        .buttonStyle(.link)
                    Text("Without Accessibility permission, transcripts are copied only. Restart after granting access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.microphonePermission == .denied {
                    Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Local server").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(serverStatusText).font(.caption.monospacedDigit())
            }
            Button { model.restartServer() } label: {
                Label("Restart local server", systemImage: "arrow.clockwise")
            }
            if let line = model.serverManager.recentLogs.last {
                Text(line)
                    .lineLimit(2)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverStatusText: String {
        switch model.serverManager.status {
        case .stopped: "Stopped"
        case .checking: "Checking"
        case .loading: "Loading"
        case .ready(let pid, let owned):
            if let pid { owned ? "Ready · PID \(pid)" : "Ready · PID \(pid)" }
            else { "Ready · external" }
        case .failed: "Failed"
        }
    }
}
