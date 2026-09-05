# Model Management and Provider Controls

> Historical design retained as a baseline for the official-CLI catalog,
> configuration, and lifecycle controls. Any later text or linked design that
> describes protected live model switching, private provider endpoints, custom
> CLI branches, or staged warming is superseded and must not be implemented or
> launched. The signed vendor-released CLI is the only supported provider.

## Goal

Expand the Darkbloom menu-bar monitor from a read-only dashboard into a narrowly scoped provider control surface. The app will manage downloaded models, stage the provider's enabled and preload selections, and offer non-interactive Start, Stop, and Restart controls without exposing unrelated provider configuration or credentials.

The feature keeps four concepts visibly and behaviorally separate:

- A model is **downloaded** when its files exist in the local Darkbloom model cache.
- A model is **enabled** when the saved provider configuration permits it to serve work.
- A model is **preloaded** when the saved provider configuration asks Darkbloom to load it at provider startup.
- A model is **loaded** when live daemon telemetry reports it resident now.

No action silently changes another concept. Downloading does not enable or preload a model. Enabling does not download it. Preloading does not automatically enable it. Deleting does not alter provider configuration.

## Observed Darkbloom contract

The design targets the locally verified Darkbloom CLI 0.8.15 contract:

- `darkbloom models catalog --json` returns the supported coordinator catalog.
- `darkbloom models list --json --all` returns locally downloaded models.
- `darkbloom models download <model-id>` downloads a catalog model.
- `darkbloom models remove <model-id> --force` removes a downloaded model without an interactive CLI prompt.
- `darkbloom start --config <path> --model <model-id> ...` accepts repeated model arguments and skips the interactive picker.
- `darkbloom stop` stops the launchd provider service without uninstalling it.
- `darkbloom restart --config <path>` restarts the installed service with its current model selection.

The canonical provider configuration remains the fixed per-user path `~/.config/darkbloom/provider.toml`. Only the top-level `enabled_models` and `preload_models` arrays are in scope for editing. Existing fields such as coordinator endpoints, concurrency, slot count, beta settings, identity, and provider metadata remain untouched and undisclosed.

Live provider state continues to come from the existing bounded telemetry sources. `inference_active` is the only observed signal that work is currently running. Darkbloom does not expose an atomic drain or `if-idle` lifecycle command, so the app can warn immediately before Stop or Restart but cannot guarantee that new work will not arrive between the final check and command execution.

## Architecture

The feature uses an official-CLI-first architecture:

1. A model inventory service executes the official JSON catalog and local-list commands, then reconciles them with live loaded state and saved configuration.
2. A narrow provider configuration store reads and rewrites only the two approved TOML arrays.
3. A provider command service invokes exact CLI argument arrays for model and lifecycle actions.
4. `MonitorStore` coordinates these services and publishes immutable presentation state to SwiftUI.

No command is launched through a shell. Model identifiers and paths are passed as distinct `Process` arguments, preventing shell expansion or injection. The executable is resolved through the existing approved Darkbloom candidate list.

Direct launchd manipulation, direct cache deletion, and a privileged helper are out of scope. The official CLI remains responsible for those behaviors.

## Model inventory

`ModelInventoryService` produces a stable record for each supported model with:

- catalog ID and display name;
- family or compatibility alias when supplied by the catalog;
- model type, capabilities, version, size, and minimum RAM;
- local download ID and downloaded state;
- saved enabled and preload state;
- live active, loaded-idle, or unloaded state;
- any inventory mismatch or unavailable-source explanation.

Catalog ID is the primary identity. Reconciliation first uses an exact catalog/local/configured ID match. For compatibility with existing selectors such as `gpt-oss`, a configured selector may match a catalog entry's unique family alias. Ambiguous aliases are never guessed: the row remains visible with an explanation and its configuration controls are disabled until the user resolves it.

The inventory has two presentation groups:

- **My Catalog** contains supported catalog models whose files are downloaded locally.
- **Available** contains supported catalog models not downloaded locally.

Unrelated local MLX assets that are not in the Darkbloom coordinator catalog are not presented as provider models. A catalog failure does not erase the last good inventory; it marks that inventory stale and prevents new downloads until refreshed. A local-list failure leaves download state unavailable rather than treating every catalog entry as missing.

## Settings interface

The existing Settings window becomes a resizable, two-tab interface:

- **General** retains the menu-bar metric picker.
- **Models** contains My Catalog, Available, staged-change status, and Save Changes.

### My Catalog

Each downloaded model row shows its name, size, live status pill, and three independent controls:

- Enable or Disable stages membership in `enabled_models`.
- Preload On or Off stages membership in `preload_models`.
- Delete starts the explicit deletion flow.

The toggles do not mutate each other. Save is unavailable while the staged configuration is invalid; for example, every preloaded model must also be enabled. The inline validation message tells the user which model must be enabled or removed from preload.

Delete is unavailable while any of these are true:

- the model is active or loaded;
- the saved configuration still enables it;
- the saved configuration still preloads it;
- configuration edits are unsaved;
- inventory freshness is insufficient to prove those conditions.

The disabled control explains the blocking condition. Once eligible, Delete presents a confirmation naming the model and approximate disk space to be removed. Confirmation invokes `darkbloom models remove <local-id> --force`. Successful deletion refreshes the inventory and moves the row to Available. A failed deletion preserves the row and displays bounded CLI diagnostics.

### Available

Each non-downloaded catalog row shows display name, capabilities, model type, approximate download size, and minimum RAM. Its Add button invokes `darkbloom models download <catalog-id>`.

Downloads show an in-row spinner and status, allow cancellation, and disable duplicate model actions. Cancelling terminates only the child process started by the app. A successful download refreshes the inventory and moves the row to My Catalog without enabling or preloading it.

Only one model mutation command runs at a time. Catalog and local-list refreshes may be coalesced but never overwrite a newer mutation result.

## Provider configuration editing

Enable and preload toggles edit an in-memory draft. The configuration file is not changed until Save Changes is pressed.

When loading the draft, `ProviderConfigStore` records the source bytes and a SHA-256 revision. It parses the two top-level arrays with a string- and comment-aware scanner and retains the byte ranges that own them. Missing, duplicate, malformed, or non-string arrays produce a read-only error state rather than a guessed rewrite.

Saving follows this sequence:

1. Validate that every selected model maps unambiguously to a downloaded catalog entry.
2. Validate that `preload_models` is a subset of `enabled_models`.
3. Re-read the file and compare its SHA-256 revision with the loaded revision. If it changed externally, reject the save and offer Reload; never merge silently.
4. Replace only the two array ranges in a candidate copy, preserving all unrelated bytes, comments, ordering, and line endings.
5. Write the candidate to a private sibling temporary file with the original file permissions.
6. Validate the candidate with the official non-mutating `darkbloom status --config <temporary-path>` command.
7. Preserve the prior file as a single last-known-good sibling backup and atomically replace `provider.toml` with the validated candidate.
8. Re-read the saved file, refresh inventory, clear the draft, and show **Restart required**.

The backup is replaced only after the new candidate validates. Save failure leaves the original configuration in place and reports a bounded, human-readable error. The app never displays or logs the full TOML contents.

## Main popup lifecycle controls

The popup header adds three compact, individually accessible buttons:

- Start uses a play icon.
- Stop uses a stop icon.
- Restart uses a clockwise-arrow icon.

The existing Settings and Quit controls remain. Tooltips and accessibility labels name every lifecycle action; icons are not the sole communication channel.

Start is available when the provider is known to be stopped and at least one valid saved enabled model exists. It executes:

`darkbloom start --config ~/.config/darkbloom/provider.toml --model <enabled-1> --model <enabled-2> ...`

Each enabled model is passed through a separate repeated `--model` argument. This deliberately bypasses Darkbloom's interactive model picker. Start is disabled with an explanation when there are no enabled models or provider state cannot be determined safely.

Stop is available when the provider is running and executes `darkbloom stop`. It never passes `--uninstall`.

Restart is available when the provider is running and executes `darkbloom restart --config ~/.config/darkbloom/provider.toml`.

Only one lifecycle command may run at a time. While it runs, all three controls are disabled and the selected control shows progress. Completion triggers immediate telemetry, status, and model-inventory refreshes. Expected temporary unavailability during startup or restart is presented as a transition, not as a permanent error.

## Customer-impact confirmation

Immediately before Stop or Restart, the app refreshes daemon state rather than trusting the last rendered snapshot.

- If fresh state reports `inference_active == true`, show: **A customer job is currently running. Continuing will interrupt it.** Actions are Cancel and Stop Anyway or Restart Anyway.
- If activity cannot be determined from fresh state, show: **Darkbloom Monitor cannot confirm whether a customer job is running. Continuing may interrupt customer work.** Actions are Cancel and Continue Anyway.
- If fresh state reports idle, execute without an extra warning.

After confirmation, the app performs one final state read. If the state newly changed from idle or known-safe to active or unknown, it presents the appropriate warning before execution. Once the user explicitly confirms the current warning, the app permits the requested action as directed.

The warning is an informed override, not a claim of transactional safety. The UI documentation explicitly notes that Darkbloom 0.8.15 has no drain or atomic idle guard.

## Command execution and errors

Read commands retain short bounded timeouts. Lifecycle commands receive a larger bounded timeout suitable for launchd transitions. Model downloads use a dedicated long-running child-process path with bounded retained output, streamed progress when available, and explicit cancellation. Every process path:

- captures stdout and stderr separately;
- caps retained output;
- owns and terminates only the child it launched;
- rejects overlapping mutations;
- redacts the home directory and any credential-shaped text from user-visible diagnostics;
- never persists command output containing secrets.

Failures remain attached to the action that failed. A download failure does not make provider telemetry unavailable. A configuration failure does not erase the inventory. A lifecycle failure does not imply the provider stopped; the app refreshes authoritative state before presenting the outcome.

## Security and scope changes

This feature intentionally supersedes the monitor's original read-only policy, but only for the approved control surface. The revised policy permits:

- reading and narrowly rewriting the fixed provider TOML file;
- official catalog, list, download, remove, start, stop, restart, and candidate-validation commands;
- a private same-directory temporary file and one last-known-good configuration backup.

It still forbids arbitrary command execution, shell invocation, direct launchd edits, direct cache deletion, credential display, account changes, login/logout, update, enrollment, beta-feature changes, and edits to any other provider field.

## Testing

Pure and fixture-driven tests cover:

- catalog and local-list decoding, including missing and extra fields;
- exact-ID, unique-family-alias, ambiguous-alias, and unmatched inventory reconciliation;
- My Catalog versus Available grouping;
- independent downloaded, enabled, preloaded, loaded-idle, and active states;
- no implicit state changes between Download, Enable, Preload, and Delete;
- delete eligibility and confirmation copy;
- TOML array parsing with inline comments, multiline arrays, escaped strings, CRLF, malformed arrays, duplicates, and missing keys;
- byte preservation outside the two edited ranges;
- preload-subset validation;
- external revision conflict rejection;
- candidate validation failure, backup creation, atomic replacement, permissions, and rollback behavior;
- exact shell-free command argument arrays;
- non-interactive Start with one and multiple enabled models;
- lifecycle availability, overlap prevention, and refresh behavior;
- active, idle, stale, unavailable, and changed-during-confirmation customer-impact flows;
- download cancellation and bounded-output behavior;
- independent errors for inventory, configuration, model mutation, and lifecycle control;
- accessibility identifiers, labels, help text, and stable popup layout.

Automated tests use fake command runners and temporary configuration fixtures. They never stop, restart, download, or delete from the real provider installation.

Verification before handoff includes the full Swift test suite, release build, diff and secret scans, a normal-scale visual review of both Settings tabs and the popup controls, and harmless live catalog/list reads. Start, Stop, Restart, download, deletion, and real `provider.toml` writes require explicit live-test authorization and are not inferred from unit-test success.

## Acceptance criteria

- The user can see downloaded models under My Catalog and non-downloaded supported models under Available.
- Download/Delete, Enable/Disable, and Preload are separate controls with no implicit cross-action.
- Configuration changes remain staged until Save Changes and preserve unrelated TOML content.
- A saved model selection can start the provider without the interactive CLI picker.
- Start, Stop, and Restart are available from compact popup icons with clear progress and accessible names.
- Active or unverifiable work produces an explicit customer-impact confirmation while preserving the user's ability to continue.
- Unsafe deletion, invalid preload configuration, concurrent file edits, and overlapping commands fail closed with actionable explanations.
- The app never exposes credentials, invokes a shell, uses `stop --uninstall`, or mutates provider state during automated tests.
