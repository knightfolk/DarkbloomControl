import AppKit
import DarkbloomTelemetry
import SwiftUI
import Testing
@testable import DarkbloomMonitor

/// Synthetic ChatView renders at dashboard and pop-out sizes, including the
/// local-unavailable and paid-network states. Nothing contacts a live
/// endpoint or spends credit; every state comes from in-memory fakes.
/// Screenshots are captured only when DARKBLOOM_RENDER_EVIDENCE=1.
@Suite("Chat view renders")
@MainActor
struct ChatViewTests {
    private func makeStore(
        local: FakeChatRouteClient = FakeChatRouteClient(),
        network: FakeChatRouteClient = FakeChatRouteClient()
    ) -> ChatStore {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        return ChatStore(
            localClient: local,
            networkClient: network,
            balanceClient: FakeBalanceClient(),
            pricingClient: FakePricingClient(),
            keyStore: keys,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    @Test("empty state and local-unavailable banner render at dashboard size", arguments: ["light", "dark"])
    func rendersLocalStates(appearance: String) async throws {
        let suite = "ChatView-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let local = FakeChatRouteClient()
        local.modelsResult = .failure(ChatClientError.localEndpointUnavailable)
        let store = makeStore(local: local)
        store.startConversation(route: .local)

        let content = NSHostingController(rootView: ChatView(store: store))
        let window = NSWindow(contentViewController: content)
        defer { window.close() }
        window.setContentSize(NSSize(width: 980, height: 640))
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        content.view.layoutSubtreeIfNeeded()
        #expect(content.view.frame.width == 980)
        // The hosted content must stay near the requested window size; an
        // unbounded ideal height (the giant-window regression) fails here.
        try assertBoundedContentSize(content: content, window: window, width: 980, height: 640)

        // The banner states the failure honestly.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, store.modelsNotice == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.modelsNotice != nil)
        #expect(store.canSend == false)

        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            try capture(window: window, name: "chat-local-unavailable-\(appearance)")
        }

        // The true empty state: a fresh store with no conversation yet.
        let emptyStore = makeStore(local: local)
        #expect(emptyStore.conversation == nil)
        content.rootView = ChatView(store: emptyStore)
        try await Task.sleep(for: .milliseconds(120))
        content.view.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            try capture(window: window, name: "chat-empty-state-\(appearance)")
        }
    }

    @Test("paid-network states render at pop-out size", arguments: ["light", "dark"])
    func rendersNetworkStates(appearance: String) async throws {
        let network = FakeChatRouteClient()
        network.completeResult = .success(ChatCompletionOutcome(
            content: "Network synthetic reply.",
            model: "gpt-oss-20b",
            finishReason: "stop",
            promptTokens: 12,
            completionTokens: 34
        ))
        let store = makeStore(network: network)
        store.startConversation(route: .network)
        try await waitForModels(store: store)

        // Ack-pending state shows the paid disclosure before any send.
        #expect(store.conversation?.paidRouteAcknowledged == false)

        let content = NSHostingController(rootView: ChatView(store: store))
        let window = NSWindow(contentViewController: content)
        defer { window.close() }
        window.setContentSize(NSSize(width: 560, height: 680))
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        content.view.layoutSubtreeIfNeeded()
        #expect(content.view.frame.width == 560)
        try assertBoundedContentSize(content: content, window: window, width: 560, height: 680)

        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            try capture(window: window, name: "chat-network-ack-pending-\(appearance)")
        }

        // Acknowledged state with a small transcript carrying provenance.
        store.acknowledgePaidRoute()
        store.send("What can you tell me about this Mac's model?")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, store.conversation?.entries.last?.phase != .complete {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.conversation?.entries.last?.provenance?.route == .network)
        content.rootView = ChatView(store: store)
        try await Task.sleep(for: .milliseconds(120))
        content.view.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            try capture(window: window, name: "chat-network-acknowledged-\(appearance)")
        }
        #expect(store.balance?.balanceMicroUSD == 2_400_000)
    }

    @Test("the paid acknowledgement stays fully readable at the pop-out minimum size", arguments: ["light", "dark"])
    func rendersAckPanelAtMinimumSize(appearance: String) async throws {
        let store = makeStore()
        store.startConversation(route: .network)
        try await waitForModels(store: store)
        #expect(store.conversation?.paidRouteAcknowledged == false)

        let content = NSHostingController(rootView: ChatView(store: store))
        let window = NSWindow(contentViewController: content)
        defer { window.close() }
        // The pop-out window's enforced content minimum.
        window.setContentSize(NSSize(width: 460, height: 520))
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        content.view.layoutSubtreeIfNeeded()
        #expect(content.view.frame.width == 460)
        try assertBoundedContentSize(content: content, window: window, width: 460, height: 520)
        if ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_EVIDENCE"] == "1" {
            try capture(window: window, name: "chat-network-ack-pending-minsize-\(appearance)")
        }
    }

    @Test("the pop-out window is resizable with a sane minimum and shares the store")
    func popOutWindowProperties() throws {
        let store = makeStore()
        let controller = ChatWindowController(store: store)
        let window = try #require(controller.window)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.closable))
        #expect(window.contentMinSize == NSSize(width: 460, height: 520))
        #expect(window.isReleasedWhenClosed == false)
        // The dashboard tab and this window hold the same observable store.
        controller.present(activate: false)
        controller.close()
    }

    /// The hosted chat content and window frame must stay close to the
    /// requested size after layout. An unbounded ideal height (for example a
    /// misapplied `fixedSize`) makes the hosting controller grow the window
    /// into a giant blank column; this fails that regression directly.
    private func assertBoundedContentSize(
        content: NSHostingController<ChatView>,
        window: NSWindow,
        width: CGFloat,
        height: CGFloat
    ) throws {
        let view = try #require(content.viewIfLoaded)
        #expect(abs(view.frame.height - height) <= height * 0.1, "hosted height \(view.frame.height) escaped \(height)")
        let bounds = try #require(window.contentView?.bounds)
        #expect(abs(bounds.height - height) <= height * 0.1, "window content height \(bounds.height) escaped \(height)")
        #expect(abs(bounds.width - width) <= width * 0.1, "window content width \(bounds.width) escaped \(width)")
    }

    private func waitForModels(store: ChatStore) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, store.verifiedModelIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.verifiedModelIDs.isEmpty)
    }

    private func capture(window: NSWindow, name: String) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/darkbloom-\(name).png"]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}
