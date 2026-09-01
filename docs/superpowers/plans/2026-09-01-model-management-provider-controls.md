# Model Management and Provider Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add separate model download/delete, enable/disable, and preload management plus non-interactive provider Start, Stop, and Restart controls with customer-impact confirmation.

**Architecture:** Keep all external mutations behind shell-free Darkbloom CLI command objects and a narrow provider configuration store. A dedicated `ProviderControlStore` owns model/config/lifecycle state for SwiftUI while the existing `MonitorStore` remains responsible for telemetry and earnings. The Settings window receives the model manager; the popup receives a compact lifecycle strip.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, Foundation `Process`, CryptoKit SHA-256, Darkbloom CLI 0.8.15, TOML byte-preserving targeted edits.

**Spec:** `docs/superpowers/specs/2026-09-01-model-management-provider-controls-design.md`

## Global Constraints

- Target macOS 14 or newer and preserve the package's existing dependency-free SwiftPM structure.
- Use the fixed config path `~/.config/darkbloom/provider.toml`; do not follow arbitrary paths printed by CLI output.
- Mutate only top-level `enabled_models` and `preload_models`; preserve every unrelated TOML byte and comment.
- Never invoke `/bin/sh` for production commands. Pass executable and arguments separately to `Process`.
- Never display or log the complete TOML file, credentials, account data, or unbounded command output.
- Download/Delete, Enable/Disable, Preload, and Loaded are independent states. No action implicitly changes another.
- `darkbloom stop` must never receive `--uninstall`.
- Automated tests must not touch the real provider config, cache, launchd service, or coordinator.
- Real Start, Stop, Restart, Add, Delete, and config writes remain outside final live verification unless the user separately authorizes them.
- Preserve untracked `.superpowers/` and `Sources/DarkbloomMonitor/Resources/DarkbloomLogo.svg`; they are not part of this feature.

## File Structure

- `Sources/DarkbloomTelemetry/SourcePolicy.swift`: fixed paths, command value type, exact Darkbloom command factory, and timeout/output bounds.
- `Sources/DarkbloomTelemetry/ProcessRunner.swift`: generic shell-free execution with bounded incremental output callbacks.
- `Sources/DarkbloomTelemetry/ModelInventory.swift`: catalog/local JSON models and deterministic state reconciliation.
- `Sources/DarkbloomTelemetry/ProviderConfigDocument.swift`: pure targeted TOML parsing and byte-preserving rendering.
- `Sources/DarkbloomTelemetry/ProviderConfigStore.swift`: revision checks, candidate validation, backup, permissions, and atomic replacement.
- `Sources/DarkbloomTelemetry/ProviderControlService.swift`: catalog/list refresh, download/delete, activity checks, and lifecycle command execution.
- `Sources/DarkbloomMonitor/ProviderControlStore.swift`: main-actor state machine shared by Settings and the popup.
- `Sources/DarkbloomMonitor/MonitorSettingsView.swift`: tab shell and General settings.
- `Sources/DarkbloomMonitor/ModelManagerView.swift`: My Catalog and Available UI.
- `Sources/DarkbloomMonitor/ProviderLifecycleControls.swift`: popup icon controls and customer-impact alerts.
- `Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift`: constructs one shared control service/store.
- `Sources/DarkbloomMonitor/StatusItemController.swift`: injects the shared control store and sizes the Settings window.
- `Sources/DarkbloomMonitor/MonitorPopover.swift`: places the lifecycle strip without regressing infographic content.
- `Tests/DarkbloomTelemetryTests/`: focused parser, service, store, and layout suites plus inert fixtures.

---

### Task 1: Preserve the approved popup baseline

**Files:**
- Verify and commit only the existing approved popup/data changes already present in the working tree.
- Exclude: `.superpowers/`
- Exclude: `Sources/DarkbloomMonitor/Resources/DarkbloomLogo.svg`

**Interfaces:**
- Consumes: current dirty working tree on top of design commit `fa3da70`.
- Produces: a tested baseline commit containing the infographic popup, approved menu icon, in-process Settings window, and dashboard metrics.

- [ ] **Step 1: Confirm the baseline diff contains no unrelated paths**

Run:

```bash
git status --short
git diff --check
git diff -- Sources Tests Package.swift README.md docs/ARCHITECTURE.md docs/PRESENTATION_OPTIONS.md
```

Expected: the known popup/data files are modified; `.superpowers/` and `DarkbloomLogo.svg` remain untracked and untouched.

- [ ] **Step 2: Re-run baseline verification**

Run:

```bash
swift test
swift build -c release
```

Expected: 118 or more tests pass and the release executable links successfully.

- [ ] **Step 3: Stage only the approved baseline files**

Run:

```bash
git add Package.swift README.md \
  Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift \
  Sources/DarkbloomMonitor/MonitorPopover.swift \
  Sources/DarkbloomMonitor/MonitorSettingsView.swift \
  Sources/DarkbloomMonitor/MonitorStore.swift \
  Sources/DarkbloomMonitor/StatusItemController.swift \
  Sources/DarkbloomTelemetry/AuthenticatedEarningsClient.swift \
  Sources/DarkbloomTelemetry/DashboardPresentation.swift \
  Sources/DarkbloomTelemetry/EarningsDatabase.swift \
  Tests/DarkbloomTelemetryTests/DashboardPresentationTests.swift \
  Tests/DarkbloomTelemetryTests/EarningsDatabaseTests.swift \
  Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift \
  Tests/DarkbloomTelemetryTests/MonitorStoreDashboardTests.swift \
  Tests/DarkbloomTelemetryTests/MonitorStoreEarningsTests.swift \
  docs/ARCHITECTURE.md docs/PRESENTATION_OPTIONS.md
git diff --cached --name-status
```

Expected: only the listed paths are staged.

- [ ] **Step 4: Commit the baseline**

Run:

```bash
git commit -m "feat: add infographic monitor popup"
```

Expected: one scoped commit; the two excluded untracked paths remain untracked.

---

### Task 2: Generalize bounded commands and define the exact Darkbloom command surface

**Files:**
- Modify: `Sources/DarkbloomTelemetry/SourcePolicy.swift:3-65`
- Modify: `Sources/DarkbloomTelemetry/ProcessRunner.swift:3-166,180-335`
- Modify: `Sources/DarkbloomTelemetry/LocalTelemetrySource.swift:1-65`
- Modify: `Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift:5-45`
- Modify: `Tests/DarkbloomTelemetryTests/ProcessRunnerTests.swift:6-318`
- Create: `Tests/DarkbloomTelemetryTests/DarkbloomCommandTests.swift`

**Interfaces:**
- Consumes: existing `CappedProcessRunner` behavior and approved CLI candidate resolution.
- Produces: `ProcessCommand`, `ProcessExecuting`, `ProcessOutputChunk`, `DarkbloomCommand`, and mutation-specific policy bounds.

- [ ] **Step 1: Write failing exact-command tests**

Add tests with these assertions:

```swift
@Suite("Darkbloom commands")
struct DarkbloomCommandTests {
    let executable = URL(fileURLWithPath: "/Users/example/.darkbloom/bin/darkbloom")
    let config = URL(fileURLWithPath: "/Users/example/.config/darkbloom/provider.toml")

    @Test("start repeats model arguments and skips the picker")
    func startArguments() {
        let command = DarkbloomCommand.start(
            executable: executable,
            config: config,
            models: ["gemma-4-26b-qat-4bit", "gpt-oss"]
        )
        #expect(command.arguments == [
            "start", "--config", config.path,
            "--model", "gemma-4-26b-qat-4bit",
            "--model", "gpt-oss",
        ])
    }

    @Test("stop cannot uninstall")
    func stopArguments() {
        #expect(DarkbloomCommand.stop(executable: executable).arguments == ["stop"])
    }

    @Test("model commands keep identifiers as single arguments")
    func modelArguments() {
        #expect(DarkbloomCommand.catalog(executable: executable, config: config).arguments == [
            "models", "catalog", "--config", config.path, "--json",
        ])
        #expect(DarkbloomCommand.localModels(executable: executable, config: config).arguments == [
            "models", "list", "--config", config.path, "--json", "--all",
        ])
        #expect(DarkbloomCommand.download(executable: executable, config: config, modelID: "safe-id").arguments == [
            "models", "download", "--config", config.path, "safe-id",
        ])
        #expect(DarkbloomCommand.remove(executable: executable, modelID: "safe-id").arguments == [
            "models", "remove", "safe-id", "--force",
        ])
    }
}
```

- [ ] **Step 2: Run the new suite and verify it fails**

Run:

```bash
swift test --filter DarkbloomCommandTests
```

Expected: compilation fails because `DarkbloomCommand` and `ProcessCommand` do not exist.

- [ ] **Step 3: Introduce generic command and executor interfaces**

Replace the read-only value type with:

```swift
public struct ProcessCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    static func testOnly(executable: URL, arguments: [String]) -> Self {
        Self(executable: executable, arguments: arguments)
    }
}

public enum ProcessOutputDestination: Equatable, Sendable {
    case standardOutput
    case standardError
}

public struct ProcessOutputChunk: Equatable, Sendable {
    public let destination: ProcessOutputDestination
    public let data: Data
}

public protocol ProcessExecuting: Sendable {
    func run(
        _ command: ProcessCommand,
        timeout: Duration,
        outputLimit: Int,
        onOutput: (@Sendable (ProcessOutputChunk) -> Void)?
    ) async throws -> CommandResult
}
```

Make `CappedProcessRunner` conform, give `onOutput` a default value of `nil`, and emit a chunk before appending it to the bounded retained buffers. Rename all test-only `ReadOnlyCommand` references to `ProcessCommand`.

- [ ] **Step 4: Add fixed paths, bounds, and command factory**

Add these policy values and factory cases:

```swift
public static let lifecycleTimeout: Duration = .seconds(30)
public static let catalogTimeout: Duration = .seconds(15)
public static let downloadTimeout: Duration = .seconds(21_600)
public static let mutationOutputByteLimit = 1_048_576

public let providerConfig: URL

public enum DarkbloomCommand {
    public static func status(executable: URL, config: URL? = nil) -> ProcessCommand
    public static func catalog(executable: URL, config: URL) -> ProcessCommand
    public static func localModels(executable: URL, config: URL) -> ProcessCommand
    public static func download(executable: URL, config: URL, modelID: String) -> ProcessCommand
    public static func remove(executable: URL, modelID: String) -> ProcessCommand
    public static func start(executable: URL, config: URL, models: [String]) -> ProcessCommand
    public static func stop(executable: URL) -> ProcessCommand
    public static func restart(executable: URL, config: URL) -> ProcessCommand
}
```

Initialize `providerConfig` as `homeDirectory/.config/darkbloom/provider.toml`. Update `LocalTelemetrySource` to call `DarkbloomCommand.status` through `ProcessCommand`.

- [ ] **Step 5: Add bounded incremental-output coverage**

Add a recorder-based test:

```swift
@Test("publishes chunks without bypassing the retained output cap")
func publishesOutputChunks() async throws {
    let recorder = OutputChunkRecorder()
    let result = try await CappedProcessRunner().run(
        .testOnly(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["progress"]),
        timeout: .seconds(3),
        outputLimit: 64,
        onOutput: recorder.record
    )
    #expect(result.standardOutput == Data("progress".utf8))
    #expect(recorder.data(for: .standardOutput) == Data("progress".utf8))
}

private final class OutputChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [ProcessOutputChunk] = []

    func record(_ chunk: ProcessOutputChunk) {
        lock.withLock { chunks.append(chunk) }
    }

    func data(for destination: ProcessOutputDestination) -> Data {
        lock.withLock {
            chunks.lazy
                .filter { $0.destination == destination }
                .reduce(into: Data()) { $0.append($1.data) }
        }
    }
}
```

Keep all existing timeout, cancellation, resistant-child, and handle-cleanup tests green.

- [ ] **Step 6: Run focused and full tests**

Run:

```bash
swift test --filter DarkbloomCommandTests
swift test --filter ProcessRunnerTests
swift test --filter SourcePolicyTests
swift test
```

Expected: all suites pass and no production source contains `/bin/sh`.

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/DarkbloomTelemetry/SourcePolicy.swift \
  Sources/DarkbloomTelemetry/ProcessRunner.swift \
  Sources/DarkbloomTelemetry/LocalTelemetrySource.swift \
  Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift \
  Tests/DarkbloomTelemetryTests/ProcessRunnerTests.swift \
  Tests/DarkbloomTelemetryTests/DarkbloomCommandTests.swift
git commit -m "feat: define bounded Darkbloom control commands"
```

---

### Task 3: Decode and reconcile the model inventory

**Files:**
- Create: `Sources/DarkbloomTelemetry/ModelInventory.swift`
- Create: `Tests/DarkbloomTelemetryTests/ModelInventoryTests.swift`
- Create: `Tests/DarkbloomTelemetryTests/Fixtures/model-catalog.json`
- Create: `Tests/DarkbloomTelemetryTests/Fixtures/local-models.json`

**Interfaces:**
- Consumes: raw JSON output from `models catalog --json`, `models list --json --all`, `DaemonState`, and `LoadedModelsState`.
- Produces: `CatalogModel`, `LocalModel`, `ProviderModelSelection`, `ModelInventoryItem`, `ModelInventory`, and `ModelInventoryBuilder.build(catalog:local:selection:daemon:loadedModels:)`.

- [ ] **Step 1: Add inert JSON fixtures and failing decoder tests**

Use a two-model catalog fixture containing `gpt-oss-20b` with family `gpt-oss` and `gemma-4-26b-qat-4bit`, plus a local response whose `models` array contains both IDs. Add:

```swift
@Suite("Model inventory")
struct ModelInventoryTests {
    @Test("decodes catalog and local model JSON")
    func decodesSources() throws {
        let catalog = try ModelCatalogDecoder.decode(fixture("model-catalog.json"))
        let local = try LocalModelListDecoder.decode(fixture("local-models.json"))
        #expect(catalog.map(\.id) == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
        #expect(local.models.map(\.id) == ["gpt-oss-20b", "gemma-4-26b-qat-4bit"])
    }

    @Test("matches a unique configured family alias without rewriting it")
    func matchesFamilyAlias() throws {
        let inventory = ModelInventoryBuilder.build(
            catalog: try ModelCatalogDecoder.decode(fixture("model-catalog.json")),
            local: try LocalModelListDecoder.decode(fixture("local-models.json")).models,
            selection: ProviderModelSelection(enabled: ["gpt-oss"], preloaded: []),
            daemon: nil,
            loadedModels: []
        )
        let item = try #require(inventory.myCatalog.first { $0.catalogID == "gpt-oss-20b" })
        #expect(item.configuredSelector == "gpt-oss")
        #expect(item.isEnabled)
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
```

- [ ] **Step 2: Run the suite and verify it fails**

Run:

```bash
swift test --filter ModelInventoryTests
```

Expected: compilation fails because the inventory types do not exist.

- [ ] **Step 3: Implement decodable source types**

Define:

```swift
public struct CatalogModel: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let family: String
    public let modelType: String
    public let capabilities: [String]
    public let sizeGB: Double
    public let minimumRAMGB: Int
    public let active: Bool
}

public struct LocalModel: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let modelType: String
    public let sizeBytes: Int64
    public let estimatedMemoryGB: Double?
}

public struct LocalModelList: Decodable, Equatable, Sendable {
    public let cacheDirectory: String
    public let filteredByConfig: Bool
    public let models: [LocalModel]
}

public enum ModelCatalogDecoder {
    public static func decode(_ data: Data) throws -> [CatalogModel]
}

public enum LocalModelListDecoder {
    public static func decode(_ data: Data) throws -> LocalModelList
}
```

Map the observed snake-case catalog fields (`display_name`, `model_type`, `size_gb`, `min_ram_gb`) and local fields (`size_bytes`, `estimated_memory_gb`) explicitly.

- [ ] **Step 4: Implement deterministic reconciliation**

Define the stable output:

```swift
public struct ProviderModelSelection: Equatable, Sendable {
    public var enabled: [String]
    public var preloaded: [String]
}

public enum InventoryLiveState: Equatable, Sendable {
    case active
    case loadedIdle
    case unloaded
}

public struct ModelInventoryItem: Equatable, Identifiable, Sendable {
    public var id: String { catalogID }
    public let catalogID: String
    public let localID: String?
    public let configuredSelector: String?
    public let displayName: String
    public let capabilities: [String]
    public let sizeGB: Double
    public let minimumRAMGB: Int
    public let isDownloaded: Bool
    public let isEnabled: Bool
    public let isPreloaded: Bool
    public let liveState: InventoryLiveState
    public let issue: String?
}

public struct ModelInventory: Equatable, Sendable {
    public let myCatalog: [ModelInventoryItem]
    public let available: [ModelInventoryItem]
    public let issues: [String]
}

public enum ModelInventoryBuilder {
    public static func build(
        catalog: [CatalogModel],
        local: [LocalModel],
        selection: ProviderModelSelection,
        daemon: DaemonState?,
        loadedModels: [String]
    ) -> ModelInventory
}
```

Match exact IDs first, then a family alias only when exactly one catalog entry has that family. Preserve the original configured selector. Mark ambiguous or unmatched selectors as issues and never guess. Sort each section by localized display name.

- [ ] **Step 5: Add state-separation and ambiguity tests**

Cover these exact expectations:

```swift
#expect(downloadedButDisabled.isDownloaded && !downloadedButDisabled.isEnabled)
#expect(enabledButUnloaded.isEnabled && enabledButUnloaded.liveState == .unloaded)
#expect(preloadedButIdle.isPreloaded && preloadedButIdle.liveState == .loadedIdle)
#expect(active.liveState == .active)
#expect(inventory.available.allSatisfy { !$0.isDownloaded })
#expect(ambiguous.issue == "Configured selector 'shared-family' matches multiple catalog models")
```

- [ ] **Step 6: Run tests and commit**

Run:

```bash
swift test --filter ModelInventoryTests
swift test
git add Sources/DarkbloomTelemetry/ModelInventory.swift \
  Tests/DarkbloomTelemetryTests/ModelInventoryTests.swift \
  Tests/DarkbloomTelemetryTests/Fixtures/model-catalog.json \
  Tests/DarkbloomTelemetryTests/Fixtures/local-models.json
git commit -m "feat: reconcile Darkbloom model inventory"
```

---

### Task 4: Parse and render only the approved TOML arrays

**Files:**
- Create: `Sources/DarkbloomTelemetry/ProviderConfigDocument.swift`
- Create: `Tests/DarkbloomTelemetryTests/ProviderConfigDocumentTests.swift`
- Create: `Tests/DarkbloomTelemetryTests/Fixtures/provider-comments.toml`

**Interfaces:**
- Consumes: raw `provider.toml` bytes and `ProviderModelSelection`.
- Produces: `ProviderConfigDocument.init(data:)`, `.selection`, `.revision`, and `.rendering(_:)`.

- [ ] **Step 1: Write failing preservation tests**

Add a fixture containing multiline arrays, inline comments, unrelated provider fields, and a credential-shaped value that must remain byte-identical and never enter an error message. Add:

```swift
@Suite("Provider config document")
struct ProviderConfigDocumentTests {
    @Test("renders only enabled and preload arrays")
    func preservesUnrelatedBytes() throws {
        let original = fixture("provider-comments.toml")
        let document = try ProviderConfigDocument(data: original)
        let rendered = try document.rendering(ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss"],
            preloaded: ["gemma-4-26b-qat-4bit"]
        ))
        #expect(String(decoding: rendered, as: UTF8.self).contains("engine_v2_max_concurrent = 4"))
        #expect(String(decoding: rendered, as: UTF8.self).contains("private_value = \"never-display-me\""))
        #expect(try ProviderConfigDocument(data: rendered).selection == ProviderModelSelection(
            enabled: ["gemma-4-26b-qat-4bit", "gpt-oss"],
            preloaded: ["gemma-4-26b-qat-4bit"]
        ))
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
```

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter ProviderConfigDocumentTests
```

Expected: compilation fails because `ProviderConfigDocument` does not exist.

- [ ] **Step 3: Implement the document API and scanner**

Define:

```swift
public enum ProviderConfigError: Error, Equatable, Sendable {
    case invalidUTF8
    case missingArray(String)
    case duplicateArray(String)
    case malformedArray(String)
    case nonStringValue(String)
    case duplicateModel(String)
    case preloadRequiresEnabled(String)
    case changedExternally
    case validationFailed(String)
}

public struct ProviderConfigDocument: Equatable, Sendable {
    public let data: Data
    public let selection: ProviderModelSelection
    public let revision: String

    public init(data: Data) throws
    public func rendering(_ selection: ProviderModelSelection) throws -> Data
}
```

The scanner must track quoted-string state, escapes, `#` comments, bracket depth, and line endings. It must locate exactly one top-level assignment for each approved key and retain each full array-value byte range. Render arrays in deterministic four-space-indented multiline form while preserving the source line ending. Apply replacements from the later byte range to the earlier range so offsets stay valid. Compute `revision` with `SHA256.hash(data:)` from CryptoKit.

- [ ] **Step 4: Add malformed, duplicate, CRLF, and subset tests**

Add explicit cases for:

```swift
await #expect(throws: ProviderConfigError.missingArray("preload_models")) {
    try ProviderConfigDocument(data: Data("enabled_models = []\n".utf8))
}
await #expect(throws: ProviderConfigError.duplicateArray("enabled_models")) {
    try ProviderConfigDocument(data: Data("enabled_models=[]\nenabled_models=[]\npreload_models=[]\n".utf8))
}
await #expect(throws: ProviderConfigError.preloadRequiresEnabled("gpt-oss")) {
    try document.rendering(ProviderModelSelection(enabled: [], preloaded: ["gpt-oss"]))
}
```

Also assert CRLF remains CRLF and strings containing `#`, `]`, commas, and escaped quotes parse correctly.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter ProviderConfigDocumentTests
swift test
git add Sources/DarkbloomTelemetry/ProviderConfigDocument.swift \
  Tests/DarkbloomTelemetryTests/ProviderConfigDocumentTests.swift \
  Tests/DarkbloomTelemetryTests/Fixtures/provider-comments.toml
git commit -m "feat: edit provider model arrays safely"
```

---

### Task 5: Persist validated configuration with conflict detection and backup

**Files:**
- Create: `Sources/DarkbloomTelemetry/ProviderConfigStore.swift`
- Create: `Tests/DarkbloomTelemetryTests/ProviderConfigStoreTests.swift`

**Interfaces:**
- Consumes: `ProviderConfigDocument`, `ProcessExecuting`, `DarkbloomCommand.status`, fixed config URL, and resolved executable URL.
- Produces: `ProviderConfigDraft`, `ProviderConfigManaging`, `LocalProviderConfigStore.load()`, and `.save(_:)`.

- [ ] **Step 1: Write failing load/save/conflict tests**

Define test expectations around a temporary directory and fake executor:

```swift
@Test("save validates, backs up, preserves permissions, and replaces atomically")
func savesValidatedCandidate() async throws {
    let harness = try ConfigStoreHarness.make(mode: 0o600)
    let draft = try await harness.store.load()
    let saved = try await harness.store.save(draft.withSelection(
        ProviderModelSelection(enabled: ["gemma-4-26b-qat-4bit"], preloaded: [])
    ))
    #expect(saved.restartRequired)
    #expect(try Data(contentsOf: harness.backupURL) == harness.originalData)
    #expect(try fileMode(harness.configURL) == 0o600)
    let validation = try #require(await harness.executor.commands.first)
    #expect(Array(validation.arguments.prefix(2)) == ["status", "--config"])
    let candidate = try #require(validation.arguments.dropFirst(2).first)
    #expect(URL(fileURLWithPath: candidate).deletingLastPathComponent() == harness.directory)
}

@Test("external changes reject save without replacing either file")
func rejectsExternalChange() async throws {
    let harness = try ConfigStoreHarness.make(mode: 0o600)
    let draft = try await harness.store.load()
    try Data("enabled_models=[]\npreload_models=[]\n# external\n".utf8).write(to: harness.configURL)
    await #expect(throws: ProviderConfigError.changedExternally) {
        try await harness.store.save(draft)
    }
    #expect(!FileManager.default.fileExists(atPath: harness.backupURL.path))
}
```

The test file must define `ConfigStoreHarness` with `directory`, `configURL`, `backupURL`, `originalData`, `executor`, and `store`. Its `make(mode:)` creates a unique temporary directory, writes the fixture bytes, applies the requested POSIX mode, and registers cleanup with the test. Define `fileMode(_:)` by reading `.posixPermissions` through `FileManager.attributesOfItem(atPath:)`. The fake executor records commands and returns exit zero unless the test injects a nonzero result.

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter ProviderConfigStoreTests
```

Expected: compilation fails because the store interfaces do not exist.

- [ ] **Step 3: Implement actor-isolated persistence**

Define:

```swift
public struct ProviderConfigDraft: Equatable, Sendable {
    public let sourceRevision: String
    public let original: ProviderModelSelection
    public var selection: ProviderModelSelection
    public var hasChanges: Bool { selection != original }

    public func withSelection(_ selection: ProviderModelSelection) -> Self
}

public struct ProviderConfigSaveResult: Equatable, Sendable {
    public let draft: ProviderConfigDraft
    public let restartRequired: Bool
}

public protocol ProviderConfigManaging: Sendable {
    func load() async throws -> ProviderConfigDraft
    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult
}

public actor LocalProviderConfigStore: ProviderConfigManaging {
    public init(
        configURL: URL,
        executable: URL,
        runner: any ProcessExecuting,
        fileManager: FileManager = .default
    )
}
```

Write a random-UUID sibling candidate with mode copied from `stat`. Compare the current SHA-256 immediately before replacement. Validate with `darkbloom status --config <candidate>`, cap output at the normal process limit, and redact home paths in errors. Replace a fixed sibling backup named `provider.toml.darkbloom-monitor-backup` only after validation succeeds. Remove orphaned candidate files on every exit path.

- [ ] **Step 4: Add validation-failure and cleanup coverage**

Assert that nonzero validation leaves original bytes unchanged, does not create/replace the backup, deletes the candidate, and exposes only `ProviderConfigError.validationFailed("Darkbloom rejected the candidate configuration")`.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter ProviderConfigStoreTests
swift test
git add Sources/DarkbloomTelemetry/ProviderConfigStore.swift \
  Tests/DarkbloomTelemetryTests/ProviderConfigStoreTests.swift
git commit -m "feat: persist validated provider model config"
```

---

### Task 6: Build the provider control service

**Files:**
- Create: `Sources/DarkbloomTelemetry/ProviderControlService.swift`
- Create: `Tests/DarkbloomTelemetryTests/ProviderControlServiceTests.swift`

**Interfaces:**
- Consumes: `ProcessExecuting`, `ProviderConfigManaging`, model decoders, inventory builder, `TelemetrySource.readDaemonState()`, and command factory.
- Produces: `ProviderControlling`, `ProviderControlSnapshot`, `ProviderLifecycleAction`, `ProviderActivityRisk`, model mutations, and lifecycle execution.

- [ ] **Step 1: Write failing refresh and exact-mutation tests**

Use an actor fake that returns fixture JSON by command arguments. Assert:

```swift
@Test("refresh combines catalog local config and live telemetry")
func refreshesInventory() async throws {
    let snapshot = try await harness.service.refresh()
    #expect(snapshot.inventory.myCatalog.count == 2)
    #expect(snapshot.inventory.available.count == 1)
    #expect(snapshot.draft.selection.enabled == ["gemma-4-26b-qat-4bit"])
}

@Test("download and delete never change configuration")
func mutationsStaySeparate() async throws {
    try await harness.service.download("gpt-oss-20b", onOutput: nil)
    try await harness.service.delete("gpt-oss-20b")
    #expect(await harness.configStore.saveCount == 0)
    #expect(await harness.runner.mutationArguments == [
        ["models", "download", "--config", harness.configURL.path, "gpt-oss-20b"],
        ["models", "remove", "gpt-oss-20b", "--force"],
    ])
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter ProviderControlServiceTests
```

Expected: compilation fails because the service does not exist.

- [ ] **Step 3: Implement service interfaces and serialized mutations**

Define:

```swift
public enum ProviderLifecycleAction: String, Equatable, Sendable {
    case start
    case stop
    case restart
}

public enum ProviderActivityRisk: Equatable, Sendable {
    case idle
    case active
    case unknown(String)
}

public struct ProviderControlSnapshot: Equatable, Sendable {
    public let inventory: ModelInventory
    public let draft: ProviderConfigDraft
    public let capturedAt: Date
}

public protocol ProviderControlling: Sendable {
    func refresh() async throws -> ProviderControlSnapshot
    func save(_ draft: ProviderConfigDraft) async throws -> ProviderConfigSaveResult
    func download(_ modelID: String, onOutput: (@Sendable (ProcessOutputChunk) -> Void)?) async throws
    func delete(_ localModelID: String) async throws
    func activityRisk() async -> ProviderActivityRisk
    func execute(_ action: ProviderLifecycleAction, enabledModels: [String]) async throws
}

public enum ProviderControlError: Error, Equatable, Sendable {
    case commandAlreadyRunning
    case executableUnavailable
    case noEnabledModels
    case inventoryUnavailable(String)
    case deleteBlocked(String)
    case invalidOutput(String)
}

public actor ProviderControlService: ProviderControlling {
    public init(
        policy: DarkbloomSourcePolicy,
        telemetrySource: any TelemetrySource,
        configStore: any ProviderConfigManaging,
        runner: any ProcessExecuting,
        now: @escaping @Sendable () -> Date = Date.init
    )
}
```

Implement `ProviderControlService` as an actor. Reject overlapping model/lifecycle mutations with `ProviderControlError.commandAlreadyRunning`. Decode catalog and local JSON before publishing. Resolve exact CLI executable once per action from the approved candidate list; absence produces a bounded error. Retain the last successful catalog and local list independently: on a later source failure, rebuild from those values and append a stale-source issue; if a required source has never succeeded, throw an unavailable error instead of classifying every model incorrectly. Before Delete, require a fresh inventory and reject active, loaded, saved-enabled, saved-preloaded, or ambiguous models in the service itself; the SwiftUI disabled state is not the safety boundary.

- [ ] **Step 4: Implement activity and lifecycle behavior**

`activityRisk()` directly calls `readDaemonState()`. Return `.active` for `inferenceActive == true`, `.idle` for false, and `.unknown("Provider activity is unavailable")` for any read failure.

For Start, require non-empty saved enabled selectors and build the repeated `--model` command. Stop must use the zero-option stop command. Restart must include the fixed config. Use the 30-second lifecycle timeout and refresh only after command completion.

- [ ] **Step 5: Add lifecycle and cancellation tests**

Cover Start with two selectors, empty Start rejection, Stop without uninstall, Restart config path, activity mapping, overlap rejection, download output callback, cancellation propagation to the fake executor, and service-level Delete rejection for active, loaded, saved-enabled, and saved-preloaded models. Define the service test harness with an inert telemetry source, actor fake executor, actor fake config store, fixed policy paths under a temporary home, and no live CLI access.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
swift test --filter ProviderControlServiceTests
swift test
git add Sources/DarkbloomTelemetry/ProviderControlService.swift \
  Tests/DarkbloomTelemetryTests/ProviderControlServiceTests.swift
git commit -m "feat: orchestrate provider and model controls"
```

---

### Task 7: Add the shared main-actor control store and app wiring

**Files:**
- Create: `Sources/DarkbloomMonitor/ProviderControlStore.swift`
- Modify: `Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift:16-65`
- Modify: `Sources/DarkbloomMonitor/StatusItemController.swift:6-54,100-106`
- Create: `Tests/DarkbloomTelemetryTests/ProviderControlStoreTests.swift`

**Interfaces:**
- Consumes: `ProviderControlling` and existing `MonitorStore` telemetry refresh.
- Produces: one shared `ProviderControlStore` injected into Settings and popup roots.

- [ ] **Step 1: Write failing state-machine tests**

Add a fake controller and tests for draft independence, one-command-at-a-time, warning flow, and refresh:

```swift
@Test("active restart requires confirmation but remains executable")
@MainActor
func confirmsActiveRestart() async {
    let controller = FakeProviderController(activityRisks: [.active, .active])
    let store = ProviderControlStore(controller: controller)
    await store.request(.restart)
    #expect(store.pendingConfirmation == .restart(.active))
    await store.confirmPendingLifecycle()
    #expect(await controller.executedActions == [.restart])
}

@Test("download does not stage enable or preload")
@MainActor
func keepsDownloadSeparate() async {
    let store = ProviderControlStore(controller: FakeProviderController.fixture())
    await store.refresh()
    let before = store.draft?.selection
    await store.download("gpt-oss-20b")
    #expect(store.draft?.selection == before)
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter ProviderControlStoreTests
```

Expected: compilation fails because `ProviderControlStore` does not exist.

- [ ] **Step 3: Implement published state and independent draft mutations**

Define:

```swift
@MainActor
final class ProviderControlStore: ObservableObject {
    @Published private(set) var snapshot: ProviderControlSnapshot?
    @Published private(set) var draft: ProviderConfigDraft?
    @Published private(set) var operation: ProviderOperation = .idle
    @Published private(set) var pendingConfirmation: LifecycleConfirmation?
    @Published private(set) var restartRequired = false
    @Published private(set) var errorMessage: String?

    init(controller: any ProviderControlling)
    func refresh() async
    func setEnabled(_ enabled: Bool, modelID: String)
    func setPreloaded(_ preloaded: Bool, modelID: String)
    func save() async
    func download(_ modelID: String) async
    func delete(_ modelID: String) async
    func request(_ action: ProviderLifecycleAction) async
    func confirmPendingLifecycle() async
    func cancelPendingLifecycle()
    func cancelCurrentOperation()
}

enum ProviderOperation: Equatable {
    case idle
    case refreshing
    case saving
    case downloading(String)
    case deleting(String)
    case lifecycle(ProviderLifecycleAction)
}

enum LifecycleConfirmation: Equatable {
    case stop(ProviderActivityRisk)
    case restart(ProviderActivityRisk)

    var action: ProviderLifecycleAction {
        switch self {
        case .stop: .stop
        case .restart: .restart
        }
    }

    var risk: ProviderActivityRisk {
        switch self {
        case .stop(let risk), .restart(let risk): risk
        }
    }
}
```

Use ordered arrays for selections. Toggles mutate only their own array. `canSave` requires a changed, valid draft and idle operation. Map errors to short action-specific text and retain the last good snapshot. The download output callback publishes a sanitized latest progress line while retained output remains bounded in the runner.

Define `FakeProviderController` in the test file as an actor conforming to every `ProviderControlling` method. It accepts queued `activityRisks`, records `executedActions`, counts config saves, returns a fixed fixture snapshot from `refresh()`, and returns successfully for inert model mutations. No fake method may access the live filesystem or CLI.

- [ ] **Step 4: Implement the two-read lifecycle warning flow**

For Stop/Restart, call `activityRisk()`. If active or unknown, publish confirmation. If idle, call it once more immediately before executing; a newly active/unknown result publishes confirmation instead. `confirmPendingLifecycle()` performs one final activity read for current warning copy, then executes because the user explicitly overrode the risk. Start executes without the customer-impact warning and passes `draft.original.enabled`, never unsaved staged selectors.

- [ ] **Step 5: Construct and inject one shared store**

In the app delegate, build `LocalProviderConfigStore` and `ProviderControlService` from the same home, policy, runner, and telemetry source. Construct one `ProviderControlStore`, pass it to `StatusItemController(store:controlStore:)`, and trigger its initial refresh without blocking telemetry startup. Change Settings and popover root views to receive the shared store.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
swift test --filter ProviderControlStoreTests
swift test
git add Sources/DarkbloomMonitor/ProviderControlStore.swift \
  Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift \
  Sources/DarkbloomMonitor/StatusItemController.swift \
  Tests/DarkbloomTelemetryTests/ProviderControlStoreTests.swift
git commit -m "feat: add shared provider control state"
```

---

### Task 8: Build the My Catalog and Available Settings interface

**Files:**
- Modify: `Sources/DarkbloomMonitor/MonitorSettingsView.swift:4-34`
- Create: `Sources/DarkbloomMonitor/ModelManagerView.swift`
- Modify: `Sources/DarkbloomMonitor/StatusItemController.swift:19-28`
- Create: `Tests/DarkbloomTelemetryTests/ModelManagerPresentationTests.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift:64-93`

**Interfaces:**
- Consumes: published `ProviderControlStore` inventory, draft, operation, and errors.
- Produces: General/Models tabs, separate model actions, and deletion confirmation.

- [ ] **Step 1: Write failing pure presentation tests**

Extract `ModelRowPresentation.make(item:draft:operation:)` and assert:

```swift
@Test("download enable preload and delete stay independent")
func separatesActions() {
    let row = ModelRowPresentation.make(item: downloadedItem, draft: draft, operation: .idle)
    #expect(row.showsDownload == false)
    #expect(row.showsEnableToggle)
    #expect(row.showsPreloadToggle)
    #expect(row.showsDelete)
}

@Test("delete explains every blocking state")
func blocksUnsafeDelete() {
    #expect(ModelRowPresentation.make(item: activeItem, draft: draft, operation: .idle).deleteBlockReason == "Model is currently active")
    #expect(ModelRowPresentation.make(item: enabledItem, draft: draft, operation: .idle).deleteBlockReason == "Disable and save this model before deleting it")
    #expect(ModelRowPresentation.make(item: preloadedItem, draft: draft, operation: .idle).deleteBlockReason == "Remove preload and save before deleting this model")
}
```

Define the pure presentation value before building SwiftUI:

```swift
struct ModelRowPresentation: Equatable {
    let showsDownload: Bool
    let showsEnableToggle: Bool
    let showsPreloadToggle: Bool
    let showsDelete: Bool
    let deleteBlockReason: String?

    static func make(
        item: ModelInventoryItem,
        draft: ProviderConfigDraft?,
        operation: ProviderOperation
    ) -> Self
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter ModelManagerPresentationTests
```

Expected: compilation fails because the presentation type does not exist.

- [ ] **Step 3: Implement the tabbed Settings shell**

Use:

```swift
TabView {
    GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
    ModelManagerView(store: controlStore)
        .tabItem { Label("Models", systemImage: "shippingbox") }
}
.frame(minWidth: 680, minHeight: 560)
```

Make the AppKit Settings window resizable with `.resizable` in its style mask, set its initial content size to 720 by 620 points, and retain `isReleasedWhenClosed = false`.

- [ ] **Step 4: Implement My Catalog rows**

Render a `Section("My Catalog")` in a `List`. Each row shows display name, size, live-state pill, Enable toggle, Preload toggle, and a separate trash button. Bind toggles to `setEnabled` and `setPreloaded`; never change the other binding. Show the delete block reason as help text. Eligible Delete opens an alert naming the model and formatted size before calling `store.delete(localID)`.

- [ ] **Step 5: Implement Available rows and staged-save footer**

Render `Section("Available")` below My Catalog. Show name, capabilities, size, minimum RAM, and an Add button. While downloading, replace Add with a spinner and Cancel button. Add a bottom bar containing Reload, Save Changes, validation text, `Restart required`, and the last action error.

- [ ] **Step 6: Add accessibility and hosting-size checks**

Use identifiers `models.my-catalog`, `models.available`, `models.save`, `model.<id>.enable`, `model.<id>.preload`, `model.<id>.download`, and `model.<id>.delete`. Update the Settings-window size expectations and verify an `NSHostingController` fits at 680 by 560 without horizontal clipping.

- [ ] **Step 7: Run tests and commit**

Run:

```bash
swift test --filter ModelManagerPresentationTests
swift test --filter MonitorPopoverLayoutTests
swift test
git add Sources/DarkbloomMonitor/MonitorSettingsView.swift \
  Sources/DarkbloomMonitor/ModelManagerView.swift \
  Sources/DarkbloomMonitor/StatusItemController.swift \
  Tests/DarkbloomTelemetryTests/ModelManagerPresentationTests.swift \
  Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift
git commit -m "feat: add model catalog settings"
```

---

### Task 9: Add popup Start, Stop, Restart, and customer-impact confirmation

**Files:**
- Create: `Sources/DarkbloomMonitor/ProviderLifecycleControls.swift`
- Modify: `Sources/DarkbloomMonitor/MonitorPopover.swift:4-59`
- Create: `Tests/DarkbloomTelemetryTests/ProviderLifecyclePresentationTests.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift:64-93`

**Interfaces:**
- Consumes: telemetry provider state plus `ProviderControlStore` operation and confirmation state.
- Produces: two-row popup header with accessible lifecycle icons and warning alerts.

- [ ] **Step 1: Write failing lifecycle-presentation tests**

Define `ProviderLifecyclePresentation.make(providerKnownRunning:operation:enabledModels:)`, where `providerKnownRunning` is `Bool?` and `nil` disables all actions with an unavailable-state explanation. Assert:

```swift
@Test("running provider offers stop and restart")
func runningActions() {
    let value = ProviderLifecyclePresentation.make(
        providerKnownRunning: true,
        operation: .idle,
        enabledModels: ["gemma-4-26b-qat-4bit"]
    )
    #expect(!value.canStart)
    #expect(value.canStop)
    #expect(value.canRestart)
}

@Test("stopped provider needs an enabled model")
func startRequirements() {
    #expect(!ProviderLifecyclePresentation.make(providerKnownRunning: false, operation: .idle, enabledModels: []).canStart)
    #expect(ProviderLifecyclePresentation.make(providerKnownRunning: false, operation: .idle, enabledModels: ["gpt-oss"]).canStart)
}
```

Define the exact pure presentation value:

```swift
struct ProviderLifecyclePresentation: Equatable {
    let canStart: Bool
    let canStop: Bool
    let canRestart: Bool
    let unavailableReason: String?

    static func make(
        providerKnownRunning: Bool?,
        operation: ProviderOperation,
        enabledModels: [String]
    ) -> Self
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter ProviderLifecyclePresentationTests
```

Expected: compilation fails because the presentation type does not exist.

- [ ] **Step 3: Implement compact lifecycle controls**

Create three bordered icon buttons using `play.fill`, `stop.fill`, and `arrow.clockwise`. Give them help/accessibility labels `Start Darkbloom provider`, `Stop Darkbloom provider`, and `Restart Darkbloom provider`, plus identifiers `provider.start`, `provider.stop`, and `provider.restart`. Display a `ProgressView` in the active action and disable all three controls while any mutation runs.

- [ ] **Step 4: Fit the controls into a two-row header**

Keep the first row exactly for logo/title, labeled Settings, and door Quit. Add a second compact row immediately below it:

```swift
HStack {
    Label("Provider", systemImage: "server.rack")
        .font(.headline)
        .foregroundStyle(.secondary)
    Spacer()
    ProviderLifecycleControls(store: controlStore, snapshot: store.snapshot)
}
```

Reduce vertical section spacing from 18 to 14 points and set the fixed popover to 400 by 600 points so cards and model pills retain their current sizes.

- [ ] **Step 5: Add active and unknown warning alerts**

Present `Customer work may be interrupted` with the exact body from `LifecycleConfirmation`. Buttons are Cancel plus `Stop Anyway` or `Restart Anyway`; unknown state uses `Continue Anyway`. The destructive button calls `confirmPendingLifecycle()`. Closing the alert calls `cancelPendingLifecycle()`.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
swift test --filter ProviderLifecyclePresentationTests
swift test --filter MonitorPopoverLayoutTests
swift test
git add Sources/DarkbloomMonitor/ProviderLifecycleControls.swift \
  Sources/DarkbloomMonitor/MonitorPopover.swift \
  Tests/DarkbloomTelemetryTests/ProviderLifecyclePresentationTests.swift \
  Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift
git commit -m "feat: add provider lifecycle controls"
```

---

### Task 10: Update the safety contract and perform final verification

**Files:**
- Modify: `README.md:1-190`
- Modify: `docs/ARCHITECTURE.md:1-110`
- Modify: `docs/TELEMETRY_CONTRACT.md:1-130`
- Modify: `docs/PRESENTATION_OPTIONS.md:1-80`
- Modify: `Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift:5-45`

**Interfaces:**
- Consumes: completed control surface and all focused proof.
- Produces: truthful documentation, full mechanical verification, and normal-scale visual evidence without mutating the real provider.

- [ ] **Step 1: Replace the obsolete read-only claims**

Document the exact new allowlist: fixed provider TOML, catalog/list/download/remove/start/stop/restart/status, sibling candidate, and one backup. State that all other config fields, credentials, account commands, launchd internals, and direct cache operations remain forbidden. Document picker bypass through repeated `--model` arguments and the non-atomic customer-job warning.

- [ ] **Step 2: Add final policy assertions**

Assert the provider config path is fixed, the production command factory contains no shell executable, Stop has no uninstall argument, and config-save errors never include fixture secret text.

- [ ] **Step 3: Run the complete mechanical suite**

Run:

```bash
swift test
swift build -c release
git diff --check
rg -n '/bin/sh|--uninstall|never-display-me|auth_token' Sources Tests README.md docs
```

Expected: every test passes, release build succeeds, diff check is silent, `/bin/sh` appears only in test fixtures if still required by runner hardening tests, `--uninstall` appears only in negative assertions/documentation, the fixture secret never appears in `Sources`, and credential references remain limited to existing approved earnings handling and documentation.

- [ ] **Step 4: Verify harmless live reads**

Run:

```bash
/Users/kevink/.darkbloom/bin/darkbloom models catalog --json | jq 'length'
/Users/kevink/.darkbloom/bin/darkbloom models list --json --all | jq '.models | length'
```

Expected: both return numeric counts. Do not invoke Start, Stop, Restart, download, remove, or a config save.

- [ ] **Step 5: Relaunch only the project monitor and inspect both surfaces**

Stop only a process whose executable resolves inside this project's `.build` directory, launch `.build/release/DarkbloomMonitor`, and inspect at normal macOS scale:

- first popup row retains labeled Settings and door Quit;
- second row shows Start, Stop, and Restart icons with tooltips;
- infographic cards and model pills remain readable;
- Settings opens in the same process and shows General and Models tabs;
- Models shows My Catalog and Available with separate actions;
- no control clips at the minimum window size;
- VoiceOver/Accessibility exposes all identifiers and labels.

Capture screenshots under `/tmp` only. Do not activate a real mutation to produce visual evidence.

- [ ] **Step 6: Confirm one monitor process and clean scoped Git state**

Run:

```bash
pgrep -afil 'DarkbloomMonitor(.app/Contents/MacOS/DarkbloomMonitor)?$'
git status --short --branch
git diff --check
```

Expected: exactly one current project release process. Only the two preserved unrelated untracked paths remain outside committed feature work.

- [ ] **Step 7: Commit documentation and final assertions**

Run:

```bash
git add README.md docs/ARCHITECTURE.md docs/TELEMETRY_CONTRACT.md \
  docs/PRESENTATION_OPTIONS.md Tests/DarkbloomTelemetryTests/SourcePolicyTests.swift
git commit -m "docs: document provider control safety"
```

- [ ] **Step 8: Prepare handoff without push or real provider mutation**

Report commit hashes, full test count, release-build result, screenshot paths, the untouched real-provider boundary, and any remaining untracked user-owned files. Do not push, deploy, edit the live config, or exercise destructive/provider lifecycle actions without separate authorization.
