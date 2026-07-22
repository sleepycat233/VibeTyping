import Carbon
import Foundation

struct InputSourceSnapshot: Sendable {
    let id: String
}

enum InputSourceManager {
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func isCJKInputSourceActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        let type: String?
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
            type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        } else {
            type = nil
        }
        return isCJK(sourceType: type, sourceID: currentID())
    }

    static func isCJK(sourceType: String?, sourceID: String?) -> Bool {
        if sourceType == kTISTypeKeyboardInputMode as String { return true }
        guard let sourceID else { return false }
        return [
            "com.apple.inputmethod.TCIM",
            "com.apple.inputmethod.SCIM",
            "com.apple.inputmethod.Japanese",
            "com.apple.inputmethod.Korean",
        ].contains { sourceID.hasPrefix($0) }
    }

    static func switchToASCIIIfNeeded() -> InputSourceSnapshot? {
        guard isCJKInputSourceActive(), let previous = currentID() else { return nil }
        let criteria: [String: Any] = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceIsASCIICapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true,
        ]
        guard let sources = TISCreateInputSourceList(criteria as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
              let ascii = sources.first,
              TISSelectInputSource(ascii) == noErr else { return nil }
        return InputSourceSnapshot(id: previous)
    }

    static func restore(_ snapshot: InputSourceSnapshot) {
        let criteria = [kTISPropertyInputSourceID as String: snapshot.id]
        guard let sources = TISCreateInputSourceList(criteria as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return }
        _ = TISSelectInputSource(source)
    }
}
