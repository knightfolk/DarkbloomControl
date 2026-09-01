import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    static let itemWidth: CGFloat = 132

    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    var statusItemLength: CGFloat { statusItem.length }

    init(store: MonitorStore) {
        statusItem = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
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
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.contentViewController = NSHostingController(rootView: PopoverRootView(store: store))
    }

    func invalidate() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
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
    @AppStorage("menuBarDisplayMode") private var displayModeRaw = MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        MonitorPopover(store: store, displayMode: displayModeBinding)
    }

    private var displayMode: MenuBarDisplayMode {
        MenuBarDisplayMode(rawValue: displayModeRaw) ?? .automatic
    }

    private var displayModeBinding: Binding<MenuBarDisplayMode> {
        Binding(get: { displayMode }, set: { displayModeRaw = $0.rawValue })
    }
}
