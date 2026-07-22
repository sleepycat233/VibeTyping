import AppKit
import ApplicationServices

enum PasteResult: Equatable, Sendable {
    case pasted
    case copiedOnly
}

@MainActor
enum PasteController {
    static func apply(_ text: String) async -> PasteResult {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard FocusedElementInspector.hasEditableExternalFocus() else { return .copiedOnly }

        let inputSource = InputSourceManager.switchToASCIIIfNeeded()
        if inputSource != nil { try? await Task.sleep(for: .milliseconds(100)) }
        postCommandV()
        if let inputSource {
            try? await Task.sleep(for: .milliseconds(500))
            InputSourceManager.restore(inputSource)
        }
        return .pasted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
