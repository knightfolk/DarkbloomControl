import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let store: MonitorStore
    let navigation: DashboardNavigation
    init(
        store: MonitorStore,
        controlStore: ProviderControlStore?,
        frameAutosaveName: String? = "DarkbloomDashboard",
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        navigation = DashboardNavigation(defaults: defaults)
        let content = NSHostingController(rootView: DashboardRootView(
            store: store, controlStore: controlStore, navigation: navigation
        ))
        let window = NSWindow(contentViewController: content)
        window.title = "Darkbloom Control"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.contentMinSize = NSSize(width: 800, height: 560)
        window.center()
        if let frameAutosaveName { window.setFrameAutosaveName(frameAutosaveName) }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present(section: DashboardDestination? = nil, activate: Bool = true) {
        if let section { navigation.selected = section }
        if activate { showWindow(nil) } else { window?.orderBack(nil) }
        window?.deminiaturize(nil)
        store.setDashboardVisible(true)
        if activate {
            NSApplication.shared.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) { store.setDashboardVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { store.setDashboardVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { store.setDashboardVisible(true) }
}
