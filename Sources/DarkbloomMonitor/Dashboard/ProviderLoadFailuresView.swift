import DarkbloomTelemetry
import SwiftUI

struct ProviderLoadFailuresView: View {
    let failures: [ModelLoadFailure]
    var body: some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last reported model-load issues").font(.headline)
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(failure.model, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(description(failure.code)).font(.callout)
                        if let at = failure.occurredAt, at.isFinite {
                            Text(Date(timeIntervalSince1970: at), style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Reported diagnostic history; a model may have recovered since this issue. Loaded models are shown separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func description(_ code: ModelLoadFailureCode) -> String {
        switch code {
        case .insufficientMemory: "Insufficient memory"
        case .modelUnavailable: "Model unavailable"
        case .unsupported: "Model or runtime unsupported"
        case .integrityFailure: "Model integrity check failed"
        case .timedOut: "Model load timed out"
        case .backendUnavailable: "Inference backend unavailable"
        case .unknown: "Model loading failed; detailed provider message withheld"
        }
    }
}
