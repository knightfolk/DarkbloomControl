# Alpha 2 — Official CLI compatibility

Darkbloom Monitor now supports only the official, unmodified Darkbloom CLI.
This release does not install, patch, or bundle the provider CLI.

## Changes

- Removed private model-control APIs, manual live warming, staged switching,
  automatic demand switching, and their unavailable controls.
- Kept official one/two-slot settings, Enable/Preload, separate model
  download/delete actions, and Start/Stop/Restart with customer-impact checks.
- Removed the unreliable runtime-based “Restart required” indicator. Save
  model settings, then restart the provider to apply them.
- Removed realtime throughput claims. During activity, the menu bar and popup
  show Working or a clearly labeled observed model average.
- Compact model settings keep advanced information under Details.
- Retained model demand, calendar earnings, model-rate history and opt-in
  electricity estimates, including a collection placeholder before matched
  earnings and electricity data are available.
- Startup no longer enables an unnecessary local HTTP endpoint.

## Download and signing

- `DarkbloomMonitor-v0.1.0-alpha.2-arm64.zip`: macOS 14 or newer, Apple Silicon.
- App version 0.1.0, build 8; signed with Developer ID Application:
  KEVIN PATRICK KNIGHT (5P2LWPPWRN), with hardened runtime and secure timestamp.
- **Not notarized.** Apple notarization credentials are not configured in this
  release environment. Gatekeeper may block the downloaded app.
- `SHA256SUMS.txt` provides the ZIP checksum.
- Intel users can build from source with Swift 6; no Intel binary is included.

This is alpha software. Electricity readings estimate whole-Mac adapter input,
not provider-only or wall power. Historical rates are not streaming rates.
Changing model settings still requires a provider restart, which can affect
customer work. Review the confirmation before stopping or restarting.

The installed official CLI was verified locally as version 0.8.16 with a valid
Eigen Labs signature. This is not an exhaustive compatibility certification for
every future CLI release.
