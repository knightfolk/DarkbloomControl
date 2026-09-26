import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

public enum SpikeRole: String, Sendable { case host, phone }

/// Synthetic, ephemeral software keys for this standalone transport experiment only.
/// This deliberately does not implement production persistence or Secure Enclave enrollment.
public struct SpikeIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    public let spkiSHA256: Data
    // Non-secret, per-instance lookup scope for auditing this synthetic key's lifetime.
    let keyApplicationTag: Data

    public static func make(role: SpikeRole, now: Date = Date(), validFrom: Date? = nil, validUntil: Date? = nil) throws -> SpikeIdentity {
        let keyApplicationTag = Data("dev.darkbloom.companion-spike.ephemeral.\(UUID().uuidString)".utf8)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false,
            kSecAttrApplicationTag: keyApplicationTag,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw IdentityError.keyCreationFailed
        }
        let privateKey = try Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("Synthetic companion spike \(role.rawValue)") }
        var extensions = try [
            Certificate.Extension(BasicConstraints.notCertificateAuthority, critical: true),
            Certificate.Extension(KeyUsage(digitalSignature: true), critical: true),
            Certificate.Extension(ExtendedKeyUsage([role == .host ? .serverAuth : .clientAuth]), critical: false),
        ]
        if role == .host {
            extensions.append(try Certificate.Extension(
                SubjectAlternativeNames([.dnsName("companion-spike.invalid")]), critical: false
            ))
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: validFrom ?? now.addingTimeInterval(-60),
            notValidAfter: validUntil ?? now.addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(extensions),
            issuerPrivateKey: privateKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let nativeCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw IdentityError.certificateCreationFailed
        }
        guard let identity = SecIdentityCreate(nil, nativeCertificate, key) else {
            throw IdentityError.identityCreationFailed
        }
        return try SpikeIdentity(
            identity: identity, certificate: nativeCertificate,
            spkiSHA256: canonicalSPKIHash(certificate.publicKey), keyApplicationTag: keyApplicationTag
        )
    }

    private enum IdentityError: Error { case keyCreationFailed, certificateCreationFailed, identityCreationFailed }
}

/// Closed, pinned single-leaf trust profile; never consults or changes system trust.
public enum SpikeTrust {
    public static func validate(_ certificates: [SecCertificate], expectedSPKI: Data, role: SpikeRole, now: Date = Date()) -> Bool {
        guard certificates.count == 1, expectedSPKI.count == 32 else { return false }
        do {
            let certificate = try Certificate(certificates[0])
            guard certificate.version == .v3,
                  certificate.issuer == certificate.subject,
                  certificate.notValidBefore <= now, now <= certificate.notValidAfter,
                  P256.Signing.PublicKey(certificate.publicKey) != nil,
                  certificate.signatureAlgorithm == .ecdsaWithSHA256,
                  certificate.publicKey.isValidSignature(certificate.signature, for: certificate),
                  try canonicalSPKIHash(certificate.publicKey) == expectedSPKI,
                  try certificate.extensions.basicConstraints == .notCertificateAuthority,
                  certificate.extensions[oid: .X509ExtensionID.basicConstraints]?.critical == true,
                  try certificate.extensions.keyUsage == KeyUsage(digitalSignature: true),
                  certificate.extensions[oid: .X509ExtensionID.keyUsage]?.critical == true,
                  let eku = try certificate.extensions.extendedKeyUsage,
                  Array(eku) == [role == .host ? .serverAuth : .clientAuth]
            else { return false }

            // Reject unhandled critical constraints instead of silently granting trust.
            let understood: Set<ASN1ObjectIdentifier> = [
                .X509ExtensionID.basicConstraints, .X509ExtensionID.keyUsage,
                .X509ExtensionID.extendedKeyUsage, .X509ExtensionID.subjectAlternativeName,
            ]
            guard certificate.extensions.allSatisfy({ !$0.critical || understood.contains($0.oid) }) else { return false }
            // Parse SAN whenever supplied, even though the pin, not DNS, is the peer identity.
            _ = try certificate.extensions.subjectAlternativeNames
            return true
        } catch {
            return false
        }
    }
}

private func canonicalSPKIHash(_ publicKey: Certificate.PublicKey) throws -> Data {
    var serializer = DER.Serializer()
    try serializer.serialize(publicKey)
    return Data(SHA256.hash(data: Data(serializer.serializedBytes)))
}
