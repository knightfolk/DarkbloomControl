import Darwin
import Foundation

/// The officially documented local-serving modes of `darkbloom start`.
public enum HostingEndpointMode: String, CaseIterable, Sendable, Equatable {
    /// No local endpoint flags. The provider serves the coordinator fleet only.
    case off
    /// `--local-endpoint`: the local OpenAI-compatible endpoint runs alongside
    /// coordinator serving. Fleet traffic keeps earning; local and fleet
    /// requests share one engine and model slots through the normal provider
    /// registration, so applying it replaces the provider with a drained
    /// handoff exactly like the existing start path.
    case unified
    /// `--local`: standalone coordinator-less direct mode. The official CLI
    /// runs it in the foreground, so this app cannot own or terminate it
    /// safely. The settings surface can still show and copy its CLI command.
    case standalone

    public var isDispatchable: Bool { self != .standalone }

    /// Fixed, non-secret reason shown when standalone mode is selected.
    public static let standaloneUnavailableReason = String(
        localized: "Local-only serving runs in the foreground. This app cannot supervise or stop it safely; copy the command below and run it in Terminal if you need coordinator-less serving."
    )
}

/// How widely the local endpoint accepts connections.
public enum HostingBindScope: Equatable, Sendable {
    /// The documented default `--bind 127.0.0.1`: only this Mac.
    case loopback
    /// One specific interface address, such as an active LAN or tailnet address.
    case specificInterface
    /// `--bind 0.0.0.0`: every interface. The widest possible exposure.
    case allInterfaces
}

/// Monitor-owned start-flag preferences for the official local endpoint.
/// These are application preferences, not provider configuration fields: they
/// are applied only through the official non-interactive `darkbloom start`
/// command and are never written into `provider.toml`.
public struct HostingOptions: Equatable, Sendable {
    public static let loopbackBindAddress = "127.0.0.1"
    public static let allInterfacesBindAddress = "0.0.0.0"
    /// The port the official CLI uses when `--port` is not passed.
    public static let defaultPort: UInt16 = 8000

    public var mode: HostingEndpointMode
    public var port: UInt16
    public var bindAddress: String
    public var requiresAuthentication: Bool

    public init(
        mode: HostingEndpointMode,
        port: UInt16 = HostingOptions.defaultPort,
        bindAddress: String = HostingOptions.loopbackBindAddress,
        requiresAuthentication: Bool = true
    ) {
        self.mode = mode
        self.port = port
        self.bindAddress = bindAddress
        self.requiresAuthentication = requiresAuthentication
    }

    /// No endpoint: the monitor's historical behavior before hosting existed.
    public static let `default` = HostingOptions(mode: .off)

    public var bindScope: HostingBindScope {
        HostingAddressPolicy.bindScope(for: bindAddress)
    }

    public var usesLoopback: Bool { bindScope == .loopback }

    /// Any non-loopback bind of an active endpoint is a network exposure that
    /// the user must confirm explicitly before it is applied.
    public var requiresLANConfirmation: Bool {
        mode != .off && bindScope != .loopback
    }

    /// Every network-exposed or unauthenticated endpoint requires a fresh
    /// confirmation before the CLI is asked to apply it.
    public var requiresExposureConfirmation: Bool {
        mode != .off && (requiresLANConfirmation || !requiresAuthentication)
    }

    public var isValid: Bool {
        guard HostingAddressPolicy.isSupportedBindAddress(bindAddress) else { return false }
        return mode == .off || port > 0
    }

    /// The official `darkbloom start` argument suffix for these options.
    /// `--port` and `--bind` are always explicit for an active endpoint so the
    /// dispatched command documents the exact exposure instead of relying on
    /// CLI defaults. Authentication remains enabled unless the user explicitly
    /// opts out and confirms the resulting exposure in the app.
    public var startArguments: [String] {
        let authArguments = requiresAuthentication ? [] : ["--no-auth"]
        switch mode {
        case .off:
            return []
        case .unified:
            return ["--local-endpoint", "--port", String(port), "--bind", bindAddress] + authArguments
        case .standalone:
            return ["--local", "--port", String(port), "--bind", bindAddress] + authArguments
        }
    }
}

public enum HostingAddressPolicy {
    public static func isValidIPv4Address(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= Int(INET_ADDRSTRLEN) else { return false }
        var address = in_addr()
        return value.withCString { pointer in
            inet_pton(AF_INET, pointer, &address) == 1
        }
    }

    /// Private-use IPv4 ranges (RFC 1918) only. Loopback and link-local
    /// addresses are intentionally not "private LAN" candidates.
    public static func isPrivateIPv4Address(_ value: String) -> Bool {
        guard let octets = ipv4Octets(value) else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        return false
    }

    /// Tailscale uses the shared address space 100.64.0.0/10. These addresses
    /// are not RFC 1918 private addresses, but are a supported private-device
    /// path for the CLI's local endpoint.
    public static func isTailnetIPv4Address(_ value: String) -> Bool {
        guard let octets = ipv4Octets(value) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Permit this Mac, an active RFC 1918/tailnet interface, or the explicitly
    /// confirmed all-interface bind. Public and malformed addresses are not
    /// accepted by the app even though the CLI accepts a string.
    public static func isSupportedBindAddress(_ value: String) -> Bool {
        value == HostingOptions.loopbackBindAddress
            || value == HostingOptions.allInterfacesBindAddress
            || isPrivateIPv4Address(value)
            || isTailnetIPv4Address(value)
    }

    public static func bindScope(for address: String) -> HostingBindScope {
        guard isValidIPv4Address(address) else { return .specificInterface }
        if address == HostingOptions.loopbackBindAddress { return .loopback }
        if address == HostingOptions.allInterfacesBindAddress { return .allInterfaces }
        return .specificInterface
    }

    private static func ipv4Octets(_ value: String) -> [UInt8]? {
        var address = in_addr()
        let parsed = value.withCString { pointer in
            inet_pton(AF_INET, pointer, &address) == 1
        }
        guard parsed else { return nil }
        let raw = address.s_addr
        return [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF),
        ]
    }
}

/// Enumerates this Mac's active RFC 1918 and tailnet IPv4 addresses so hosting
/// can prefer one specific interface over all interfaces. Reading the
/// interface list is the only system introspection; no hostname or interface
/// names leave this type.
public enum LANAddressScanner {
    public static func activePrivateIPv4Addresses() -> [String] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return [] }
        defer { freeifaddrs(interfaceList) }

        var found = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  let sockaddr = interface.ifa_addr,
                  sockaddr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var address = sockaddr.pointee
            let text = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inetAddress in
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var value = inetAddress.pointee.sin_addr
                    if inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
                        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
                        return String(decoding: bytes, as: UTF8.self)
                    }
                    return ""
                }
            }
            guard !text.isEmpty,
                  HostingAddressPolicy.isPrivateIPv4Address(text)
                    || HostingAddressPolicy.isTailnetIPv4Address(text)
            else { continue }
            found.insert(text)
        }
        return found.sorted()
    }
}

/// Runtime capability gate for hosting. The local endpoint flags and the
/// `darkbloom local` discovery command are used exactly as documented in the
/// official provider CLI reference; 0.9.7 is the earliest CLI release this app
/// has verified against that reference. Older or unknown CLI versions surface
/// hosting as unavailable instead of attempting unverified flags.
public enum HostingCapability: Equatable, Sendable {
    public static let minimumCLIVersion = "0.9.7"

    public static func supportsHostServing(cliVersion: String?) -> Bool {
        guard let own = versionTuple(minimumCLIVersion),
              let observed = versionTuple(cliVersion)
        else { return false }
        return observed >= own
    }

    /// Accepts a leading numeric `major.minor.patch` and ignores pre-release
    /// or build metadata suffixes, mirroring the CLI's banner format.
    static func versionTuple(_ value: String?) -> (Int, Int, Int)? {
        guard let value,
              let prefix = value.split(separator: "-", maxSplits: 1).first,
              let core = prefix.split(separator: "+", maxSplits: 1).first
        else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0, number <= 100_000 else { return nil }
            numbers.append(number)
        }
        return (numbers[0], numbers[1], numbers[2])
    }
}
