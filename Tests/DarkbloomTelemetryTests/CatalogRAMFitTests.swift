import Testing
@testable import DarkbloomTelemetry

struct CatalogRAMFitTests {
    @Test("RAM minimum uses installed memory and includes the exact boundary")
    func boundary() {
        #expect(fit(bytes: 32 * 1_073_741_824 - 1) == .belowMinimum)
        #expect(fit(bytes: 32 * 1_073_741_824) == .minimumMet)
        #expect(fit(bytes: 64 * 1_073_741_824) == .minimumMet)
    }

    @Test("stale missing or mismatched metadata never establishes RAM fit")
    func insufficientEvidence() {
        #expect(fit(bytes: 0) == .unavailable)
        #expect(CatalogRAMFit.evaluate(modelID: "Example/Model", metadata: model(), metadataIsCurrent: false,
                                      installedMemoryBytes: 64 * 1_073_741_824) == .unavailable)
        #expect(CatalogRAMFit.evaluate(modelID: "example/model", metadata: model(), metadataIsCurrent: true,
                                      installedMemoryBytes: 64 * 1_073_741_824) == .unavailable)
        #expect(CatalogRAMFit.evaluate(modelID: "Example/Model", metadata: nil, metadataIsCurrent: true,
                                      installedMemoryBytes: 64 * 1_073_741_824) == .unavailable)
        for minimum in [0, -1] {
            #expect(CatalogRAMFit.evaluate(modelID: "Example/Model", metadata: model(minimum: minimum), metadataIsCurrent: true,
                                          installedMemoryBytes: 64 * 1_073_741_824) == .unavailable)
        }
    }

    @Test("provider capability fit remains unverified without explicit runtime evidence")
    func providerCapabilityEvidence() {
        #expect(CatalogProviderCapabilityFit.evaluate(required: nil, observed: nil) == .unverified)
        #expect(CatalogProviderCapabilityFit.evaluate(required: [], observed: nil) == .noRequirements)
        #expect(CatalogProviderCapabilityFit.evaluate(required: ["apple_m5", "mlx_nax"], observed: nil) == .unverified)
        #expect(CatalogProviderCapabilityFit.evaluate(required: ["apple_m5", "mlx_nax"], observed: ["apple_m5"]) == .unsupported(missing: ["mlx_nax"]))
        #expect(CatalogProviderCapabilityFit.evaluate(required: ["apple_m5", "mlx_nax", "mlx_nax"], observed: ["apple_m5", "mlx_nax"]) == .supported)
        #expect(CatalogProviderCapabilityFit.evaluate(required: ["  mlx_nax  ", ""], observed: ["mlx_nax"]) == .supported)
    }

    private func fit(bytes: UInt64) -> CatalogRAMFit {
        .evaluate(modelID: "Example/Model", metadata: model(), metadataIsCurrent: true, installedMemoryBytes: bytes)
    }

    private func model(minimum: Int = 32) -> CatalogModel {
        CatalogModel(id: "Example/Model", displayName: "Example", family: "example", modelType: "llm",
                     capabilities: ["text"], sizeGB: 20, minimumRAMGB: minimum, active: true)
    }
}
