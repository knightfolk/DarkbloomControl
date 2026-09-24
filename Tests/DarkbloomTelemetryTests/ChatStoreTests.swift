import Foundation
import Testing
@testable import DarkbloomMonitor
@testable import DarkbloomTelemetry

/// Store-level gating, route-locking, provenance, cancellation and race
/// tests for the shared chat store. All clients are in-memory fakes; no
/// endpoint is contacted and no paid inference occurs.
@Suite("Chat store")
@MainActor
struct ChatStoreTests {
    private let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))

    private func makeStore(
        local: FakeChatRouteClient = FakeChatRouteClient(),
        network: FakeChatRouteClient = FakeChatRouteClient(),
        balance: FakeBalanceClient = FakeBalanceClient(),
        pricing: FakePricingClient = FakePricingClient(),
        keys: FakeConsumerKeyStore = FakeConsumerKeyStore()
    ) -> ChatStore {
        ChatStore(
            localClient: local,
            networkClient: network,
            balanceClient: balance,
            pricingClient: pricing,
            keyStore: keys,
            now: { [clock] in clock.date }
        )
    }

    /// Polls the main actor until the condition holds. The budget is
    /// deliberately generous: under the full suite's parallel scheduling
    /// bursts a three-second window flaked even though every condition here
    /// completes in milliseconds when the actor is free.
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for condition")
    }

    // MARK: Route locking and no fallback

    @Test("model verification expiring by time rejects the send and reports it")
    func staleVerificationRejectsSend() async {
        let local = FakeChatRouteClient()
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }

        // The verified list goes stale purely by time: nothing is published,
        // so the UI may still look sendable. The store must refuse the turn
        // and tell the caller, which keeps the user's draft.
        clock.advance(ChatStore.modelsFreshnessWindow + 1)
        #expect(store.canSend == false)
        let accepted = store.send("must not be silently dropped")
        #expect(accepted == false)
        #expect(local.completeCalls.isEmpty)
        #expect(store.conversation?.entries.isEmpty == true)
        #expect(store.isSending == false)

        // A fresh synthetic verification under the advanced clock restores
        // sending; the rejected draft text was never transmitted or recorded.
        local.modelsResult = .success(ChatModelListSnapshot(
            modelIDs: ["gpt-oss-20b", "gemma-4-26b-qat-4bit"],
            capturedAt: clock.date
        ))
        await store.refreshModels()
        await waitUntil { store.canSend }
        #expect(store.send("accepted turn") == true)
        await waitUntil { local.completeCalls.count == 1 && store.conversation?.entries.last?.phase == .complete }
        #expect(local.completeCalls.first?.map(\.content) == ["accepted turn"])
    }

    @Test("a conversation's route is immutable; a new chat never inherits the old transcript")
    func routeLockAndTranscriptIsolation() async {
        let local = FakeChatRouteClient()
        let network = FakeChatRouteClient()
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let store = makeStore(local: local, network: network, keys: keys)

        store.startConversation(route: .local)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.send("local only secret")
        await waitUntil { store.conversation?.entries.last?.phase == .complete }

        // Switching requires a new chat, and the new network conversation
        // starts empty: the local transcript is not re-sent anywhere.
        store.startConversation(route: .network)
        #expect(store.conversation?.route == .network)
        #expect(store.conversation?.entries.isEmpty == true)
        #expect(network.completeCalls.isEmpty)

        store.acknowledgePaidRoute()
        await waitUntil { store.selectedModelID != nil }
        store.send("network question")
        await waitUntil { !network.completeCalls.isEmpty }
        let history = network.completeCalls.last ?? []
        #expect(history.map(\.content) == ["network question"])
        #expect(!history.contains { $0.content.contains("local only secret") })
    }

    @Test("local unavailability stops sending; nothing silently falls back to the network")
    func noFallbackFromLocal() async {
        let local = FakeChatRouteClient()
        local.modelsResult = .failure(ChatClientError.localEndpointUnavailable)
        let network = FakeChatRouteClient()
        let store = makeStore(local: local, network: network)

        store.startConversation(route: .local)
        await waitUntil { store.modelsNotice != nil }
        #expect(store.canSend == false)
        store.send("will not send")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(local.completeCalls.isEmpty)
        #expect(network.completeCalls.isEmpty)
        #expect(store.conversation?.entries.isEmpty == true)
        #expect(store.modelsNotice?.contains("local") == true)
    }

    @Test("switching from paid network to local also requires an explicit new empty chat")
    func noFallbackFromNetwork() async {
        let network = FakeChatRouteClient()
        let store = makeStore(network: network)
        network.modelsResult = .failure(ChatClientError.missingConsumerKey)

        store.startConversation(route: .network)
        await waitUntil { store.modelsNotice != nil }
        store.startConversation(route: .local)
        #expect(store.conversation?.entries.isEmpty == true)
        #expect(store.conversation?.paidRouteAcknowledged == false)
    }

    // MARK: Network gating matrix (fail closed)

    @Test("paid-route acknowledgement is required before any network send")
    func acknowledgementGate() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let network = FakeChatRouteClient()
        let store = makeStore(network: network, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        #expect(store.conversation?.paidRouteAcknowledged == false)
        #expect(store.canSend == false)
        store.send("not yet")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(network.completeCalls.isEmpty)

        store.acknowledgePaidRoute()
        #expect(store.canSend == true)
    }

    @Test("missing consumer key keeps the network send disabled at the button")
    func missingKeyGate() async {
        let network = FakeChatRouteClient()
        let store = makeStore(network: network)

        store.startConversation(route: .network)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.acknowledgePaidRoute()
        #expect(store.consumerKeyPresent == false)
        #expect(store.canSend == false)
        store.send("needs a key")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(network.completeCalls.isEmpty)
        #expect(store.conversation?.entries.isEmpty == true)
    }

    @Test("zero balance and balance failures stop the send with distinct fixed messages")
    func balanceGates() async {
        for (balance, expectedNeedle) in [
            (Int64(0), "balance is zero"),
            (Int64(-1) /* fake forces fetch failure */, "balance could not be verified"),
        ] {
            let keys = FakeConsumerKeyStore()
            keys.inject("dk-synthetic-consumer")
            let balanceClient = FakeBalanceClient()
            if balance >= 0 {
                balanceClient.balance = balance
            } else {
                balanceClient.result = .failure(URLError(.notConnectedToInternet))
            }
            let network = FakeChatRouteClient()
            let store = makeStore(network: network, balance: balanceClient, keys: keys)

            store.startConversation(route: .network)
            await waitUntil { !store.verifiedModelIDs.isEmpty }
            store.acknowledgePaidRoute()
            store.send("gated")
            await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
            #expect(network.completeCalls.isEmpty)
            #expect(store.conversation?.entries.last?.failureMessage?.contains(expectedNeedle) == true)
        }
    }

    @Test("a stale balance snapshot from a fetch fails closed even when the fetch succeeds")
    func staleBalanceGate() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let balance = FakeBalanceClient()
        balance.capturedAtOffset = ConsumerBalanceSnapshot.maximumAge + 10
        let network = FakeChatRouteClient()
        let store = makeStore(network: network, balance: balance, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.acknowledgePaidRoute()
        store.send("stale")
        await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
        #expect(network.completeCalls.isEmpty)
        #expect(store.conversation?.entries.last?.failureMessage?.contains("not current") == true)
    }

    @Test("stale or unavailable pricing stops the send; unknown model pricing stops it too")
    func pricingGates() async {
        // Unavailable pricing: the fetch itself fails while stale.
        do {
            let keys = FakeConsumerKeyStore()
            keys.inject("dk-synthetic-consumer")
            let pricing = FakePricingClient()
            pricing.result = .failure(PublicPricingError.httpStatus(503))
            let network = FakeChatRouteClient()
            let store = makeStore(network: network, pricing: pricing, keys: keys)
            store.startConversation(route: .network)
            await waitUntil { !store.verifiedModelIDs.isEmpty }
            store.acknowledgePaidRoute()
            store.send("needs pricing")
            await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
            #expect(network.completeCalls.isEmpty)
            #expect(store.conversation?.entries.last?.failureMessage == ChatSendBlocked.pricingUnavailable.message)
        }

        // Pricing that does not list the selected model.
        do {
            let keys = FakeConsumerKeyStore()
            keys.inject("dk-synthetic-consumer")
            let pricing = FakePricingClient(prices: ["some-other-model"])
            let network = FakeChatRouteClient()
            let store = makeStore(network: network, pricing: pricing, keys: keys)
            store.startConversation(route: .network)
            await waitUntil { !store.verifiedModelIDs.isEmpty }
            store.acknowledgePaidRoute()
            store.send("unknown price")
            await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
            #expect(network.completeCalls.isEmpty)
            #expect(store.conversation?.entries.last?.failureMessage == ChatSendBlocked.unknownPricing("gpt-oss-20b").message)
        }
    }

    @Test("a 402 from the network is final: one request, no retry, authoritative message")
    func paymentRequiredIsFinal() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let network = FakeChatRouteClient()
        network.completeResult = .failure(ChatClientError.paymentRequired)
        let store = makeStore(network: network, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.acknowledgePaidRoute()
        store.send("charge me")
        await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
        #expect(network.completeCalls.count == 1)
        #expect(store.conversation?.entries.last?.failureMessage == ChatClientError.paymentRequired.errorDescription)
        #expect(store.notice == ChatClientError.paymentRequired.errorDescription)
    }

    @Test("network 401 surfaces the key-specific rejection")
    func keyRejectionMessage() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let network = FakeChatRouteClient()
        network.completeResult = .failure(ChatClientError.consumerKeyRejected)
        let store = makeStore(network: network, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.acknowledgePaidRoute()
        store.send("hello")
        await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
        #expect(network.completeCalls.count == 1)
        #expect(store.conversation?.entries.last?.failureMessage == ChatClientError.consumerKeyRejected.errorDescription)
    }

    // MARK: Provenance and multi-turn history

    @Test("provenance names the model that actually served the response")
    func provenanceUsesResponseModel() async {
        let local = FakeChatRouteClient()
        local.completeResult = .success(ChatCompletionOutcome(
            content: "served elsewhere",
            model: "gemma-4-26b-qat-4bit",
            finishReason: "stop"
        ))
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID == "gpt-oss-20b" }
        store.send("which model are you?")
        await waitUntil { store.conversation?.entries.last?.phase == .complete }
        #expect(store.conversation?.entries.last?.provenance?.modelID == "gemma-4-26b-qat-4bit")
        // Fallback: a response without a model keeps the requested ID.
        local.completeResult = .success(ChatCompletionOutcome(content: "anonymous", model: nil))
        store.send("and now?")
        await waitUntil { local.completeCalls.count == 2 && store.conversation?.entries.last?.phase == .complete }
        #expect(store.conversation?.entries.last?.provenance?.modelID == "gpt-oss-20b")
    }

    @Test("an in-flight verification or balance read under an old key cannot repopulate readiness")
    func keyChangeDuringInFlightReads() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer-old")
        let network = FakeChatRouteClient()
        let balance = FakeBalanceClient()
        balance.suspend = true
        let store = makeStore(network: network, balance: balance, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { balance.pendingReleases > 0 }

        // The key is replaced while the balance read is suspended.
        #expect(store.storeConsumerKey("dk-synthetic-consumer-new") == nil)
        #expect(store.networkModels == nil)

        // The old-key read completes successfully — and is discarded.
        balance.release(.success(ConsumerBalanceSnapshot(balanceMicroUSD: 5_000_000, capturedAt: clock.date)))
        await waitUntil { balance.pendingReleases == 0 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.networkModels == nil)
        #expect(store.balance == nil)
        #expect(store.selectedModelID == nil)
    }

    @Test("multi-turn history accumulates on the fixed route")
    func multiTurnHistory() async {
        let local = FakeChatRouteClient()
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }
        store.send("first")
        await waitUntil { local.completeCalls.count == 1 && store.conversation?.entries.last?.phase == .complete }
        store.send("second")
        await waitUntil { local.completeCalls.count == 2 }
        let history = local.completeCalls.last ?? []
        #expect(history.map(\.role) == [.user, .assistant, .user])
        #expect(history.map(\.content) == ["first", "Local synthetic reply.", "second"])
    }

    // MARK: Duplicate sends and cancellation

    @Test("a second send while one is in flight is ignored")
    func duplicateSendIgnored() async {
        let local = FakeChatRouteClient()
        local.suspendComplete = true
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.send("first")
        await waitUntil { store.isSending }
        store.send("duplicate")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(local.completeCalls.count == 1)
        local.release(.success(ChatCompletionOutcome(content: "done", model: "gpt-oss-20b")))
        await waitUntil { !store.isSending }
        #expect(store.conversation?.entries.count == 2)
    }

    @Test("cancellation records an honest maybe-delivered state")
    func cancelHonesty() async {
        let local = FakeChatRouteClient()
        local.suspendComplete = true
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }
        store.send("cancel me")
        await waitUntil { store.isSending }
        store.cancelSend()
        await waitUntil { store.conversation?.entries.last?.phase == .cancelled }
        #expect(store.notice?.contains("may already have been delivered") == true)
        #expect(store.isSending == false)
    }

    @Test("a cancelled predecessor send cannot disturb a newer send")
    func cancelThenSendRace() async {
        let local = FakeChatRouteClient()
        local.suspendComplete = true
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }
        store.send("old")
        // Wait until the old client call is genuinely in flight; cancelling
        // earlier could prevent it from ever starting.
        await waitUntil { local.completeCalls.count == 1 && local.pendingReleases == 1 }
        store.cancelSend()
        #expect(store.conversation?.entries.last?.phase == .cancelled)
        #expect(store.isSending == false)

        store.send("new")
        await waitUntil { local.completeCalls.count == 2 && local.pendingReleases == 2 }
        // Both client calls end now: the older, cancellation-ignoring one
        // errors, the newer one succeeds. The old must not overwrite its
        // cancelled entry or the new send's state.
        local.releaseInOrder([
            .failure(CancellationError()),
            .success(ChatCompletionOutcome(content: "Local synthetic reply.", model: "gpt-oss-20b")),
        ])
        await waitUntil { store.conversation?.entries.last?.phase == .complete && store.isSending == false }
        #expect(store.conversation?.entries.last?.text == "Local synthetic reply.")
        let cancelled = store.conversation?.entries.first { $0.phase == .cancelled }
        #expect(cancelled != nil)
    }

    @Test("cancelling before the send task starts still finalizes the placeholder")
    func immediateCancelFinalizes() async {
        let local = FakeChatRouteClient()
        local.suspendComplete = true
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }
        store.send("immediate")
        // No yield: the task may not have started when we cancel.
        store.cancelSend()
        #expect(store.isSending == false)
        #expect(store.conversation?.entries.last?.phase == .cancelled)
        #expect(store.notice?.contains("may already have been delivered") == true)
        local.release(.failure(CancellationError()))
        await waitUntil { !store.isSending }
        #expect(store.conversation?.entries.last?.phase == .cancelled)
    }

    // MARK: Route-change races

    @Test("a send finishing after a new chat never mutates the new conversation")
    func newChatDuringInFlightSend() async {
        let local = FakeChatRouteClient()
        local.suspendComplete = true
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.send("old chat")
        await waitUntil { store.isSending }

        store.startConversation(route: .network)
        #expect(store.isSending == false)
        #expect(store.conversation?.entries.isEmpty == true)

        local.release(.success(ChatCompletionOutcome(content: "late reply", model: "gpt-oss-20b")))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.conversation?.entries.isEmpty == true)
        #expect(store.isSending == false)
    }

    @Test("a network preflight interrupted by a new chat never issues the paid request")
    func newChatDuringNetworkPreflight() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let balance = FakeBalanceClient()
        balance.suspend = true
        let network = FakeChatRouteClient()
        let store = makeStore(network: network, balance: balance, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { !store.verifiedModelIDs.isEmpty }
        store.acknowledgePaidRoute()
        store.send("interrupted")
        await waitUntil { balance.pendingReleases > 0 }

        store.startConversation(route: .local)
        balance.release(.success(ConsumerBalanceSnapshot(balanceMicroUSD: 1_000_000, capturedAt: clock.date)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(network.completeCalls.isEmpty)
        #expect(store.isSending == false)
    }

    @Test("an old conversation's model refresh cannot replace a newer sample or re-select its models")
    func staleRefreshDoesNotReselect() async {
        let local = FakeChatRouteClient()
        local.suspendModels = true
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { local.pendingModelReleases > 0 }

        local.suspendModels = false
        local.modelsResult = .success(ChatModelListSnapshot(modelIDs: ["new-model"], capturedAt: clock.date))
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID == "new-model" }

        // The first conversation's suspended refresh completes with an older
        // sample; it must not replace the newer list or its selection.
        local.releaseModels(.success(ChatModelListSnapshot(
            modelIDs: ["old-model"],
            capturedAt: clock.date.addingTimeInterval(-60)
        )))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.selectedModelID == "new-model")
        #expect(store.verifiedModelIDs == ["new-model"])
    }

    // MARK: Model selection honesty

    @Test("only verified models are selectable and the first is auto-selected")
    func modelSelection() async {
        let local = FakeChatRouteClient()
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID == "gpt-oss-20b" }
        store.selectModel("not-verified")
        #expect(store.selectedModelID == "gpt-oss-20b")
        store.selectModel("gemma-4-26b-qat-4bit")
        #expect(store.selectedModelID == "gemma-4-26b-qat-4bit")
    }

    // MARK: Consumer key lifecycle

    @Test("a draft can only be sent to the conversation it was written in")
    func draftPolicy() {
        let first = UUID()
        let second = UUID()
        // No conversation: never sendable.
        #expect(ChatDraftPolicy.canSend(draft: "hi", draftConversationID: first, activeConversationID: nil) == false)
        // Blank drafts never send.
        #expect(ChatDraftPolicy.canSend(draft: "  ", draftConversationID: first, activeConversationID: first) == false)
        // An unstamped draft is not sendable: ownership must be exact and
        // non-nil, so the guard cannot be defeated before onChange runs.
        #expect(ChatDraftPolicy.canSend(draft: "hi", draftConversationID: nil, activeConversationID: first) == false)
        // Same conversation: sendable.
        #expect(ChatDraftPolicy.canSend(draft: "hi", draftConversationID: first, activeConversationID: first) == true)
        // The deciding case: a draft from a previous conversation must not
        // send to a new one, even before SwiftUI's onChange clears it.
        #expect(ChatDraftPolicy.canSend(draft: "local secret", draftConversationID: first, activeConversationID: second) == false)
    }

    @Test("a failed turn's prompt is kept visibly but never retransmitted as history")
    func failedTurnIsNotResent() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let local = FakeChatRouteClient()
        let store = makeStore(local: local, keys: keys)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }

        // One intact exchange, then a failed one.
        store.send("good")
        await waitUntil { local.completeCalls.count == 1 && store.conversation?.entries.last?.phase == .complete }
        local.completeResult = .failure(ChatClientError.paymentRequired)
        store.send("doomed")
        await waitUntil { local.completeCalls.count == 2 && store.conversation?.entries.last?.phase.isFailure == true }
        // The failed turn stays visible.
        #expect(store.conversation?.entries.contains { entry in
            entry.author == .user && entry.text == "doomed"
        } == true)

        local.completeResult = .success(ChatCompletionOutcome(
            content: "Local synthetic reply.", model: "gpt-oss-20b", finishReason: "stop", promptTokens: 12, completionTokens: 34
        ))
        store.send("retry")
        await waitUntil { local.completeCalls.count == 3 && store.conversation?.entries.last?.phase == .complete }
        let history = local.completeCalls.last ?? []
        // Only the intact exchange plus the new turn; "doomed" is absent.
        #expect(history.map(\.content) == ["good", "Local synthetic reply.", "retry"])
    }

    @Test("a key replaced during a paid preflight stops the request fail-closed")
    func keyChangeDuringPaidPreflight() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer-old")
        let balance = FakeBalanceClient()
        balance.suspend = true
        let network = FakeChatRouteClient()
        let store = makeStore(network: network, balance: balance, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { store.selectedModelID != nil }
        store.acknowledgePaidRoute()
        store.send("paid")
        await waitUntil { balance.pendingReleases > 0 }

        // The key is replaced while the balance gate is suspended.
        #expect(store.storeConsumerKey("dk-synthetic-consumer-new") == nil)

        balance.release(.success(ConsumerBalanceSnapshot(balanceMicroUSD: 1_000_000, capturedAt: clock.date)))
        await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
        #expect(network.completeCalls.isEmpty)
        #expect(store.conversation?.entries.last?.failureMessage == ChatSendBlocked.credentialChanged.message)
    }

    @Test("a stale pricing fetch result blocks the paid send")
    func stalePricingFetchBlocks() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer")
        let pricing = FakePricingClient()
        pricing.capturedAtOffset = ChatStore.pricingFreshnessWindow + 60
        let network = FakeChatRouteClient()
        let store = makeStore(network: network, pricing: pricing, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { store.selectedModelID != nil }
        store.acknowledgePaidRoute()
        store.send("needs current pricing")
        await waitUntil { store.conversation?.entries.last?.phase.isFailure == true }
        #expect(network.completeCalls.isEmpty)
        #expect(store.conversation?.entries.last?.failureMessage == ChatSendBlocked.pricingUnavailable.message)
    }

    @Test("history cap trims whole pairs and never starts with an orphan assistant")
    func historyCapTrimsPairs() async {
        let local = FakeChatRouteClient()
        let store = makeStore(local: local)
        store.startConversation(route: .local)
        await waitUntil { store.selectedModelID != nil }

        // Fill the transcript with more intact pairs than the cap allows.
        let pairs = ChatStore.maximumHistoryMessages / 2 // 16 pairs = 32 messages
        for turn in 0..<(pairs + 1) {
            store.send("turn \(turn)")
            await waitUntil { local.completeCalls.count == turn + 1 && store.conversation?.entries.last?.phase == .complete }
        }
        let history = local.completeCalls.last ?? []
        // 16 prior pairs + the new turn = 33 messages; trimming one whole
        // pair from the front leaves 15 pairs + the new turn = 31.
        #expect(history.count == ChatStore.maximumHistoryMessages - 1)
        #expect(history.first?.role == .user)
        #expect(history.last?.role == .user)
        #expect(history.last?.content == "turn \(pairs)")
        // Roles must alternate user/assistant throughout the window.
        let roles = history.map(\.role)
        #expect(roles.enumerated().allSatisfy { index, role in
            role == (index % 2 == 0 ? .user : .assistant)
        })
    }

    @Test("key changes invalidate network verification, selection and readiness")
    func keyChangeInvalidatesNetworkState() async {
        let keys = FakeConsumerKeyStore()
        keys.inject("dk-synthetic-consumer-old")
        let balance = FakeBalanceClient()
        let store = makeStore(balance: balance, keys: keys)

        store.startConversation(route: .network)
        await waitUntil { store.selectedModelID != nil }
        store.acknowledgePaidRoute()
        await store.checkBalance()
        await waitUntil { store.balance != nil }

        // Replacing the key drops everything the old key vouched for.
        #expect(store.storeConsumerKey("dk-synthetic-consumer-new") == nil)
        #expect(store.networkModels == nil)
        #expect(store.balance == nil)
        #expect(store.selectedModelID == nil)
        #expect(store.canSend == false)

        // Removing the key does the same on a fresh verification.
        await store.refreshModels()
        await waitUntil { store.selectedModelID != nil }
        store.removeConsumerKey()
        #expect(store.networkModels == nil)
        #expect(store.selectedModelID == nil)
        #expect(store.consumerKeyPresent == false)
    }

    @Test("invalid key material is refused with a fixed message and never stored")
    func invalidKeyRefused() {
        let keys = FakeConsumerKeyStore()
        let store = makeStore(keys: keys)
        let message = store.storeConsumerKey("has spaces")
        #expect(message == ConsumerKeyStoreError.invalidKey.errorDescription)
        #expect(store.consumerKeyPresent == false)
        #expect(keys.storedKey == nil)
    }
}

// MARK: - Fakes

private final class MutableClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

final class FakeChatRouteClient: LocalChatRouteClient, NetworkChatRouteClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _completeCalls: [[ChatMessagePayload]] = []
    private var _pending: [CheckedContinuation<ChatCompletionOutcome, Error>] = []
    private var _pendingModels: [CheckedContinuation<ChatModelListSnapshot, Error>] = []

    var modelsResult: Result<ChatModelListSnapshot, Error> = .success(
        ChatModelListSnapshot(modelIDs: ["gpt-oss-20b", "gemma-4-26b-qat-4bit"], capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    var completeResult: Result<ChatCompletionOutcome, Error> = .success(
        ChatCompletionOutcome(content: "Local synthetic reply.", model: "gpt-oss-20b", finishReason: "stop", promptTokens: 12, completionTokens: 34)
    )
    var suspendComplete = false
    var suspendModels = false

    // Locking lives in synchronous helpers only; async paths call these.

    private func sync<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    var completeCalls: [[ChatMessagePayload]] {
        sync { _completeCalls }
    }
    var pendingReleases: Int {
        sync { _pending.count }
    }
    var pendingModelReleases: Int {
        sync { _pendingModels.count }
    }

    func release(_ result: Result<ChatCompletionOutcome, Error>) {
        let pending = sync { () -> [CheckedContinuation<ChatCompletionOutcome, Error>] in
            let copy = _pending
            _pending.removeAll()
            return copy
        }
        pending.forEach { $0.resume(with: result) }
    }

    /// Resumes pending calls one-for-one in enqueue order, so a test can end
    /// an older cancelled call differently from a newer one.
    func releaseInOrder(_ results: [Result<ChatCompletionOutcome, Error>]) {
        let pending = sync { () -> [CheckedContinuation<ChatCompletionOutcome, Error>] in
            let copy = Array(_pending.prefix(results.count))
            _pending.removeFirst(min(results.count, _pending.count))
            return copy
        }
        for (continuation, result) in zip(pending, results) {
            continuation.resume(with: result)
        }
    }

    func releaseModels(_ result: Result<ChatModelListSnapshot, Error>) {
        let pending = sync { () -> [CheckedContinuation<ChatModelListSnapshot, Error>] in
            let copy = _pendingModels
            _pendingModels.removeAll()
            return copy
        }
        pending.forEach { $0.resume(with: result) }
    }

    func models(now: Date) async throws -> ChatModelListSnapshot {
        if suspendModels {
            return try await withCheckedThrowingContinuation { continuation in
                sync { _pendingModels.append(continuation) }
            }
        }
        return try modelsResult.get()
    }

    func complete(model: String, messages: [ChatMessagePayload]) async throws -> ChatCompletionOutcome {
        let shouldSuspend = sync { () -> Bool in
            _completeCalls.append(messages)
            return suspendComplete
        }
        if shouldSuspend {
            return try await withCheckedThrowingContinuation { continuation in
                sync { _pending.append(continuation) }
            }
        }
        return try completeResult.get()
    }
}

final class FakeBalanceClient: ConsumerBalanceFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [CheckedContinuation<ConsumerBalanceSnapshot, Error>] = []

    var balance: Int64 = 2_400_000
    var result: Result<ConsumerBalanceSnapshot, Error>?
    var capturedAtOffset: TimeInterval = 0
    var suspend = false

    private func sync<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    var pendingReleases: Int {
        sync { _pending.count }
    }

    func release(_ result: Result<ConsumerBalanceSnapshot, Error>) {
        let pending = sync { () -> [CheckedContinuation<ConsumerBalanceSnapshot, Error>] in
            let copy = _pending
            _pending.removeAll()
            return copy
        }
        pending.forEach { $0.resume(with: result) }
    }

    func fetch(now: Date) async throws -> ConsumerBalanceSnapshot {
        if suspend {
            return try await withCheckedThrowingContinuation { continuation in
                sync { _pending.append(continuation) }
            }
        }
        if let result {
            return try result.get()
        }
        return ConsumerBalanceSnapshot(
            balanceMicroUSD: balance,
            capturedAt: now.addingTimeInterval(capturedAtOffset)
        )
    }
}

final class FakePricingClient: PublicPricingFetching, @unchecked Sendable {
    var result: Result<PublicPricingSnapshot, Error>?
    /// Shifts the captured timestamp of returned snapshots to simulate a
    /// stale-but-successful fetch.
    var capturedAtOffset: TimeInterval = 0

    init(prices: [String] = ["gpt-oss-20b", "gemma-4-26b-qat-4bit"]) {
        let list = prices.map { #"{"model":"\#($0)","input_price":18000,"output_price":90000}"# }
            .joined(separator: ",")
        result = .success(try! PublicPricingSnapshot.parse(
            Data(#"{"prices":[\#(list)]}"#.utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    init(failing error: Error) {
        result = .failure(error)
    }

    func fetch(at capturedAt: Date) async throws -> PublicPricingSnapshot {
        guard let result else {
            return PublicPricingSnapshot(prices: [], capturedAt: capturedAt)
        }
        let snapshot = try result.get()
        guard capturedAtOffset != 0 else { return snapshot }
        return PublicPricingSnapshot(prices: snapshot.prices, capturedAt: capturedAt.addingTimeInterval(capturedAtOffset))
    }
}

final class FakeConsumerKeyStore: ConsumerKeyManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _key: String?

    var storedKey: String? {
        lock.lock(); defer { lock.unlock() }
        return _key
    }

    func inject(_ key: String) {
        lock.lock()
        _key = key
        lock.unlock()
    }

    func store(_ key: String) throws {
        guard ConsumerAPIKey.isValid(key) else { throw ConsumerKeyStoreError.invalidKey }
        lock.lock()
        _key = ConsumerAPIKey.trimmed(key)
        lock.unlock()
    }

    func remove() {
        lock.lock()
        _key = nil
        lock.unlock()
    }

    func withConsumerKey<R>(_ body: (String) throws -> R) rethrows -> R? {
        lock.lock()
        let key = _key
        lock.unlock()
        guard let key else { return nil }
        return try body(key)
    }

    var hasKey: Bool { storedKey != nil }
}

// MARK: - Phase helpers

extension ChatEntry.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

extension ChatEntry {
    var failureMessage: String? { phase.failureMessage }
}
