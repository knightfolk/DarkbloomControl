# Architecture Notes

## Boundary

`DarkbloomTelemetry` owns local acquisition, parsing, normalization, and
derivation. `DarkbloomMonitor` owns the macOS menu-bar lifecycle and eventual
presentation. The UI consumes a normalized snapshot and never reads files or
launches processes directly.

## Planned data flow

1. Poll `~/.darkbloom/daemon-state.json` and `loaded-models.json` every two
   seconds using coordinated, read-only file access.
2. Run `darkbloom status` at a slower cadence for configuration and hardware
   fields not present in daemon state. The command is local and read-only; the
   adapter rejects commands that could reveal credentials or perform network
   verification.
3. Read only the final bounded byte window of `provider.log`. Optionally ingest
   bounded unified-log JSON from the local `log` process. Retain at most 100
   normalized lifecycle/warning/error events.
4. Validate process identity (`pid` plus `start_time_micros`) before comparing
   successive counters.
5. Derive tokens/second only from a positive `tokens_generated` delta divided
   by a positive `written_at` delta. Label the result `derived`; otherwise emit
   an explicit unavailable reason.
6. Publish an immutable snapshot on the main actor. A source failure affects
   only that source and is displayed as stale or unavailable.

## Trust boundaries

The monitor does not read `provider.toml`, `auth_token`, model weights, caches,
or local endpoint credentials. Paths printed by `darkbloom status` are treated
as display strings, never followed. Log messages are untrusted text and must be
rendered literally without link activation or command execution.
