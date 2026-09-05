import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Provider config document")
struct ProviderConfigDocumentTests {
    @Test("reads and rewrites model selection from the backend table")
    func readsBackendModelSelection() throws {
        let source = """
        title = "preserve me"

        [backend]
        enabled_models = ["legacy-model"]
        max_model_slots = 1
        preload_models = ["legacy-model"]

        [unrelated]
        enabled_models = ["unrelated-model"]
        preload_models = ["unrelated-model"]

        """
        let document = try ProviderConfigDocument(data: Data(source.utf8))

        #expect(document.selection == ProviderModelSelection(
            enabled: ["legacy-model"],
            preloaded: ["legacy-model"]
        ))
        #expect(document.maxModelSlots == 1)

        let rendered = try document.rendering(
            ProviderModelSelection(enabled: ["new-model"], preloaded: []),
            maxModelSlots: 2
        )
        let expected = """
        title = "preserve me"

        [backend]
        enabled_models = [
            "new-model",
        ]
        max_model_slots = 2
        preload_models = [
        ]

        [unrelated]
        enabled_models = ["unrelated-model"]
        preload_models = ["unrelated-model"]

        """
        #expect(rendered == Data(expected.utf8))
    }

    @Test("preserves a missing slot setting until the user explicitly chooses a mode")
    func optionalMaxModelSlots() throws {
        let source = "enabled_models = []\npreload_models = []\n"
        let document = try ProviderConfigDocument(data: Data(source.utf8))

        #expect(document.maxModelSlots == nil)
        let preserved = try ProviderConfigDocument(data: document.rendering(document.selection))
        #expect(preserved.maxModelSlots == nil)
        #expect(preserved.selection == document.selection)

        let repaired = try ProviderConfigDocument(data: document.rendering(
            document.selection,
            maxModelSlots: 2
        ))
        #expect(repaired.maxModelSlots == 2)
        #expect(repaired.selection == document.selection)
    }

    @Test("inserts a missing slot setting in the backend table without stealing adjacent comments")
    func insertsMissingBackendMaxModelSlots() throws {
        let source = """
        title = "preserve me"

        [backend]
        enabled_models = ["model-a"]
        # This comment belongs with preload.
        preload_models = []

        [unrelated]
        max_model_slots = 99

        """
        let document = try ProviderConfigDocument(data: Data(source.utf8))

        let rendered = try document.rendering(document.selection, maxModelSlots: 2)
        let expected = """
        title = "preserve me"

        [backend]
        enabled_models = [
            "model-a",
        ]
        max_model_slots = 2
        # This comment belongs with preload.
        preload_models = [
        ]

        [unrelated]
        max_model_slots = 99

        """

        #expect(rendered == Data(expected.utf8))
        #expect(try ProviderConfigDocument(data: rendered).maxModelSlots == 2)
    }

    @Test("uses the source line ending when inserting a missing slot setting")
    func insertsMissingMaxModelSlotsWithCRLF() throws {
        let source = "enabled_models = []\r\npreload_models = []\r\nprivate_value = \"preserve\"\r\n"
        let document = try ProviderConfigDocument(data: Data(source.utf8))

        let rendered = try document.rendering(document.selection, maxModelSlots: 1)
        let expected = "enabled_models = [\r\n]\r\nmax_model_slots = 1\r\npreload_models = [\r\n]\r\nprivate_value = \"preserve\"\r\n"

        #expect(rendered == Data(expected.utf8))
    }

    @Test("accepts only one or two model slots through the monitor")
    func validatesMaxModelSlots() throws {
        let source = "enabled_models = []\nmax_model_slots = 1\npreload_models = []\n"
        let document = try ProviderConfigDocument(data: Data(source.utf8))

        #expect(throws: ProviderConfigError.unsupportedInteger("max_model_slots", 0)) {
            try document.rendering(document.selection, maxModelSlots: 0)
        }
        #expect(throws: ProviderConfigError.unsupportedInteger("max_model_slots", 3)) {
            try document.rendering(document.selection, maxModelSlots: 3)
        }
    }

    @Test("renders only enabled and preload array value bytes")
    func preservesUnrelatedBytes() throws {
        let original = try fixture("provider-comments.toml")
        let document = try ProviderConfigDocument(data: original)

        let rendered = try document.rendering(ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss"],
            preloaded: ["gemma-4-26b-qat-4bit"]
        ))

        let expected = """
        # Darkbloom provider settings
        enabled_models = [
            "gemma-4-26b-qat-4bit",
            "gpt-oss",
        ]
        engine_v2_max_concurrent = 4 # preserve this comment
        private_value = "never-display-me"
        preload_models = [
            "gemma-4-26b-qat-4bit",
        ] # preserve this trailing comment

        [unrelated]
        enabled_models = ["section-model"] # not a top-level provider selection
        note = "characters inside a string: # ] , \\\""

        """
        #expect(rendered == Data(expected.utf8))
        #expect(try ProviderConfigDocument(data: rendered).selection == ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss"],
            preloaded: ["gemma-4-26b-qat-4bit"]
        ))
    }

    @Test("revision hashes the exact original bytes")
    func exactRevision() throws {
        let document = try ProviderConfigDocument(data: fixture("provider-comments.toml"))
        #expect(document.revision == "0807c3b3061049bb0993718f5567e8788a71c564751024303d8bc6c2f01c3963")
    }

    @Test("parses delimiters comments and escapes inside string values")
    func parsesSpecialCharacters() throws {
        let source = #"""
        enabled_models = ["hash#model", "close]model", "comma,model", "quote\"model", 'literal#],model']
        preload_models = ["hash#model"]
        """#
        let document = try ProviderConfigDocument(data: Data(source.utf8))
        #expect(document.selection == ProviderModelSelection(
            enabled: ["hash#model", "close]model", "comma,model", "quote\"model", "literal#],model"],
            preloaded: ["hash#model"]
        ))
    }

    @Test("uses CRLF for deterministic replacement arrays")
    func preservesCRLF() throws {
        let source = "enabled_models = [\"old\"]\r\npreload_models = []\r\nprivate_value = \"never-display-me\"\r\n"
        let document = try ProviderConfigDocument(data: Data(source.utf8))
        let rendered = try document.rendering(ProviderModelSelection(
            enabled: ["new"],
            preloaded: []
        ))
        let expected = "enabled_models = [\r\n    \"new\",\r\n]\r\npreload_models = [\r\n]\r\nprivate_value = \"never-display-me\"\r\n"
        #expect(rendered == Data(expected.utf8))
    }

    @Test("requires exactly one top-level assignment for each approved key")
    func requiresUniqueTopLevelAssignments() {
        #expect(throws: ProviderConfigError.missingArray("preload_models")) {
            try ProviderConfigDocument(data: Data("enabled_models = []\n".utf8))
        }
        #expect(throws: ProviderConfigError.duplicateArray("enabled_models")) {
            try ProviderConfigDocument(data: Data("enabled_models=[]\nenabled_models=[]\npreload_models=[]\n".utf8))
        }
        #expect(throws: ProviderConfigError.missingArray("enabled_models")) {
            try ProviderConfigDocument(data: Data("[nested]\nenabled_models=[]\npreload_models=[]\n".utf8))
        }
    }

    @Test("rejects malformed arrays and non-string elements precisely")
    func rejectsMalformedAndNonStringValues() {
        #expect(throws: ProviderConfigError.malformedArray("enabled_models")) {
            try ProviderConfigDocument(data: Data("enabled_models = [\"one\" \"two\"]\npreload_models = []\n".utf8))
        }
        #expect(throws: ProviderConfigError.malformedArray("enabled_models")) {
            try ProviderConfigDocument(data: Data("enabled_models = [\"one\"\npreload_models = []\n".utf8))
        }
        #expect(throws: ProviderConfigError.nonStringValue("enabled_models")) {
            try ProviderConfigDocument(data: Data("enabled_models = [1]\npreload_models = []\n".utf8))
        }
        #expect(throws: ProviderConfigError.nonStringValue("preload_models")) {
            try ProviderConfigDocument(data: Data("enabled_models = []\npreload_models = \"one\"\n".utf8))
        }
    }

    @Test("rejects duplicate models when parsing and rendering")
    func rejectsDuplicateModels() throws {
        #expect(throws: ProviderConfigError.duplicateModel("same")) {
            try ProviderConfigDocument(data: Data("enabled_models = [\"same\", \"same\"]\npreload_models = []\n".utf8))
        }

        let document = try ProviderConfigDocument(data: Data("enabled_models = []\npreload_models = []\n".utf8))
        #expect(throws: ProviderConfigError.duplicateModel("same")) {
            try document.rendering(ProviderModelSelection(enabled: ["same", "same"], preloaded: []))
        }
    }

    @Test("requires every preload selector to remain enabled")
    func validatesPreloadSubset() throws {
        #expect(throws: ProviderConfigError.preloadRequiresEnabled("gpt-oss")) {
            try ProviderConfigDocument(data: Data("enabled_models = []\npreload_models = [\"gpt-oss\"]\n".utf8))
        }

        let document = try ProviderConfigDocument(data: Data("enabled_models = []\npreload_models = []\n".utf8))
        #expect(throws: ProviderConfigError.preloadRequiresEnabled("gpt-oss")) {
            try document.rendering(ProviderModelSelection(enabled: [], preloaded: ["gpt-oss"]))
        }
    }

    @Test("rejects invalid UTF-8")
    func rejectsInvalidUTF8() {
        #expect(throws: ProviderConfigError.invalidUTF8) {
            try ProviderConfigDocument(data: Data([0xFF, 0xFE]))
        }
    }

    @Test("errors never disclose unrelated credential-shaped values")
    func redactsUnrelatedValuesFromErrors() {
        let source = "private_value = \"never-display-me\"\nenabled_models = []\n"
        do {
            _ = try ProviderConfigDocument(data: Data(source.utf8))
            Issue.record("Expected a missing preload array error")
        } catch {
            #expect(error as? ProviderConfigError == .missingArray("preload_models"))
            #expect(!String(describing: error).contains("never-display-me"))
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }
}
