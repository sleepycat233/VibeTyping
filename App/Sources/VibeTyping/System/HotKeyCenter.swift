import Carbon
import Foundation

private func remoteASRHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let kind = GetEventKind(event)
    DispatchQueue.main.async {
        HotKeyCenter.invoke(id: hotKeyID.id, eventKind: kind)
    }
    return noErr
}

private struct HotKeyHandlers {
    let pressed: () -> Void
    let released: () -> Void
}

final class HotKeyCenter {
    private static var handlerInstalled = false
    private static var handlers: [UInt32: HotKeyHandlers] = [:]
    private static var pressedIDs = Set<UInt32>()
    private var references: [EventHotKeyRef] = []

    func registerPushToTalk(onPressed: @escaping () -> Void, onReleased: @escaping () -> Void) throws {
        Self.installHandlerIfNeeded()
        let id: UInt32 = 1
        Self.handlers[id] = HotKeyHandlers(pressed: onPressed, released: onReleased)
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("RASR"), id: id)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(status)
        }
        references.append(reference)
    }

    deinit {
        references.forEach { UnregisterEventHotKey($0) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        _ = eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                remoteASRHotKeyHandler,
                buffer.count,
                buffer.baseAddress,
                nil,
                nil
            )
        }
    }

    fileprivate static func invoke(id: UInt32, eventKind: UInt32) {
        guard let handlers = handlers[id] else { return }
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard pressedIDs.insert(id).inserted else { return }
            handlers.pressed()
        case UInt32(kEventHotKeyReleased):
            pressedIDs.remove(id)
            handlers.released()
        default:
            break
        }
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.unicodeScalars.prefix(4).reduce(0) { ($0 << 8) + OSType($1.value) }
    }
}

enum HotKeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status): "Could not register Control+Option+Space (\(status))."
        }
    }
}
