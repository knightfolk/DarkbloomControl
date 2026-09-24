import DarkbloomTelemetry
import SwiftUI

/// The built-in Chat destination. One `ChatStore` instance is shared by this
/// view in the dashboard tab and the pop-out chat window, so both show the
/// same in-memory conversation.
struct ChatView: View {
    @ObservedObject var store: ChatStore
    var openPopOut: (() -> Void)? = nil

    @State private var draft = ""
    /// The conversation this window's draft was written in. A draft may only
    /// ever be sent to the conversation it belongs to, so an unsent draft
    /// can never ride along when a new chat starts on a different route.
    @State private var draftConversationID: UUID?
    @State private var showsNewChatDialog = false
    @State private var showsKeyEditor = false
    @State private var keyDraft = ""
    @State private var keyError: String?

    private var draftBelongsToActiveConversation: Bool {
        ChatDraftPolicy.canSend(
            draft: draft,
            draftConversationID: draftConversationID,
            activeConversationID: store.conversation?.id
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = store.conversation {
                routeBanner(conversation)
                if conversation.route == .network && !conversation.paidRouteAcknowledged {
                    paidAcknowledgementPanel
                }
                transcript(conversation)
                composer(conversation)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsNewChatDialog) {
            ChatNewConversationDialog(store: store)
        }
        .onChange(of: store.conversation?.id) { _, _ in
            // A new conversation (the only route change) discards this
            // window's unsent draft immediately.
            draft = ""
            draftConversationID = nil
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No active chat")
                .font(.title2.bold())
            Text("Start a chat with an explicit destination. New chats default to the local endpoint. The destination is fixed for the whole conversation; switching requires a new chat, so nothing is ever silently re-routed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                showsNewChatDialog = true
            } label: {
                Label("New Chat…", systemImage: "plus.bubble")
            }
            .controlSize(.large)
            consumerKeyLink
            Spacer()
        }
        .padding()
    }

    // MARK: Route banner

    @ViewBuilder
    private func routeBanner(_ conversation: ChatConversation) -> some View {
        let route = conversation.route
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: route == .local ? "house.fill" : "network")
                    .foregroundStyle(route == .local ? .green : .orange)
                Text("Destination: \(route.label)")
                    .font(.headline)
                Spacer()
                Button {
                    showsNewChatDialog = true
                } label: {
                    Label("New Chat…", systemImage: "plus.bubble")
                }
                .help("Start a new chat. The destination of the current chat cannot be changed.")
                if let openPopOut {
                    Button(action: openPopOut) {
                        Label("Open in Window", systemImage: "macwindow.on.rectangle")
                    }
                    .help("Open this chat in a separate resizable window")
                }
            }
            switch route {
            case .local:
                Text("Sends go to your own local hosting endpoint on this Mac. The local engine is shared with fleet serving work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                modelVerificationLine
            case .network:
                Text("Network inference. This Mac is not used. Paid credits apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                balanceLine
                pricingLine
                Text("Balance is advisory; the network can still reject a send (402).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(route == .local ? Color.green.opacity(0.08) : Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var modelVerificationLine: some View {
        if store.modelsAreFresh {
            Text("Endpoint verified — \(store.verifiedModelIDs.count) models available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let notice = store.modelsNotice {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                // The notice itself carries the start-hosting/new-chat
                // guidance; only the disabled-send fact is restated here.
                Text("Local endpoint unavailable: \(notice) Sending stays disabled — nothing is re-routed automatically.")
            }
            .font(.caption)
            .foregroundStyle(.red)
        } else {
            Text("Verifying the local endpoint with an authenticated model list…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var balanceLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "creditcard")
            if let balance = store.balance, !store.balanceCheckFailed {
                Text("Balance: \(ChatFormatting.usd(balance.balanceUSD)) — re-checked immediately before every send")
            } else if store.balanceCheckFailed {
                Text("Balance: unavailable — it will be checked again before every send, and any send stops if that check fails")
                Button {
                    Task { await store.checkBalance() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry the balance check")
            } else {
                Text("Balance: checking…")
            }
        }
        .font(.caption)
        .foregroundStyle(store.balanceCheckFailed ? .red : .secondary)
    }

    @ViewBuilder
    private var pricingLine: some View {
        if let modelID = store.selectedModelID {
            if let summary = store.pricingSummary(for: modelID) {
                Text("\(modelID): \(summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("\(modelID): no verified price — a send would be stopped until pricing lists this model")
                    Button {
                        Task { await store.refreshPricing() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Retry the pricing check")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        } else if store.pricingUnavailable {
            Text("Network pricing is unavailable — a send would be stopped until pricing is verified")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Paid acknowledgement

    private var paidAcknowledgementPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Paid network route — acknowledge before the first send", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("• Inference runs on the Darkbloom network; this Mac is not used.")
                Text("• Every request is paid from your key's balance at the listed price.")
                Text("• Balance checked per send; 402 is final.")
            }
            .font(.callout)
            HStack {
                Button {
                    store.acknowledgePaidRoute()
                } label: {
                    Text("I understand — enable paid network sends for this chat")
                }
                .controlSize(.large)
                Spacer()
            }
        }
        .padding()
        .background(Color.orange.opacity(0.08))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: Transcript

    private func transcript(_ conversation: ChatConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conversation.entries) { entry in
                        ChatEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: conversation.entries.last?.phase) { _, _ in
                if let last = conversation.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = conversation.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                noticeBar(notice)
            }
        }
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(notice)
                .lineLimit(3)
            Spacer()
            Button {
                store.clearNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .padding(.horizontal)
    }

    // MARK: Composer

    private func composer(_ conversation: ChatConversation) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                modelPicker(conversation)
                Button {
                    Task { await store.refreshModels() }
                } label: {
                    if store.isRefreshingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Re-verify the model list on this chat's route with an authenticated request")
                if conversation.route == .network {
                    consumerKeyLink
                }
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: Binding(
                    get: {
                        // An edit owned by a previous conversation reads as
                        // empty here, so stale text can never display or
                        // send after a route change.
                        ChatDraftPolicy.visibleDraft(
                            draft: draft,
                            draftConversationID: draftConversationID,
                            activeConversationID: store.conversation?.id
                        )
                    },
                    set: { newValue in
                        // Discard edits that arrive while the stored owner
                        // is a different conversation (the window between a
                        // route change and onChange); only a fresh, empty
                        // draft may acquire the active conversation.
                        if let owner = draftConversationID, owner != store.conversation?.id {
                            draft = ""
                            draftConversationID = nil
                            return
                        }
                        draft = newValue
                        draftConversationID = store.conversation?.id
                    }
                ))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 120)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(nsColor: separatorColor()))
                    )
                if store.isSending {
                    Button(role: .cancel) {
                        store.cancelSend()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        guard draftBelongsToActiveConversation else {
                            draft = ""
                            draftConversationID = nil
                            return
                        }
                        draftConversationID = store.conversation?.id
                        // Keep the draft when the store rejects the turn (a
                        // gate may have expired without a visible change).
                        if !store.send(draft) { return }
                        draft = ""
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        !store.canSend
                            || !draftBelongsToActiveConversation
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            if !store.canSend, conversation.route == .network, !conversation.paidRouteAcknowledged {
                Text("Sending is disabled until the paid-route acknowledgement above is confirmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func modelPicker(_ conversation: ChatConversation) -> some View {
        let models = store.verifiedModelIDs
        if models.isEmpty {
            Label(store.isRefreshingModels ? "Verifying models…" : "No verified models yet",
                  systemImage: "cpu")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: Binding(
                get: { store.selectedModelID ?? models[0] },
                set: { store.selectModel($0) }
            )) {
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .disabled(store.isSending)
            .help("Only models verified on this chat's route are offered")
        }
    }

    private var consumerKeyLink: some View {
        Button {
            keyDraft = ""
            keyError = nil
            showsKeyEditor = true
        } label: {
            Label(
                store.consumerKeyPresent ? "Key saved" : "Add key",
                systemImage: "key"
            )
        }
        .foregroundStyle(store.consumerKeyPresent ? Color.primary : Color.orange)
        .help("Manage the Darkbloom consumer API key used for the paid network route. It is stored only in the macOS Keychain.")
        .sheet(isPresented: $showsKeyEditor) {
            ConsumerKeyEditor(store: store, draft: $keyDraft, errorMessage: $keyError)
        }
    }

    private func separatorColor() -> NSColor { .separatorColor }
}

/// One transcript row. Assistant rows carry their retained route provenance.
private struct ChatEntryRow: View {
    let entry: ChatEntry

    var body: some View {
        VStack(alignment: entry.author == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if entry.author == .user { Spacer(minLength: 40) }
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(entry.author == .user
                                  ? Color.accentColor.opacity(0.18)
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(alignment: .topLeading) {
                        if entry.phase == .sending {
                            ProgressView()
                                .controlSize(.small)
                                .offset(x: -6, y: -6)
                        }
                    }
                if entry.author == .assistant { Spacer(minLength: 40) }
            }
            switch entry.phase {
            case .complete:
                provenanceLine
            case .sending:
                Text("Waiting for the destination…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .cancelled:
                Label("Cancelled — the request may already have been delivered on this route.", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var provenanceLine: some View {
        if entry.author == .assistant, let provenance = entry.provenance {
            HStack(spacing: 6) {
                Label(provenance.route.provenanceLabel, systemImage: provenance.route == .local ? "house.fill" : "network")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(provenance.route == .local ? Color.green.opacity(0.15) : Color.orange.opacity(0.2))
                    )
                Text(provenance.modelID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(provenance.completedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let prompt = entry.promptTokens, let completion = entry.completionTokens {
                    Text("\(prompt) in · \(completion) out")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Explicit route choice for a new conversation. Local is the default; the
/// network option restates the paid semantics before the chat is created.
private struct ChatNewConversationDialog: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsNetwork = false

    var body: some View {
        VStack(spacing: 14) {
            Text("New Chat").font(.title2.bold())
            Text("Choose the destination. It is fixed for the entire conversation — switching later requires another new chat, and text from one destination is never sent to the other.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            routeCard(
                route: .local,
                title: "Local endpoint — this Mac",
                detail: "Sends to your own hosting endpoint. Default choice. The local inference engine is shared with fleet serving work."
            ) {
                dismiss()
                store.startConversation(route: .local)
            }

            if !confirmsNetwork {
                routeCard(
                    route: .network,
                    title: "Darkbloom network — paid",
                    detail: "Inference runs on the Darkbloom network; this Mac is not used. Every request is paid from your consumer API key's balance."
                ) {
                    confirmsNetwork = true
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Confirm the paid network route", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                    Text("• This Mac is not used for inference.\n• Every request is paid at the model's listed price from your balance.\n• A positive balance does not guarantee acceptance; the network's decision (including HTTP 402) is final.")
                        .font(.callout)
                    HStack {
                        Button("Use paid network") {
                            dismiss()
                            store.startConversation(route: .network)
                        }
                        .controlSize(.large)
                        Button("Back") { confirmsNetwork = false }
                        Spacer()
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 480)
    }

    private func routeCard(route: ChatRoute, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: route == .local ? "house.fill" : "network")
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(route == .local ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Consumer API key entry. The key is written straight to the Keychain and
/// never displayed, echoed back, or persisted anywhere else.
private struct ConsumerKeyEditor: View {
    @ObservedObject var store: ChatStore
    @Binding var draft: String
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Consumer API key (network route)", systemImage: "key")
                .font(.headline)
            Text("The Darkbloom network route requires a consumer API key — a separate credential from this app's provider device token and from the local endpoint token. It is stored only in the macOS Keychain, never in preferences or logs, and is never used for the local route.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.consumerKeyPresent {
                Label("A key is saved in the Keychain.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            SecureField("dk-…", text: $draft)
                .disabled(store.consumerKeyPresent)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if saved {
                Text("Saved to Keychain.").font(.caption).foregroundStyle(.green)
            }
            HStack {
                if store.consumerKeyPresent {
                    Button("Remove Key", role: .destructive) {
                        store.removeConsumerKey()
                        saved = false
                        draft = ""
                    }
                }
                Spacer()
                Button("Close") {
                    // Closing without saving must not keep the pasted key
                    // text in the parent's state.
                    draft = ""
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                if !store.consumerKeyPresent {
                    Button("Save to Keychain") {
                        if let failure = store.storeConsumerKey(draft) {
                            errorMessage = failure
                        } else {
                            errorMessage = nil
                            saved = true
                            draft = ""
                        }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear {
            // Belt-and-braces: no pasted key survives the sheet in any path.
            draft = ""
        }
    }
}

/// A draft may only be sent to the conversation it was written in. This is
/// the view-side half of the no-silent-re-routing guarantee: when a new chat
/// starts (the only route change), an unsent draft from the previous
/// conversation is discarded rather than delivered to the new route. Exact
/// non-nil ownership is required — an unstamped draft is not sendable.
enum ChatDraftPolicy {
    static func canSend(draft: String, draftConversationID: UUID?, activeConversationID: UUID?) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let owner = draftConversationID,
              let active = activeConversationID
        else { return false }
        return owner == active
    }

    /// What the composer displays: a draft owned by a previous conversation
    /// is shown as empty until SwiftUI's onChange clears the stored state.
    static func visibleDraft(draft: String, draftConversationID: UUID?, activeConversationID: UUID?) -> String {
        guard let owner = draftConversationID else { return draft }
        return owner == activeConversationID ? draft : ""
    }
}

enum ChatFormatting {
    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    /// Renders a USD Decimal without currency-symbol guessing: micro-USD
    /// divided by 1,000,000 is a small value, so up to six decimals are kept.
    static func usd(_ value: Decimal) -> String {
        let number = usdFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "0"
        return "$\(number)"
    }
}
