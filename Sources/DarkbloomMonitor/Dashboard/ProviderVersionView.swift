import DarkbloomTelemetry
import SwiftUI

struct ProviderVersionView: View {
    let snapshot: TelemetrySnapshot
    let now: Date
    var body: some View {
        let installed = installedVersion
        let running = runningVersion
        if installed != nil || running != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider version").font(.headline)
                HStack(spacing: 20) {
                    if let installed { Text("Installed CLI \(installed)") }
                    if let running { Text("Running \(running)") }
                }.font(.callout)
                if let installed, let running, installed != running {
                    Label("Installed and running versions differ", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
    private var installedVersion: String? {
        guard case .available(let status, let capturedAt) = snapshot.status,
              (0...60).contains(now.timeIntervalSince(capturedAt)) else { return nil }
        return status.version
    }
    private var runningVersion: String? {
        guard case .available(let state, _) = snapshot.state,
              (0...10).contains(now.timeIntervalSince1970 - state.writtenAt) else { return nil }
        return state.version
    }
}
