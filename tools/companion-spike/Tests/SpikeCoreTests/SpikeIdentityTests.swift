import CryptoKit
import Foundation
import Security
import SwiftASN1
import XCTest
import X509
@testable import SpikeCore

final class SpikeIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRespectiveRolesValidateWithTheirCanonicalSPKIPins() throws {
        for role in [SpikeRole.host, .phone] {
            let identity = try SpikeIdentity.make(role: role, now: now)
            XCTAssertTrue(SpikeTrust.validate([identity.certificate], expectedSPKI: identity.spkiSHA256, role: role, now: now))
            let key = try XCTUnwrap(SecCertificateCopyKey(identity.certificate))
            let bytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, nil)) as Data
            let publicKey = try P256.Signing.PublicKey(x963Representation: bytes)
            XCTAssertEqual(identity.spkiSHA256, Data(SHA256.hash(data: publicKey.derRepresentation)))
        }
    }

    func testWrongPinAndWrongRoleAreRejected() throws {
        let identity = try SpikeIdentity.make(role: .host, now: now)
        XCTAssertFalse(SpikeTrust.validate([identity.certificate], expectedSPKI: Data(repeating: 0, count: 32), role: .host, now: now))
        XCTAssertFalse(SpikeTrust.validate([identity.certificate], expectedSPKI: identity.spkiSHA256, role: .phone, now: now))
        XCTAssertFalse(SpikeTrust.validate([identity.certificate], expectedSPKI: Data(), role: .host, now: now))
    }

    func testExpiredAndFutureCertificatesAreRejected() throws {
        let expired = try SpikeIdentity.make(role: .host, now: now, validFrom: now.addingTimeInterval(-120), validUntil: now.addingTimeInterval(-1))
        let future = try SpikeIdentity.make(role: .host, now: now, validFrom: now.addingTimeInterval(1), validUntil: now.addingTimeInterval(120))
        for identity in [expired, future] {
            XCTAssertFalse(SpikeTrust.validate([identity.certificate], expectedSPKI: identity.spkiSHA256, role: .host, now: now))
        }
    }

    func testEmptyAndMultiCertificateChainsAreRejected() throws {
        let identity = try SpikeIdentity.make(role: .host, now: now)
        XCTAssertFalse(SpikeTrust.validate([], expectedSPKI: identity.spkiSHA256, role: .host, now: now))
        XCTAssertFalse(SpikeTrust.validate([identity.certificate, identity.certificate], expectedSPKI: identity.spkiSHA256, role: .host, now: now))
    }

    func testIndependentIdentitiesHaveDifferentKeys() throws {
        let first = try SpikeIdentity.make(role: .phone, now: now)
        let second = try SpikeIdentity.make(role: .phone, now: now)
        XCTAssertNotEqual(first.spkiSHA256, second.spkiSHA256)
    }

    func testNativeIdentityRoundtripAndSigning() throws {
        let identity = try SpikeIdentity.make(role: .host, now: now)
        var certificate: SecCertificate?
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyCertificate(identity.identity, &certificate), errSecSuccess)
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity.identity, &key), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(certificate)) as Data, SecCertificateCopyData(identity.certificate) as Data)
        let message = Data("synthetic spike challenge".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(try XCTUnwrap(key), .ecdsaSignatureMessageX962SHA256, message as CFData, nil))
        XCTAssertTrue(SecKeyVerifySignature(try XCTUnwrap(SecCertificateCopyKey(identity.certificate)), .ecdsaSignatureMessageX962SHA256, message as CFData, signature, nil))
    }

    func testSyntheticIdentityKeysAreAbsentFromKeychain() throws {
        for role in [SpikeRole.host, .phone] {
            let scope = try autoreleasepool { () throws -> (tag: Data, label: Data) in
                let identity = try SpikeIdentity.make(role: role, now: now)
                var key: SecKey?
                XCTAssertEqual(SecIdentityCopyPrivateKey(identity.identity, &key), errSecSuccess)
                let attributes = try XCTUnwrap(SecKeyCopyAttributes(try XCTUnwrap(key))) as NSDictionary
                let label = try XCTUnwrap(attributes[kSecAttrApplicationLabel] as? Data)
                try assertKeychainAbsence(tag: identity.keyApplicationTag, label: label)
                return (identity.keyApplicationTag, label)
            }
            try assertKeychainAbsence(tag: scope.tag, label: scope.label)
        }
    }

    private func assertKeychainAbsence(tag: Data, label: Data) throws {
        // Apple's local EC attribute dictionary reports IsPermanent=true even for
        // ephemeral iOS keys. Query actual storage by this instance's unique tag
        // and independently by its public-key label; never enumerate the Keychain.
        for (selector, value) in [(kSecAttrApplicationTag, tag), (kSecAttrApplicationLabel, label)] {
            for keyClass in [kSecAttrKeyClassPrivate, kSecAttrKeyClassPublic] {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassKey,
                    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: keyClass,
                    selector: value,
                    kSecMatchLimit: kSecMatchLimitOne,
                    kSecReturnAttributes: true,
                ]
                let status = SecItemCopyMatching(query as CFDictionary, nil)
                #if os(iOS)
                if status == errSecMissingEntitlement {
                    throw XCTSkip("Keychain absence proof requires an entitled iOS test host; signing and identity validation remain tested separately.")
                }
                #endif
                XCTAssertEqual(status, errSecItemNotFound, "This exact synthetic key must not be persisted")
            }
        }
    }

    func testCAAndMissingOrOverbroadUsageProfilesAreRejected() throws {
        let profiles: [[Certificate.Extension]] = [
            try extensions(ca: true),
            try extensions(usage: KeyUsage(keyEncipherment: true)),
            try extensions(usage: KeyUsage(digitalSignature: true, keyCertSign: true)),
            try extensions(eku: [.serverAuth, .clientAuth]),
            try extensions(eku: [.any]),
            try extensions().filter { $0.oid != .X509ExtensionID.extendedKeyUsage },
            try extensions().filter { $0.oid != .X509ExtensionID.basicConstraints },
            try extensions().filter { $0.oid != .X509ExtensionID.keyUsage },
        ]
        for profile in profiles {
            let fixture = try fixture(extensions: profile)
            XCTAssertFalse(SpikeTrust.validate([fixture.certificate], expectedSPKI: fixture.pin, role: .host, now: now))
        }
    }

    func testNonSelfSignedAndWrongIssuerCertificatesAreRejected() throws {
        for fixture in [try fixture(wrongSigner: true), try fixture(wrongIssuer: true)] {
            XCTAssertFalse(SpikeTrust.validate([fixture.certificate], expectedSPKI: fixture.pin, role: .host, now: now))
        }
    }

    func testP384AndUnknownCriticalExtensionsAreRejected() throws {
        let p384 = try fixture(p384: true)
        XCTAssertFalse(SpikeTrust.validate([p384.certificate], expectedSPKI: p384.pin, role: .host, now: now))
        var profile = try extensions()
        profile.append(Certificate.Extension(oid: [1, 2, 3, 4, 5], critical: true, value: [5, 0]))
        let unknown = try fixture(extensions: profile)
        XCTAssertFalse(SpikeTrust.validate([unknown.certificate], expectedSPKI: unknown.pin, role: .host, now: now))
    }

    func testNoncriticalConstraintsAreRejected() throws {
        var noncriticalCA = try extensions()
        noncriticalCA[0] = try Certificate.Extension(BasicConstraints.notCertificateAuthority, critical: false)
        var noncriticalUsage = try extensions()
        noncriticalUsage[1] = try Certificate.Extension(KeyUsage(digitalSignature: true), critical: false)
        for profile in [noncriticalCA, noncriticalUsage] {
            let fixture = try fixture(extensions: profile)
            XCTAssertFalse(SpikeTrust.validate([fixture.certificate], expectedSPKI: fixture.pin, role: .host, now: now))
        }
    }

    func testCorruptedSignatureIsRejectedEvenWithCorrectPin() throws {
        let identity = try SpikeIdentity.make(role: .host, now: now)
        var der = SecCertificateCopyData(identity.certificate) as Data
        der[der.count - 1] ^= 1
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertFalse(SpikeTrust.validate([certificate], expectedSPKI: identity.spkiSHA256, role: .host, now: now))
    }

    private func extensions(ca: Bool = false, usage: KeyUsage = KeyUsage(digitalSignature: true), eku: [ExtendedKeyUsage.Usage] = [.serverAuth]) throws -> [Certificate.Extension] {
        try [
            Certificate.Extension(ca ? BasicConstraints.isCertificateAuthority(maxPathLength: nil) : .notCertificateAuthority, critical: true),
            Certificate.Extension(usage, critical: true),
            Certificate.Extension(ExtendedKeyUsage(eku), critical: false),
            Certificate.Extension(SubjectAlternativeNames([.dnsName("companion-spike.invalid")]), critical: false),
        ]
    }

    private func fixture(extensions profile: [Certificate.Extension]? = nil, wrongSigner: Bool = false, wrongIssuer: Bool = false, p384: Bool = false) throws -> (certificate: SecCertificate, pin: Data) {
        let key = p384 ? Certificate.PrivateKey(P384.Signing.PrivateKey()) : Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName("Synthetic spike fixture") }
        let issuer = try DistinguishedName { CommonName("Different issuer") }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-60), notValidAfter: now.addingTimeInterval(60),
            issuer: wrongIssuer ? issuer : name, subject: name,
            signatureAlgorithm: p384 ? .ecdsaWithSHA384 : .ecdsaWithSHA256,
            extensions: Certificate.Extensions(profile ?? extensions()),
            issuerPrivateKey: wrongSigner ? Certificate.PrivateKey(P256.Signing.PrivateKey()) : key
        )
        var serializer = DER.Serializer()
        try serializer.serialize(key.publicKey)
        let pin = Data(SHA256.hash(data: Data(serializer.serializedBytes)))
        var der = DER.Serializer()
        try der.serialize(certificate)
        return (try XCTUnwrap(SecCertificateCreateWithData(nil, Data(der.serializedBytes) as CFData)), pin)
    }
}
