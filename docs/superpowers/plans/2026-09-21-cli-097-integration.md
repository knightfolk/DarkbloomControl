# CLI 0.9.7 integration plan

Goal: implement the supported improvements in the September 21 CLI review, preserving provider work and existing controls.

Architecture: optional backward-compatible telemetry fields, bounded official CLI diagnostics/commands, a shared app mutation gate, and small SwiftUI sections in existing dashboard/settings. No private provider API, automatic model switching, enrollment mutation, or inferred per-request streaming metrics.

Scope and ownership:
- Telemetry: advertised models, authorization with freshness/process/coordinator validation, MTP/KV/load explanations, current status labels; older schema-1 compatibility.
- Catalog: runtime requirements and model details, honest supported/unsupported/unverified presentation, updated branding.
- Official CLI extras: read-only idle/beta/fan/update posture; user-invoked idle/beta saves, restart-required state, bounded source failure handling.
- Integration: saved versus running model state and restart confirmation; diagnostics/thermal panels; network draining/cache health; lifecycle and UI verification.

Verification:
- Meaningful regression tests for missing/unknown fields, stale/wrong-process/wrong-coordinator authorization and expiry, unsupported hardware, invalid commands, external settings changes, current/legacy CLI output, and maintenance responses.
- Run complete Swift tests and release build. Package a new review bundle; preserve unsaved drafts and existing provider process. Inspect native rendered overview, Models, Health and Settings at normal scale.
- Update README and source/API contracts. No push, release publication or provider configuration changes during verification.

Checklist:
- [x] Telemetry and verification diagnostics
- [x] Model capabilities/details/branding
- [x] Fan/temperature, idle and beta functionality
- [x] Saved/runtime selection and safe lifecycle confirmation
- [x] Network maintenance and optional cache health
- [x] Documentation, full tests/build, live visual inspection

Verification update: 523 tests in 68 suites pass. Native network cache and thermal panels were inspected; synthetic native idle save and beta enable paths were exercised without provider writes. Packaged-app CLI model scanning stalls opening the external-volume cache; terminal reads succeed. After the user approved access, the final packaged build populated Models and Settings successfully; live visual verification is complete. See `docs/CLI_097_VERIFICATION.md`.
