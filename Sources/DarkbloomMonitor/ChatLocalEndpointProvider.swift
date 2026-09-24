import DarkbloomTelemetry
import Foundation

/// Resolves the local chat endpoint from Sendable dependencies only, so the
/// telemetry client can call it from its own executor without crossing actor
/// isolation unsafely.
///
/// Unified mode (the recommended path) uses the Hosting settings' persisted
/// options and the provider-owned local token file; unified mode has no
/// discovery record, and `darkbloom local --json` does not discover it.
/// Standalone mode uses the documented on-demand discovery record.
///
/// Authentication policy: an endpoint is unauthenticated only when that is
/// explicit — unified hosting settings disabled authentication (`--no-auth`)
/// or the standalone record itself reports no bearer token. When
/// authentication is required but the token is unavailable, resolution fails
/// closed (nil) rather than silently dropping the credential. The consumer
/// API key is never used here.
struct AppLocalEndpointProvider: ChatLocalEndpointProviding {
    /// UserDefaults is documented thread-safe; it is not marked Sendable by
    /// Foundation, so the reference is wrapped for the Sendable provider.
    private final class DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
    }

    private let defaults: DefaultsBox
    private let tokenFile: any LocalEndpointTokenProviding
    private let standaloneClient: any LocalEndpointFetching

    init(
        defaults: UserDefaults = .standard,
        tokenFile: any LocalEndpointTokenProviding,
        standaloneClient: any LocalEndpointFetching
    ) {
        self.defaults = DefaultsBox(defaults)
        self.tokenFile = tokenFile
        self.standaloneClient = standaloneClient
    }

    func endpoint() async -> ChatLocalEndpoint? {
        let options = await MainActor.run { HostingSettingsStore.loadOptions(from: self.defaults.defaults) }
        if options.mode == .unified {
            guard let base = await MainActor.run(body: { HostingSettingsStore.endpointURL(from: options) }) else {
                return nil
            }
            if options.requiresAuthentication {
                // Fail closed: the endpoint demands a token that is absent.
                var token: String?
                tokenFile.withBearerToken { token = $0 }
                guard let token else { return nil }
                return ChatLocalEndpoint.make(baseURL: base, token: token)
            }
            // Explicitly unauthenticated (--no-auth): no Authorization header.
            return ChatLocalEndpoint.make(baseURL: base, token: nil)
        }
        guard case .live(let record) = await standaloneClient.fetch() else { return nil }
        if record.hasBearerToken {
            var token: String?
            record.withBearerToken { token = $0 }
            guard let token else { return nil }
            return ChatLocalEndpoint.make(baseURL: record.baseURL, token: token)
        }
        // The discovery record itself reports an unauthenticated server.
        return ChatLocalEndpoint.make(baseURL: record.baseURL, token: nil)
    }
}
