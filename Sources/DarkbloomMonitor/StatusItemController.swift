import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    static let itemWidth: CGFloat = 132

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settingsWindowController: NSWindowController

    var statusItemLength: CGFloat { statusItem.length }
    var settingsWindowTitle: String? { settingsWindowController.window?.title }
    var settingsWindowIsReleasedWhenClosed: Bool? {
        settingsWindowController.window?.isReleasedWhenClosed
    }

    init(store: MonitorStore) {
        statusItem = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        let settingsViewController = NSHostingController(rootView: MonitorSettingsView())
        let settingsWindow = NSWindow(contentViewController: settingsViewController)
        settingsWindow.title = "Darkbloom Monitor Settings"
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable]
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.setContentSize(NSSize(width: 420, height: 180))
        settingsWindow.center()
        settingsWindowController = NSWindowController(window: settingsWindow)
        super.init()

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])

        let hostingView = PassthroughHostingView(rootView: StatusItemRootView(store: store))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                openSettings: { [weak self] in self?.showSettings() }
            )
        )
    }

    func invalidate() {
        popover.performClose(nil)
        settingsWindowController.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        settingsWindowController.showWindow(nil)
        NSApplication.shared.activate()
        settingsWindowController.window?.orderFrontRegardless()
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct StatusItemRootView: View {
    @ObservedObject var store: MonitorStore
    @AppStorage("menuBarDisplayMode") private var displayModeRaw = MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        MenuBarLabel(
            presentation: store.menuPresentation(mode: displayMode),
            uptime: store.observedUptime
        )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayMode: MenuBarDisplayMode {
        MenuBarDisplayMode(rawValue: displayModeRaw) ?? .automatic
    }
}

private struct PopoverRootView: View {
    @ObservedObject var store: MonitorStore
    let openSettings: () -> Void

    var body: some View {
        MonitorPopover(store: store, openSettings: openSettings)
    }
}
