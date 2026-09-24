import CoreFoundation
import Foundation
import IOKit
import SwiftUI

/// Best-effort host GPU activity. This is system-wide, not attributed to the
/// Darkbloom process; some GPU families do not publish this registry value.
@MainActor
final class SystemGPUUsageStore: ObservableObject {
    @Published private(set) var percentage: Double?
    @Published private(set) var sampledAt: Date?

    private let interval: Duration
    private let read: @MainActor () -> Double?
    private var samplingTask: Task<Void, Never>?

    init(
        interval: Duration = .seconds(3),
        read: @escaping @MainActor () -> Double? = MacHostGPUSampler.read
    ) {
        self.interval = interval
        self.read = read
    }

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            self.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    return
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard let value = read(), let valid = SystemGPUUtilization.validPercentage(value) else {
            percentage = nil
            sampledAt = nil
            return
        }
        percentage = valid
        sampledAt = Date()
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        percentage = nil
        sampledAt = nil
    }
}

enum MacHostGPUSampler {
    static func read() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var readings: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
                  let percentage = SystemGPUUtilization.devicePercentage(from: property)
            else { continue }
            readings.append(percentage)
        }
        return SystemGPUUtilization.average(readings)
    }
}

enum SystemGPUUtilization {
    static func devicePercentage(from statistics: [String: Any]) -> Double? {
        guard let number = statistics["Device Utilization %"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return validPercentage(number.doubleValue)
    }

    static func validPercentage(_ value: Double) -> Double? {
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    static func average(_ values: [Double]) -> Double? {
        let valid = values.compactMap(validPercentage)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }
}
