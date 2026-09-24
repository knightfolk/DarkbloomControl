import DarkbloomTelemetry
import Foundation
import Testing
@testable import DarkbloomMonitor

/// Synthetic resolution tests for the app's local chat endpoint provider:
/// authenticated unified endpoints, explicitly unauthenticated (`--no-auth`)
/// endpoints, standalone discovery with and without a bearer token, and the
/// fail-closed required-token case. No live provider or credentials.
@Suite("Chat local endpoint provider")
@MainActor
struct ChatLocalEndpointProviderTests {
    /// Creates an isolated preferences domain seeded with one hosting
    /// configuration. Each test removes the domain with `defer` so no
    /// synthetic test leaves preferences behind.
    private func makeDefaults(
        mode: HostingEndpointMode,
        requiresAuthentication: Bool
    ) throws -> (defaults: UserDefaults, suite: String) {
        let suite = "ChatEndpointProvider-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(mode.rawValue, forKey: HostingSettingsStore.modeKey)
        defaults.set(8123, forKey: HostingSettingsStore.portKey)
        defaults.set("127.0.0.1", forKey: HostingSettingsStore.bindAddressKey)
        defaults.set(requiresAuthentication, forKey: HostingSettingsStore.requiresAuthenticationKey)
        return (defaults, suite)
    }

    private func makeProvider(
        defaults: UserDefaults,
        token: String?,
        availability: LocalEndpointAvailability = .none("No live local endpoint is advertised")
    ) -> AppLocalEndpointProvider {
        AppLocalEndpointProvider(
            defaults: defaults,
            tokenFile: ProviderTokenFileFake(token: token),
            standaloneClient: ProviderEndpointFake(availability: availability)
        )
    }

    @Test("unified hosting with authentication resolves the token-bearing endpoint")
    func unifiedAuthenticated() async throws {
        let scoped = try makeDefaults(mode: .unified, requiresAuthentication: true)
        defer { scoped.defaults.removePersistentDomain(forName: scoped.suite) }
        let provider = makeProvider(defaults: scoped.defaults, token: "dk-local-synthetic-token-1234")
        let endpoint = try #require(await provider.endpoint())
        #expect(endpoint.isAuthenticated)
        #expect(endpoint.origin.absoluteString == "http://127.0.0.1:8123")
    }

    @Test("unified hosting fails closed when the required token is unavailable")
    func unifiedMissingTokenFailsClosed() async throws {
        let scoped = try makeDefaults(mode: .unified, requiresAuthentication: true)
        defer { scoped.defaults.removePersistentDomain(forName: scoped.suite) }
        let provider = makeProvider(defaults: scoped.defaults, token: nil)
        #expect(await provider.endpoint() == nil)
    }

    @Test("unified hosting with disabled authentication resolves an unauthenticated endpoint")
    func unifiedNoAuth() async throws {
        let scoped = try makeDefaults(mode: .unified, requiresAuthentication: false)
        defer { scoped.defaults.removePersistentDomain(forName: scoped.suite) }
        // The settings' explicit choice wins even when a token exists.
        let provider = makeProvider(defaults: scoped.defaults, token: nil)
        let endpoint = try #require(await provider.endpoint())
        #expect(endpoint.isAuthenticated == false)
        #expect(endpoint.origin.absoluteString == "http://127.0.0.1:8123")

        let withTokenOnDisk = makeProvider(defaults: scoped.defaults, token: "dk-local-synthetic-token-1234")
        #expect(try #require(await withTokenOnDisk.endpoint()).isAuthenticated == false)
    }

    @Test("standalone discovery uses the record's bearer token when present")
    func standaloneAuthenticated() async throws {
        let scoped = try makeDefaults(mode: .standalone, requiresAuthentication: true)
        defer { scoped.defaults.removePersistentDomain(forName: scoped.suite) }
        let provider = makeProvider(
            defaults: scoped.defaults,
            token: nil,
            availability: .live(record(apiKey: "dk-local-synthetic-record-key"))
        )
        let endpoint = try #require(await provider.endpoint())
        #expect(endpoint.isAuthenticated)
        #expect(endpoint.origin.absoluteString == "http://192.168.1.5:9001")
    }

    @Test("a standalone record without a bearer token resolves unauthenticated")
    func standaloneNoAuth() async throws {
        let scoped = try makeDefaults(mode: .standalone, requiresAuthentication: true)
        defer { scoped.defaults.removePersistentDomain(forName: scoped.suite) }
        let provider = makeProvider(
            defaults: scoped.defaults,
            token: nil,
            availability: .live(record(apiKey: ""))
        )
        let endpoint = try #require(await provider.endpoint())
        #expect(endpoint.isAuthenticated == false)
        #expect(endpoint.origin.absoluteString == "http://192.168.1.5:9001")
    }

    @Test("no live standalone advertisement resolves nothing")
    func standaloneNone() async throws {
        let scoped = try makeDefaults(mode: .standalone, requiresAuthentication: true)
        defer { scoped.defaults.removePersistentDomain(forName: scoped.suite) }
        let provider = makeProvider(defaults: scoped.defaults, token: "dk-local-synthetic-token-1234")
        #expect(await provider.endpoint() == nil)
    }

    private func record(apiKey: String) -> LocalEndpointRecord {
        LocalEndpointRecord(
            baseURL: "http://192.168.1.5:9001",
            apiKey: apiKey,
            host: "192.168.1.5",
            port: 9_001,
            processID: 4_242
        )
    }
}

private struct ProviderTokenFileFake: LocalEndpointTokenProviding {
    private let token: String?
    init(token: String?) { self.token = token }

    @discardableResult
    func withBearerToken(_ action: (String) -> Void) -> Bool {
        guard let token else { return false }
        action(token)
        return true
    }
}

private struct ProviderEndpointFake: LocalEndpointFetching {
    private let availability: LocalEndpointAvailability
    init(availability: LocalEndpointAvailability) { self.availability = availability }

    func fetch() async -> LocalEndpointAvailability { availability }
}
