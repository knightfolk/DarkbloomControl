import DarkbloomTelemetry
import Foundation
import SwiftUI

/// The chat destination a conversation is bound to at creation. The route is
/// fixed for the life of a conversation: switching routes requires starting a
/// new chat, so text written under one route can never be silently sent to
/// the other.
enum ChatRoute: String, CaseIterable, Identifiable, Sendable {
    case local
    case network

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "Local endpoint · this Mac"
        case .network: "Darkbloom network · paid"
        }
    }

    /// Short badge used on every assistant response.
    var provenanceLabel: String {
        switch self {
        case .local: "Local · this Mac"
        case .network: "Darkbloom network · paid"
        }
    }
}

/// Route and model provenance retained on every assistant response.
struct ChatResponseProvenance: Equatable, Sendable {
    let route: ChatRoute
    let modelID: String
    let completedAt: Date
}

struct ChatEntry: Identifiable, Equatable, Sendable {
    enum Author: Equatable, Sendable { case user, assistant }
    enum Phase: Equatable, Sendable {
        case sending
        case complete
        case failed(String)
        case cancelled
    }

    let id: UUID
    let author: Author
    var text: String
    var phase: Phase
    var provenance: ChatResponseProvenance?
    var promptTokens: Int?
    var completionTokens: Int?
}

struct ChatConversation: Identifiable, Equatable, Sendable {
    let id: UUID
    let route: ChatRoute
    let createdAt: Date
    var modelID: String?
    /// Network conversations require an explicit, per-conversation
    /// acknowledgment of the paid semantics before the first send.
    var paidRouteAcknowledged = false
    var entries: [ChatEntry] = []
}

/// Shared in-memory conversation state for the dashboard chat tab and the
/// pop-out chat window (one instance, two windows). Nothing here persists
/// prompts, transcripts, or credentials: the transcript lives only in this
/// store's memory and the consumer API key lives only in the Keychain.
///
/// Send gating, all fail-closed:
/// - Local: a recent successful `GET /v1/models` verification (bearer-token
///   authenticated on authenticated endpoints, unauthenticated only where
///   that is explicit in hosting settings or the discovery record) is
///   required, or Send stays disabled. If the local endpoint is unavailable
///   the store stops; it never falls back to the network.
/// - Network: the conversation's paid-route acknowledgment, a stored consumer
///   API key, a fresh authoritative balance read above zero, and a fresh
///   pricing snapshot containing the selected model are all required. A
///   server 402 is recorded as the network's authoritative decision and is
///   never retried. A positive balance is not a guarantee; the network
///   reserves against each request and decides sufficiency.
@MainActor
final class ChatStore: ObservableObject {
    static let modelsFreshnessWindow: TimeInterval = 120
    static let pricingFreshnessWindow: TimeInterval = 900
    static let maximumHistoryMessages = 32

    @Published private(set) var conversation: ChatConversation?
    @Published private(set) var isSending = false
    @Published private(set) var localModels: ChatModelListSnapshot?
    @Published private(set) var networkModels: ChatModelListSnapshot?
    @Published private(set) var isRefreshingModels = false
    /// Fixed-string reason the last model verification failed, if it did.
    @Published private(set) var modelsNotice: String?
    @Published private(set) var balance: ConsumerBalanceSnapshot?
    @Published private(set) var balanceCheckFailed = false
    @Published private(set) var pricing: PublicPricingSnapshot?
    @Published private(set) var pricingUnavailable = false
    @Published private(set) var consumerKeyPresent: Bool
    /// Fixed-string transient status for the composer area.
    @Published private(set) var notice: String?

    private let localClient: LocalChatRouteClient
    private let networkClient: NetworkChatRouteClient
    private let balanceClient: any ConsumerBalanceFetching
    private let pricingClient: any PublicPricingFetching
    private let keyStore: any ConsumerKeyManaging
    private let now: @Sendable () -> Date
    private var sendTask: Task<Void, Never>?
    /// Bumped whenever the consumer key changes. In-flight network
    /// verification or balance reads that started under an older key are
    /// discarded against this generation so they cannot repopulate state the
    /// new key has not vouched for.
    private var networkCredentialGeneration = 0

    init(
        localClient: LocalChatRouteClient,
        networkClient: NetworkChatRouteClient,
        balanceClient: any ConsumerBalanceFetching,
        pricingClient: any PublicPricingFetching,
        keyStore: any ConsumerKeyManaging,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.localClient = localClient
        self.networkClient = networkClient
        self.balanceClient = balanceClient
        self.pricingClient = pricingClient
        self.keyStore = keyStore
        self.now = now
        consumerKeyPresent = keyStore.hasKey
    }

    // MARK: Conversation lifecycle

    /// Starts a new, empty conversation bound to one route. This is the only
    /// way to change routes; an existing transcript is never re-routed. Any
    /// in-flight send for the previous conversation is cancelled and its
    /// results are discarded.
    func startConversation(route: ChatRoute) {
        cancelSend()
        sendTask = nil
        isSending = false
        notice = nil
        modelsNotice = nil
        conversation = ChatConversation(
            id: UUID(),
            route: route,
            createdAt: now(),
            modelID: nil,
            paidRouteAcknowledged: false,
            entries: []
        )
        Task { [weak self] in
            await self?.refreshModels()
            if route == .network {
                await self?.refreshNetworkReadiness()
            }
        }
    }

    /// Records the explicit paid-route acknowledgment for the active network
    /// conversation. It is per-conversation and never persisted.
    func acknowledgePaidRoute() {
        guard conversation?.route == .network else { return }
        conversation?.paidRouteAcknowledged = true
        notice = nil
    }

    // MARK: Model verification

    /// The verified model IDs for the active conversation's route, from the
    /// most recent successful `GET /v1/models` read (authenticated or
    /// explicitly unauthenticated, per the endpoint). The picker offers
    /// nothing else.
    var verifiedModelIDs: [String] {
        guard let conversation else { return [] }
        return modelsSnapshot(for: conversation.route)?.modelIDs ?? []
    }

    func selectModel(_ id: String) {
        guard var updated = conversation, verifiedModelIDs.contains(id) else { return }
        updated.modelID = id
        conversation = updated
    }

    var selectedModelID: String? { conversation?.modelID }

    func refreshModels() async {
        guard let route = conversation?.route else { return }
        // A refresh belongs to the conversation and credential generation
        // that started it; a new chat or key change mid-flight keeps its own
        // notice and selection clean.
        let conversationID = conversation?.id
        let credentialGeneration = networkCredentialGeneration
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let snapshot = try await client(for: route).models(now: now())
            // An older overlapping response cannot replace a newer accepted
            // sample, and cannot re-select models for a newer conversation.
            let existing = modelsSnapshot(for: route)
            let isCurrentSample = existing.map { snapshot.capturedAt >= $0.capturedAt } ?? true
            let belongsToCurrentCredential = route != .network || credentialGeneration == networkCredentialGeneration
            if isCurrentSample && belongsToCurrentCredential {
                switch route {
                case .local: localModels = snapshot
                case .network: networkModels = snapshot
                }
            }
            if conversation?.id == conversationID {
                modelsNotice = nil
            }
            if isCurrentSample && belongsToCurrentCredential {
                reconcileModelSelection(with: snapshot, route: route, conversationID: conversationID)
            }
        } catch {
            // Keep the previous snapshot as stale; the freshness gate below
            // still fails closed for sending.
            if conversation?.id == conversationID {
                modelsNotice = Self.fixedMessage(for: error, route: route)
                    ?? "Model verification failed. Refresh to try again."
            }
        }
    }

    /// Keeps the selection honest: only a verified model can stay selected,
    /// and the first verified model is selected automatically so the picker
    /// never displays an unselected placeholder as if it were chosen. The
    /// reconciliation belongs to the conversation that requested it; a newer
    /// conversation on the same route is never touched.
    private func reconcileModelSelection(with snapshot: ChatModelListSnapshot, route: ChatRoute, conversationID: UUID?) {
        guard var updated = conversation,
              updated.id == conversationID,
              updated.route == route
        else { return }
        if let current = updated.modelID, snapshot.modelIDs.contains(current) { return }
        updated.modelID = snapshot.modelIDs.first
        conversation = updated
    }

    /// A send requires a recently verified model list on the conversation's
    /// own route.
    var modelsAreFresh: Bool {
        guard let conversation,
              let snapshot = modelsSnapshot(for: conversation.route)
        else { return false }
        let age = now().timeIntervalSince(snapshot.capturedAt)
        return age.isFinite && age >= -5 && age <= Self.modelsFreshnessWindow
    }

    // MARK: Network readiness display

    /// Fetches pricing and the balance for the banner. This is display-only;
    /// every network send re-checks both fail-closed regardless of age.
    func refreshNetworkReadiness() async {
        await refreshPricing()
        await checkBalance()
    }

    func refreshPricing() async {
        do {
            let snapshot = try await pricingClient.fetch(at: now())
            pricing = snapshot
            pricingUnavailable = false
        } catch {
            pricingUnavailable = true
        }
    }

    func checkBalance() async {
        let credentialGeneration = networkCredentialGeneration
        do {
            let snapshot = try await balanceClient.fetch(now: now())
            // A balance read that started under an older key cannot
            // repopulate readiness for the current one.
            guard credentialGeneration == networkCredentialGeneration else { return }
            balance = snapshot
            balanceCheckFailed = false
        } catch {
            guard credentialGeneration == networkCredentialGeneration else { return }
            balance = nil
            balanceCheckFailed = true
        }
    }

    var pricingIsFresh: Bool {
        guard let pricing else { return false }
        return isFresh(pricing)
    }

    private func isFresh(_ snapshot: PublicPricingSnapshot) -> Bool {
        let age = now().timeIntervalSince(snapshot.capturedAt)
        return age.isFinite && age >= -5 && age <= Self.pricingFreshnessWindow
    }

    /// "$0.018 / $0.090 per 1M tokens (input / output)" for the selected
    /// model, or nil when pricing is unavailable or does not list the model.
    func pricingSummary(for modelID: String) -> String? {
        guard let price = pricing?.price(for: modelID) else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        let input = formatter.string(from: NSDecimalNumber(decimal: price.inputUSDPerMillion)) ?? "?"
        let output = formatter.string(from: NSDecimalNumber(decimal: price.outputUSDPerMillion)) ?? "?"
        return "$\(input) / $\(output) per 1M tokens (input / output)"
    }

    // MARK: Consumer key

    /// Stores the pasted consumer API key in the macOS Keychain. Returns a
    /// fixed error message on failure; never the key. Network model
    /// verification is credential-scoped: the verified list and readiness
    /// belong to the previous key and are invalidated so a new key inherits
    /// nothing.
    @discardableResult
    func storeConsumerKey(_ text: String) -> String? {
        do {
            try keyStore.store(text)
        } catch let error as ConsumerKeyStoreError {
            return error.errorDescription
        } catch {
            return "The key could not be stored."
        }
        consumerKeyPresent = keyStore.hasKey
        invalidateNetworkReadiness()
        return nil
    }

    func removeConsumerKey() {
        keyStore.remove()
        consumerKeyPresent = keyStore.hasKey
        invalidateNetworkReadiness()
    }

    /// Drops every piece of network state that the previous consumer key
    /// vouched for: the verified network model list (and the active network
    /// conversation's selection from it) and the balance read. In-flight
    /// reads started under the old key are discarded via the generation.
    private func invalidateNetworkReadiness() {
        networkCredentialGeneration += 1
        networkModels = nil
        balance = nil
        balanceCheckFailed = false
        if var updated = conversation, updated.route == .network {
            updated.modelID = nil
            conversation = updated
        }
    }

    // MARK: Sending

    var canSend: Bool {
        guard let conversation, !isSending, effectiveModelID(for: conversation) != nil else { return false }
        switch conversation.route {
        case .local:
            return modelsAreFresh
        case .network:
            return conversation.paidRouteAcknowledged && consumerKeyPresent && modelsAreFresh
        }
    }

    /// The selected model, or the first verified one when auto-selection has
    /// not run yet. Never a guess: only IDs from this route's verified list.
    private func effectiveModelID(for conversation: ChatConversation) -> String? {
        if let modelID = conversation.modelID {
            return modelsSnapshot(for: conversation.route)?.modelIDs.contains(modelID) == true ? modelID : nil
        }
        return modelsSnapshot(for: conversation.route)?.modelIDs.first
    }

    /// Sends one user turn on the conversation's fixed route. A second call
    /// while a send is in flight is ignored, so a response can never be
    /// accidentally requested twice. Returns whether the turn was accepted:
    /// false means a gate (for example model verification that expired by
    /// time without a published change) silently rejected it, and the caller
    /// must keep the user's draft.
    @discardableResult
    func send(_ draft: String) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, var updated = conversation, let modelID = effectiveModelID(for: updated), !text.isEmpty else { return false }
        if updated.modelID == nil {
            updated.modelID = modelID
        }

        let conversationID = updated.id
        let route = updated.route
        let credentialGeneration = networkCredentialGeneration

        // Context comes from intact prior exchanges plus the new turn. A
        // failed or cancelled exchange is skipped whole — its user prompt
        // stays visible in the transcript but is never silently
        // retransmitted as history.
        var history: [ChatMessagePayload] = []
        var index = updated.entries.count - 1
        while index >= 1 {
            let assistant = updated.entries[index]
            let user = updated.entries[index - 1]
            if user.author == .user, user.phase == .complete, !user.text.isEmpty,
               assistant.author == .assistant, assistant.phase == .complete, !assistant.text.isEmpty {
                history.insert(ChatMessagePayload(role: .user, content: user.text), at: 0)
                history.insert(ChatMessagePayload(role: .assistant, content: assistant.text), at: 1)
            }
            index -= 2
        }
        history.append(ChatMessagePayload(role: .user, content: text))
        // Trim whole pairs from the front so the window never begins with
        // an orphan assistant message; the new user turn stays last.
        while history.count > Self.maximumHistoryMessages, history.count >= 3 {
            history.removeFirst(2)
        }

        updated.entries.append(ChatEntry(
            id: UUID(),
            author: .user,
            text: text,
            phase: .complete
        ))
        let placeholderID = UUID()
        updated.entries.append(ChatEntry(
            id: placeholderID,
            author: .assistant,
            text: "",
            phase: .sending
        ))
        conversation = updated
        isSending = true
        notice = nil

        sendTask = Task { [weak self] in
            await self?.performSend(
                conversationID: conversationID,
                credentialGeneration: credentialGeneration,
                route: route,
                modelID: modelID,
                history: history,
                placeholderID: placeholderID
            )
        }
        return true
    }

    /// Cancels the in-flight send and finalizes its visible state
    /// immediately: a cancelled Task that never started would otherwise
    /// leave the placeholder waiting forever. Once an HTTP request may have
    /// begun, cancellation cannot promise the request was never delivered,
    /// so the recorded state says exactly that.
    func cancelSend() {
        guard let task = sendTask else { return }
        task.cancel()
        sendTask = nil
        guard var updated = conversation, isSending,
              let index = updated.entries.lastIndex(where: { $0.phase == .sending })
        else { return }
        updated.entries[index].phase = .cancelled
        conversation = updated
        isSending = false
        notice = "Send cancelled. The request may already have been delivered on this route — verify before re-sending."
    }

    func clearNotice() {
        notice = nil
    }

    // MARK: Send pipeline

    private func performSend(
        conversationID: UUID,
        credentialGeneration: Int,
        route: ChatRoute,
        modelID: String,
        history: [ChatMessagePayload],
        placeholderID: UUID
    ) async {
        defer {
            // Only the uncancelled owner of this send may release the
            // sending state: a cancelled predecessor (the user cancelled and
            // sent again, or started a new chat) must not clear the flag of
            // the newer send that now owns it.
            if conversation?.id == conversationID && !Task.isCancelled {
                isSending = false
            }
        }
        // The conversation ID is re-checked after every await inside
        // finish/fail so a replacement conversation is never mutated.
        do {
            switch route {
            case .local:
                // Local: no fallback. If the endpoint is gone, this throws
                // and the failure is recorded; only the user can start a new
                // conversation on the network route.
                let outcome = try await localClient.complete(model: modelID, messages: history)
                finish(conversationID: conversationID, placeholderID: placeholderID, route: route, modelID: modelID, outcome: outcome)

            case .network:
                try await enforceNetworkGates(conversationID: conversationID, credentialGeneration: credentialGeneration, modelID: modelID)
                let outcome = try await networkClient.complete(model: modelID, messages: history)
                finish(conversationID: conversationID, placeholderID: placeholderID, route: route, modelID: modelID, outcome: outcome)
            }
        } catch {
            fail(conversationID: conversationID, placeholderID: placeholderID, route: route, error: error)
        }
    }

    /// All network pre-send gates. Every failure throws with a fixed message
    /// and stops the send — nothing falls through to a weaker check. If the
    /// conversation was replaced while a gate was suspended, the send is
    /// abandoned rather than continuing with the old transcript; if the
    /// consumer key was replaced, the send fails closed rather than issuing a
    /// paid request with the new key and the old key's verified state.
    private func enforceNetworkGates(conversationID: UUID, credentialGeneration: Int, modelID: String) async throws {
        try Task.checkCancellation()
        guard credentialGeneration == networkCredentialGeneration else {
            throw ChatSendBlocked.credentialChanged
        }
        guard let active = conversation, active.id == conversationID, active.route == .network else {
            throw CancellationError()
        }
        guard active.paidRouteAcknowledged else {
            throw ChatSendBlocked.needsPaidAcknowledgement
        }
        // Re-read the keychain at send time; a removed key stops the send.
        guard keyStore.hasKey else {
            consumerKeyPresent = false
            throw ChatClientError.missingConsumerKey
        }
        if !pricingIsFresh {
            do {
                let snapshot = try await pricingClient.fetch(at: now())
                try Task.checkCancellation()
                // The fetched snapshot itself must be current; a stale
                // result blocks the paid send rather than excusing it.
                guard isFresh(snapshot) else {
                    pricing = snapshot
                    pricingUnavailable = true
                    throw ChatSendBlocked.pricingUnavailable
                }
                pricing = snapshot
                pricingUnavailable = false
            } catch {
                pricingUnavailable = true
                throw ChatSendBlocked.pricingUnavailable
            }
        }
        guard pricing?.price(for: modelID) != nil else {
            throw ChatSendBlocked.unknownPricing(modelID)
        }
        // Fresh, authoritative balance read per send. Even a successful
        // fetch must be current: a stale snapshot (stale cache, skewed
        // clock, or fake) fails closed. The consumer ledger is advisory
        // only — the network reserves against each request and may still
        // return 402, which is handled as a final decision.
        do {
            let snapshot = try await balanceClient.fetch(now: now())
            try Task.checkCancellation()
            // A read started under an older key must not publish balance for
            // the current one, whatever it returned.
            guard credentialGeneration == networkCredentialGeneration else {
                throw ChatSendBlocked.credentialChanged
            }
            guard snapshot.isFresh(at: now()) else {
                balance = snapshot
                balanceCheckFailed = true
                throw ChatSendBlocked.balanceCheckFailed("The reported balance was not current.")
            }
            balance = snapshot
            balanceCheckFailed = false
            guard snapshot.balanceMicroUSD > 0 else {
                throw ChatSendBlocked.noAvailableCredit
            }
        } catch let blocked as ChatSendBlocked {
            throw blocked
        } catch {
            balance = nil
            balanceCheckFailed = true
            throw ChatSendBlocked.balanceCheckFailed(Self.fixedMessage(for: error, route: .network) ?? "The balance could not be verified.")
        }
        // The conversation and the credential must both still be the ones
        // this send belongs to before the paid request is issued.
        guard let current = conversation, current.id == conversationID, current.route == .network else {
            throw CancellationError()
        }
        guard credentialGeneration == networkCredentialGeneration else {
            throw ChatSendBlocked.credentialChanged
        }
    }

    private func finish(
        conversationID: UUID,
        placeholderID: UUID,
        route: ChatRoute,
        modelID: String,
        outcome: ChatCompletionOutcome
    ) {
        // A late result must never overwrite a state finalized by
        // cancellation or a newer send.
        guard var conversation, conversation.id == conversationID,
              let index = conversation.entries.firstIndex(where: { $0.id == placeholderID }),
              conversation.entries[index].phase == .sending
        else { return }
        // Provenance names the model that actually served the reply when the
        // response reports one; the requested ID is the fallback.
        let servedModelID = outcome.model.map { model in
            model.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let provenanceModelID = servedModelID.isEmpty ? modelID : servedModelID
        conversation.entries[index].text = outcome.content
        conversation.entries[index].phase = .complete
        conversation.entries[index].provenance = ChatResponseProvenance(
            route: route,
            modelID: provenanceModelID,
            completedAt: now()
        )
        conversation.entries[index].promptTokens = outcome.promptTokens
        conversation.entries[index].completionTokens = outcome.completionTokens
        self.conversation = conversation
    }

    private func fail(conversationID: UUID, placeholderID: UUID, route: ChatRoute, error: Error) {
        let message: String
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            message = ""
        } else if let blocked = error as? ChatSendBlocked {
            message = blocked.message
        } else if let chatError = error as? ChatClientError {
            message = chatError.errorDescription ?? "The request failed."
        } else if (error as? URLError) != nil {
            message = Self.fixedMessage(for: error, route: route) ?? "The request failed."
        } else {
            message = "The request failed."
        }

        guard var conversation, conversation.id == conversationID,
              let index = conversation.entries.firstIndex(where: { $0.id == placeholderID }),
              conversation.entries[index].phase == .sending
        else { return }
        if message.isEmpty {
            conversation.entries[index].phase = .cancelled
            notice = "Send cancelled. The request may already have been delivered on this route — verify before re-sending."
        } else {
            conversation.entries[index].phase = .failed(message)
            notice = message
        }
        self.conversation = conversation
    }

    // MARK: Helpers

    private func client(for route: ChatRoute) -> any ChatModelListing {
        switch route {
        case .local: localClient
        case .network: networkClient
        }
    }

    private func modelsSnapshot(for route: ChatRoute) -> ChatModelListSnapshot? {
        switch route {
        case .local: localModels
        case .network: networkModels
        }
    }

    /// Maps transport errors to fixed strings; never constructs a message
    /// from server-provided text.
    private static func fixedMessage(for error: Error, route: ChatRoute) -> String? {
        if let chatError = error as? ChatClientError {
            return chatError.errorDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The \(route == .local ? "local endpoint" : "Darkbloom network") did not respond in time."
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return route == .local
                    ? "The local chat endpoint could not be reached. Start local hosting, or start a new chat on the network route."
                    : "The Darkbloom network could not be reached."
            default:
                return "The request could not be completed."
            }
        }
        return nil
    }
}

/// Store-level gate failures with fixed user-facing messages.
enum ChatSendBlocked: Error {
    case needsPaidAcknowledgement
    case pricingUnavailable
    case unknownPricing(String)
    case noAvailableCredit
    case balanceCheckFailed(String)
    case credentialChanged

    var message: String {
        switch self {
        case .needsPaidAcknowledgement:
            "Acknowledge the paid-network terms for this conversation before the first send."
        case .pricingUnavailable:
            "Network pricing is unavailable right now, so the send was stopped. No charge can be approved without verified pricing."
        case .unknownPricing:
            "Network pricing does not list the selected model, so the send was stopped."
        case .noAvailableCredit:
            "The account balance is zero. Add credit before using the paid network route."
        case .balanceCheckFailed(let detail):
            "The balance could not be verified, so the send was stopped. \(detail)"
        case .credentialChanged:
            "The consumer API key changed before the request was sent, so the send was stopped. Send again after the new key's verification."
        }
    }
}

/// Local and network route clients each implement model verification and
/// completion against their own endpoint and credential domain.
protocol LocalChatRouteClient: ChatModelListing, ChatCompleting {}
protocol NetworkChatRouteClient: ChatModelListing, ChatCompleting {}
extension LocalChatClient: LocalChatRouteClient {}
extension NetworkChatClient: NetworkChatRouteClient {}
