import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns updates to this app only. Sparkle verifies and installs signed archives.
@MainActor
final class ControlAppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = ControlAppUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticInstall = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var message = "Updates are available in release builds."
    @Published private(set) var isConfigured = false
    private var controller: SPUStandardUpdaterController?
    private var resumeTask: Task<Void, Never>?
    var canRelaunch: () -> Bool = { true }

    static func hasValidConfiguration(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }

    func start(bundle: Bundle = .main) {
        guard controller == nil, bundle.bundleURL.pathExtension == "app",
              Self.hasValidConfiguration(
                feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticInstall)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        do {
            try updater.start()
            isConfigured = true
            message = "Check for a newer version of Darkbloom Control."
        } catch {
            message = "App updates could not start. Reopen a release build to try again."
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard isConfigured, let updater = controller?.updater else { return }
        if !enabled { updater.automaticallyDownloadsUpdates = false }
        updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticInstall(_ enabled: Bool) {
        guard isConfigured, let updater = controller?.updater else { return }
        if enabled { updater.automaticallyChecksForUpdates = true }
        updater.automaticallyDownloadsUpdates = enabled
    }

    func check() {
        guard canCheck else { return }
        message = "Checking for updates…"
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = "Version \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        message = "Darkbloom Control is up to date."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        if (error as NSError).domain == SUSparkleErrorDomain,
           (error as NSError).code == SUError.noUpdateError.rawValue {
            message = "Darkbloom Control is up to date."
            return
        }
        message = "The update did not finish. Check again to retry."
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !canRelaunch() else { return false }
        message = "Update ready. Finish or discard edits and pending provider actions to restart Control."
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            while let self, !self.canRelaunch() {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}

struct ControlAppUpdateSettings: View {
    @ObservedObject var updater = ControlAppUpdater.shared
    var body: some View {
        Section("Darkbloom Control · App updates") {
            LabeledContent("Installed version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build")
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
                .disabled(!updater.isConfigured)
            Toggle("Automatically download and install", isOn: Binding(
                get: { updater.automaticInstall }, set: updater.setAutomaticInstall))
                .disabled(!updater.isConfigured || !updater.automaticChecks)
            Text("Automatic installation completes when Control quits. The provider keeps running.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(updater.message)
                    if let date = updater.lastChecked {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck)
            }
            Text("If an update is available, the update window offers Download and Install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
