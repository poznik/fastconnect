import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let appState: AppState
    private let hostingController: NSHostingController<SettingsView>

    init(appState: AppState) {
        self.appState = appState
        self.hostingController = NSHostingController(
            rootView: SettingsView(appState: appState, initialConfiguration: appState.currentConfiguration)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Настройки FastConnect"
        window.setContentSize(NSSize(width: 520, height: 380))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        hostingController.rootView = SettingsView(appState: appState, initialConfiguration: appState.currentConfiguration)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
