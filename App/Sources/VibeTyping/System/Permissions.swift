import AppKit
import AVFoundation

enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

enum Permissions {
    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        if microphone == .granted { return true }
        if microphone == .denied { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
