import Darwin
import DarkbloomTelemetry
import Foundation
import SwiftUI

/// Samples macOS host CPU ticks only while the containing dashboard section is
/// visible. The value describes total Mac CPU use, not Darkbloom's process use.
@MainActor
final class SystemCPUUsageStore: ObservableObject {
    @Published private(set) var percentage: Double?
    @Published private(set) var sampledAt: Date?

    private let interval: Duration
    private let read: @MainActor () -> SystemCPUTimes?
    private var samplingTask: Task<Void, Never>?
    private var previous: SystemCPUTimes?

    init(
        interval: Duration = .seconds(3),
        read: @escaping @MainActor () -> SystemCPUTimes? = MacHostCPUSampler.read
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
        guard let current = read() else {
            percentage = nil
            sampledAt = nil
            previous = nil
            return
        }
        if let previous,
           let value = SystemCPUUtilization.percentage(from: previous, to: current) {
            percentage = value
            sampledAt = Date()
        } else {
            percentage = nil
            sampledAt = nil
        }
        previous = current
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        percentage = nil
        sampledAt = nil
        previous = nil
    }
}

enum MacHostCPUSampler {
    static func read() -> SystemCPUTimes? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return SystemCPUTimes(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
    }
}
