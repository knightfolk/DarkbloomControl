import DarkbloomTelemetry
import SwiftUI

struct ProviderVerificationView: View {
    let snapshot: TelemetrySnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Verification", systemImage: "checkmark.shield").font(.headline)
            if case .available(let state, _) = snapshot.state {
                let result = ProviderVerification.evaluate(state: state, expectedCoordinator: expectedCoordinator, now: now)
                Text(result.title).font(.title3.weight(.semibold))
                    .foregroundStyle(result.isVerified ? Color.primary : Color.secondary)
                Text(result.detail).font(.callout).foregroundStyle(.secondary)
                if result.state == .verified {
                    Text(state.trust.authorization?.mdmRemovalReady == true
                         ? "The coordinator reports MDM-removal readiness. Enrollment changes remain in the official CLI."
                         : "MDM-removal readiness has not been granted for this connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Waiting for current verification details").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var expectedCoordinator: String? {
        guard case .available(let status, let capturedAt) = snapshot.status,
              (0...60).contains(now.timeIntervalSince(capturedAt)) else { return nil }
        return status.coordinator
    }
}
