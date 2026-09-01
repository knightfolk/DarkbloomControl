# Darkbloom Monitor

A native macOS menu-bar monitor for a locally running Darkbloom provider. This
repository is currently at the **telemetry-contract and reversible scaffold**
stage: the read-only parsers and rate derivation are specified by tests, while
the final menu presentation is intentionally awaiting review.

## Safety boundary

- Reads local telemetry only.
- Never opens `~/.darkbloom/auth_token`.
- Never invokes `darkbloom local`, which prints a local API key.
- Never edits Darkbloom configuration or state.
- Does not make network requests.
- Ignores `attestation_public_key` and unknown state fields during decoding.
- Tails only a bounded byte window and retains only a bounded event count.

## Observed local sources

The contract was inventoried against Darkbloom 0.8.15 on 2026-08-31. See
[`docs/TELEMETRY_CONTRACT.md`](docs/TELEMETRY_CONTRACT.md) for source-by-source
coverage and explicit gaps.

## Run the scaffold

```bash
swift test
swift run DarkbloomMonitor
```

The package opens directly in Xcode (`open Package.swift`). The executable is a
minimal shell until one of the presentation options in
[`docs/PRESENTATION_OPTIONS.md`](docs/PRESENTATION_OPTIONS.md) is selected.
