import Foundation
import IOKit

/// AppleSmartBattery is not a documented billing-grade sensor. This source
/// measures estimated DC adapter input, not AC wall power or provider-only use.
public enum MacAdapterPower {
    public static func read(now: Date = Date()) -> EnergyReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let connected = IORegistryEntryCreateCFProperty(service,
                  "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              let telemetry = IORegistryEntryCreateCFProperty(service,
                  "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return decode(connected: connected.boolValue, telemetry: telemetry, now: now)
    }

    public static func decode(connected: Bool, telemetry: [String: Any], now: Date) -> EnergyReading? {
        guard connected, now.timeIntervalSince1970.isFinite,
              let power = telemetry["SystemPowerIn"] as? NSNumber,
              CFGetTypeID(power) != CFBooleanGetTypeID() else { return nil }
        let watts = power.doubleValue / 1000
        // A zero/stalled register is unknown, not evidence of free electricity.
        guard watts.isFinite, watts > 0, watts <= 1000 else { return nil }
        return EnergyReading(date: now, watts: watts,
            source: "Mac adapter input (DC estimate)", estimated: true)
    }
}
