import AppKit
import DarkbloomTelemetry
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    static let itemWidth: CGFloat = 104

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private(set) var dashboardWindowController: DashboardWindowController?
    private let store: MonitorStore
    private let defaults: UserDefaults
    private(set) var controlStore: ProviderControlStore?

    var statusItemLength: CGFloat { statusItem.length }
    var popoverContentSize: NSSize { popover.contentSize }

    init(store: MonitorStore, controlStore: ProviderControlStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        statusItem = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        self.controlStore = controlStore
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
        popover.contentSize = NSSize(width: 420, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                store: store,
                controlStore: controlStore,
                openSettings: { [weak self] in self?.showSettings() },
                openDashboard: { [weak self] in self?.showDashboard() }
            )
        )
    }

    func invalidate() {
        popover.performClose(nil)
        dashboardWindowController?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let controlStore = self.controlStore
            Task { @MainActor [weak controlStore] in
                await controlStore?.refreshPreservingDraft()
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func showDashboard(section: DashboardDestination? = nil, activate: Bool = true) {
        popover.performClose(nil)
        if dashboardWindowController == nil {
            dashboardWindowController = DashboardWindowController(
                store: store, controlStore: controlStore, defaults: defaults
            )
        }
        dashboardWindowController?.present(section: section, activate: activate)
    }

    func showSettings(activate: Bool = true) {
        showDashboard(section: .settings, activate: activate)
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct StatusItemRootView: View {
    @ObservedObject var store: MonitorStore
    @AppStorage("menuBarDisplayMode") private var displayModeRaw = MenuBarDisplayMode.automatic.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            MenuBarLabel(
                presentation: store.menuPresentation(mode: displayMode),
                uptime: store.observedUptime,
                family: ModelFamilyIcon.select(snapshot: store.snapshot, now: Date())
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayMode: MenuBarDisplayMode {
        MenuBarDisplayMode(rawValue: displayModeRaw) ?? .automatic
    }
}

private struct PopoverRootView: View {
    @ObservedObject var store: MonitorStore
    let controlStore: ProviderControlStore?
    let openSettings: () -> Void
    let openDashboard: () -> Void

    @ViewBuilder
    var body: some View {
        if let controlStore {
            MonitorPopover(store: store, openSettings: openSettings, openDashboard: openDashboard)
                .environmentObject(controlStore)
        } else {
            MonitorPopover(store: store, openSettings: openSettings, openDashboard: openDashboard)
        }
    }
}
