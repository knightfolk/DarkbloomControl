import Foundation
import Security

/// Format validation for a consumer API key pasted by the user. Validation is
/// purely structural; it cannot tell a real key from a synthetic test value.
public enum ConsumerAPIKey {
    public static let maximumUTF8Bytes = 256

    /// A usable key is nonblank, at most 256 UTF-8 bytes, and contains no
    /// whitespace or control characters. Trailing whitespace is tolerated and
    /// trimmed by the store.
    public static func isValid(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    public static func trimmed(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ConsumerKeyStoreError: Error, Equatable, Sendable {
    case invalidKey
    /// Carries only the Security framework status code, never key material.
    case keychainFailure(Int32)
}

extension ConsumerKeyStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            "That does not look like a consumer API key. Keys have no spaces and are at most 256 characters."
        case .keychainFailure(let status):
            "macOS Keychain refused the operation (status \(status))."
        }
    }
}

/// Read access to the stored consumer API key. The key is observable only
/// inside the closure, mirroring `LocalEndpointTokenFile`, so it is never
/// held as a loggable property. The consumer key is a distinct credential
/// from the provider device token and the local endpoint token; nothing may
/// substitute one for another.
public protocol ConsumerKeyReading: Sendable {
    @discardableResult
    func withConsumerKey<R>(_ body: (String) throws -> R) rethrows -> R?
    var hasKey: Bool { get }
}

/// Key management on top of read access. Implemented by the Keychain store
/// and by in-memory test fakes; the app never persists the key anywhere else.
public protocol ConsumerKeyManaging: ConsumerKeyReading {
    func store(_ key: String) throws
    func remove()
}

/// Stores the Darkbloom consumer API key in the macOS Keychain as a
/// this-device-only generic password. It is never written to UserDefaults,
/// files, or logs. Failures surface the Security status code only.
public struct KeychainConsumerKeyStore: ConsumerKeyManaging, Sendable {
    public static let defaultService = "dev.darkbloom.control.consumer-chat-key"

    private let service: String
    private let account: String

    public init(service: String = KeychainConsumerKeyStore.defaultService, account: String = "default") {
        self.service = service
        self.account = account
    }

    public func store(_ key: String) throws {
        let trimmed = ConsumerAPIKey.trimmed(key)
        guard ConsumerAPIKey.isValid(trimmed) else {
            throw ConsumerKeyStoreError.invalidKey
        }
        let data = Data(trimmed.utf8)
        let attributes = baseQuery()
        let status = SecItemAdd(
            attributes.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]) { current, _ in current } as CFDictionary,
            nil
        )
        guard status != errSecSuccess else { return }
        guard status == errSecDuplicateItem else {
            throw ConsumerKeyStoreError.keychainFailure(status)
        }
        let updateStatus = SecItemUpdate(
            attributes as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw ConsumerKeyStoreError.keychainFailure(updateStatus)
        }
    }

    public func remove() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    public func withConsumerKey<R>(_ body: (String) throws -> R) rethrows -> R? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              ConsumerAPIKey.isValid(key)
        else { return nil }
        return try body(key)
    }

    public var hasKey: Bool {
        withConsumerKey { _ in true } ?? false
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
