import DarkbloomTelemetry
import Foundation
import Testing

/// Safety tests for the Keychain-backed consumer key store. These only
/// perform an invalid-write rejection and read-only lookups against a
/// throwaway service name, so the user's real keychain is never modified.
@Suite("Consumer key keychain store")
struct ConsumerKeychainTests {
    @Test("invalid key material is rejected before any keychain write")
    func invalidWrite() {
        let store = KeychainConsumerKeyStore(service: "dev.darkbloom.test.\(UUID().uuidString)")
        #expect(throws: ConsumerKeyStoreError.invalidKey) {
            try store.store("has spaces")
        }
        #expect(throws: ConsumerKeyStoreError.invalidKey) {
            try store.store("")
        }
        #expect(store.hasKey == false)
    }

    @Test("a lookup for a nonexistent item returns nil without prompting")
    func missingItem() {
        let store = KeychainConsumerKeyStore(service: "dev.darkbloom.test.\(UUID().uuidString)")
        var observed: String?
        let found = store.withConsumerKey { key in
            observed = key
            return true
        }
        #expect(found == nil)
        #expect(observed == nil)
        #expect(store.hasKey == false)
    }

    @Test("error messages carry only fixed text and status codes, never key material")
    func sanitizedErrors() {
        #expect(ConsumerKeyStoreError.invalidKey.errorDescription?.contains("consumer API key") == true)
        let status = ConsumerKeyStoreError.keychainFailure(-34018)
        #expect(status.errorDescription?.contains("-34018") == true)
        #expect(status.errorDescription?.contains("Keychain") == true)
    }
}
