import AppKit
import SwiftUI

@main
struct VibeTypingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarIconName)
                .onAppear { appDelegate.configure(model: model) }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private let hotKeys = HotKeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func configure(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        do {
            try hotKeys.registerPushToTalk(
                onPressed: { [weak model] in model?.pushToTalkPressed() },
                onReleased: { [weak model] in model?.pushToTalkReleased() }
            )
        } catch {
            // The menu remains available even if another app owns the shortcut.
        }
        model.start()
    }
}
