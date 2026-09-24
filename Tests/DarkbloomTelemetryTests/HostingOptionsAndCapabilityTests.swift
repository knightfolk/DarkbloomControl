import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Hosting options and capability")
struct HostingOptionsAndCapabilityTests {
    @Test("defaults keep the endpoint off on loopback")
    func safeDefaults() {
        let options = HostingOptions.default
        #expect(options.mode == .off)
        #expect(options.port == 8000)
        #expect(options.bindAddress == "127.0.0.1")
        #expect(options.usesLoopback)
        #expect(options.requiresAuthentication)
        #expect(!options.requiresLANConfirmation)
        #expect(!options.requiresExposureConfirmation)
        #expect(options.isValid)
    }

    @Test("bind addresses classify into loopback, specific, and all interfaces")
    func bindScopes() {
        #expect(HostingAddressPolicy.bindScope(for: "127.0.0.1") == .loopback)
        #expect(HostingAddressPolicy.bindScope(for: "0.0.0.0") == .allInterfaces)
        #expect(HostingAddressPolicy.bindScope(for: "192.168.1.5") == .specificInterface)
        #expect(HostingAddressPolicy.bindScope(for: "10.0.0.2") == .specificInterface)
        #expect(HostingAddressPolicy.bindScope(for: "8.8.8.8") == .specificInterface)
        #expect(HostingAddressPolicy.bindScope(for: "not-an-address") == .specificInterface)
    }

    @Test("only valid IPv4 literals are accepted")
    func addressValidation() {
        for value in ["127.0.0.1", "0.0.0.0", "10.1.2.3", "172.16.0.1", "192.168.0.1"] {
            #expect(HostingAddressPolicy.isValidIPv4Address(value), "expected \(value) to be valid")
        }
        for value in ["", "localhost", "999.1.1.1", "1.2.3", "::1", "1.2.3.4.5", "1.2.3.4 "] {
            #expect(!HostingAddressPolicy.isValidIPv4Address(value), "expected \(value) to be invalid")
        }
    }

    @Test("private ranges cover RFC 1918 only")
    func privateRanges() {
        for value in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.168.255.255"] {
            #expect(HostingAddressPolicy.isPrivateIPv4Address(value), "expected \(value) private")
        }
        for value in ["172.32.0.1", "172.15.255.255", "11.0.0.1", "8.8.8.8", "169.254.1.1", "127.0.0.1"] {
            #expect(!HostingAddressPolicy.isPrivateIPv4Address(value), "expected \(value) not private")
        }
    }

    @Test("Tailscale shared addresses are supported but public addresses are not")
    func tailscaleAddressSupport() {
        #expect(HostingAddressPolicy.isTailnetIPv4Address("100.64.0.1"))
        #expect(HostingAddressPolicy.isTailnetIPv4Address("100.127.255.254"))
        #expect(!HostingAddressPolicy.isTailnetIPv4Address("100.63.255.255"))
        #expect(!HostingAddressPolicy.isTailnetIPv4Address("100.128.0.1"))
        #expect(HostingOptions(mode: .unified, bindAddress: "100.101.22.3").isValid)
        #expect(!HostingOptions(mode: .unified, bindAddress: "8.8.8.8").isValid)
    }

    @Test("LAN confirmation is required for every non-loopback active endpoint")
    func lanConfirmationGate() {
        #expect(!HostingOptions(mode: .off, bindAddress: "192.168.1.5").requiresLANConfirmation)
        #expect(!HostingOptions(mode: .unified, bindAddress: "127.0.0.1").requiresLANConfirmation)
        #expect(HostingOptions(mode: .unified, bindAddress: "192.168.1.5").requiresLANConfirmation)
        #expect(HostingOptions(mode: .unified, bindAddress: "0.0.0.0").requiresLANConfirmation)
        #expect(HostingOptions(mode: .standalone, bindAddress: "0.0.0.0").requiresLANConfirmation)
    }

    @Test("network exposure and authentication opt-out each require confirmation")
    func exposureConfirmationGate() {
        #expect(!HostingOptions(mode: .off, requiresAuthentication: false).requiresExposureConfirmation)
        #expect(!HostingOptions(mode: .unified).requiresExposureConfirmation)
        #expect(HostingOptions(mode: .unified, bindAddress: "100.101.22.3").requiresExposureConfirmation)
        #expect(HostingOptions(mode: .unified, requiresAuthentication: false).requiresExposureConfirmation)
    }

    @Test("invalid addresses make options invalid regardless of mode")
    func optionValidity() {
        #expect(HostingOptions(mode: .unified, bindAddress: "192.168.1.5").isValid)
        #expect(HostingOptions(mode: .unified, port: 0).isValid == false)
        #expect(HostingOptions(mode: .off, port: 0).isValid)
        #expect(!HostingOptions(mode: .unified, bindAddress: "8.8.8.8").isValid)
        #expect(!HostingOptions(mode: .unified, bindAddress: "banana").isValid)
        #expect(!HostingOptions(mode: .off, bindAddress: "banana").isValid)
    }

    @Test("standalone mode is represented but never dispatchable")
    func standaloneIsUnavailable() {
        #expect(HostingEndpointMode.standalone.isDispatchable == false)
        #expect(HostingEndpointMode.off.isDispatchable)
        #expect(HostingEndpointMode.unified.isDispatchable)
        #expect(!HostingEndpointMode.standaloneUnavailableReason.isEmpty)
        #expect(!HostingEndpointMode.standaloneUnavailableReason.contains("Terminal.app"))
    }

    @Test("capability requires a verified CLI version")
    func capabilityGate() {
        #expect(HostingCapability.supportsHostServing(cliVersion: "0.9.7"))
        #expect(HostingCapability.supportsHostServing(cliVersion: "0.9.8"))
        #expect(HostingCapability.supportsHostServing(cliVersion: "0.10.0"))
        #expect(HostingCapability.supportsHostServing(cliVersion: "1.0.0"))
        #expect(HostingCapability.supportsHostServing(cliVersion: "0.9.7-rc.1+build.3"))
        #expect(!HostingCapability.supportsHostServing(cliVersion: "0.9.6"))
        #expect(!HostingCapability.supportsHostServing(cliVersion: "0.8.15"))
        #expect(!HostingCapability.supportsHostServing(cliVersion: "unknown"))
        #expect(!HostingCapability.supportsHostServing(cliVersion: nil))
        #expect(!HostingCapability.supportsHostServing(cliVersion: ""))
    }
}
