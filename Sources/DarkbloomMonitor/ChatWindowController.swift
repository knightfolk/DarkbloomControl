import AppKit
import SwiftUI

/// Retained, resizable pop-out chat window. It hosts the same `ChatStore` as
/// the dashboard's Chat tab, so both windows show the identical in-memory
/// conversation and either can send on it.
@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private let store: ChatStore
    private let frameAutosaveName: String?

    init(
        store: ChatStore,
        frameAutosaveName: String? = "DarkbloomChatPopOut",
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.frameAutosaveName = frameAutosaveName
        let content = NSHostingController(rootView: ChatView(store: store))
        let window = NSWindow(contentViewController: content)
        window.title = "\(MonitorApplicationIdentity.displayName) — Chat"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 680))
        window.contentMinSize = NSSize(width: 460, height: 520)
        window.center()
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
        }
        super.init(window: window)
        window.delegate = self
        constrainToVisibleScreen()
    }

    required init?(coder: NSCoder) { nil }

    func present(activate: Bool = true) {
        if activate {
            showWindow(nil)
            NSApplication.shared.activate()
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderBack(nil)
        }
        constrainToVisibleScreen()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        constrainToVisibleScreen()
    }

    private func constrainToVisibleScreen() {
        guard let window,
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let visibleFrame = screen.visibleFrame
        let fitted = DashboardWindowSizing.fitted(window.frame, within: visibleFrame)
        if fitted != window.frame {
            window.setFrame(fitted, display: true)
        }
        if let frameAutosaveName {
            window.saveFrame(usingName: frameAutosaveName)
        }
    }
}
