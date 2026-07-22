import AppKit
import ApplicationServices

enum FocusedElementInspector {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func isSecureFieldFocused() -> Bool {
        guard let element = focusedElement() else { return false }
        let role = stringAttribute(kAXRoleAttribute, of: element)?.lowercased() ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)?.lowercased() ?? ""
        let description = stringAttribute(kAXDescriptionAttribute, of: element)?.lowercased() ?? ""
        return role.contains("secure")
            || subrole.contains("secure")
            || subrole.contains("password")
            || description.contains("password")
    }

    static func hasEditableExternalFocus() -> Bool {
        guard isAccessibilityTrusted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement() else { return false }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
        return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
            .contains(role)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
