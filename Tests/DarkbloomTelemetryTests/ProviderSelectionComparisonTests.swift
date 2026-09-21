import Foundation
import Testing
@testable import DarkbloomTelemetry
@testable import DarkbloomMonitor

@Suite("Saved versus advertised model selection")
struct ProviderSelectionComparisonTests {
    @Test func orderDoesNotCreateMismatch() {
        let value = ProviderSelectionComparison(saved: ["b", "a", "a"], advertised: ["a", "b"])
        #expect(!value.differs)
        #expect(value.saved == ["a", "b"])
    }
    @Test func unknownIsNotReportedAsDifferentOrEmpty() {
        let value = ProviderSelectionComparison(saved: ["a"], advertised: nil)
        #expect(!value.differs)
        #expect(value.advertised == nil)
        #expect(ProviderSelectionComparison(saved: ["a"], advertised: []).differs)
    }
    @Test @MainActor func confirmationNamesBothSelectionsAndWorkRisk() {
        let value = ProviderSelectionComparison(saved: ["qwen"], advertised: ["bonsai"])
        let dialog = LifecycleConfirmationPresentation.make(.restartSelection(.active, value))
        #expect(dialog.body.contains("interrupt"))
        #expect(dialog.body.contains("Saved selection: qwen"))
        #expect(dialog.body.contains("Advertised now: bonsai"))
        #expect(dialog.confirmLabel == "Restart with Saved Models")
    }
}
