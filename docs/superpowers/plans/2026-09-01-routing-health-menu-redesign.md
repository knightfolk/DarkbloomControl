# Routing Health Menu Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a four-color routing-health Darkbloom logo, active-throughput/idle-earnings menu text, persisted display modes, and a concise collapsible popover.

**Architecture:** Keep source acquisition and deterministic presentation models in `DarkbloomTelemetry`. Let `MonitorStore` own macOS thermal observation and the authenticated earnings polling lifecycle, then pass one pure `MenuBarPresentation` value to SwiftUI. Preserve the existing telemetry service and move existing detail views behind disclosure groups instead of deleting telemetry.

**Tech Stack:** Swift 6.0, Swift Package Manager, Foundation, Foundation URL loading, SwiftUI, AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-01-routing-health-menu-redesign.md`

## Global Constraints

- Use the supplied Darkbloom logo silhouette with adaptive SwiftUI system colors: green, yellow, orange, and red.
- Red always means not routable and overrides the thermal warning color.
- Do not log, display, or persist the Darkbloom auth token.
- Only call the fixed HTTPS account-earnings and public leaderboard endpoints with GET requests.
- Never report a partial earnings history as an actual rolling 24-hour total.
- Poll earnings every ten minutes, deduplicate with one high-water mark, and persist inference work and `base_reward` events in separate hourly aggregates, never an unbounded per-job ledger.
- Preserve existing telemetry detail, stale reasons, and explicit unavailable states.
- Keep the popover fixed at 420 by 680 points.

---

### Task 1: Pure routing and menu presentation

**Files:**
- Create: `Sources/DarkbloomTelemetry/MenuBarPresentation.swift`
- Modify: `Sources/DarkbloomTelemetry/TelemetrySnapshot.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPresentationTests.swift`

**Interfaces:**
- Produces `SystemThermalState`, `RoutingHealth`, `MenuBarDisplayMode`, `DarkbloomLogoShape`, and `MenuBarPresentation.make(snapshot:thermal:earnings:mode:)`.

- [ ] Add literal tests for green/yellow/orange thermal mapping, red offline/unavailable/critical precedence, active token-rate selection, idle earnings selection, and accessibility labels.
- [ ] Run `swift test --filter MonitorPresentationTests` and confirm the new tests fail because the presentation types do not exist.
- [ ] Implement the smallest pure presentation model that satisfies those tests.
- [ ] Rerun the focused tests and keep them green.

### Task 2: Authenticated rolling earnings

**Files:**
- Create: `Sources/DarkbloomTelemetry/AccountEarnings.swift`
- Create: `Sources/DarkbloomTelemetry/AuthenticatedEarningsClient.swift`
- Create: `Sources/DarkbloomTelemetry/EarningsDatabase.swift`
- Create: `Tests/DarkbloomTelemetryTests/AccountEarningsTests.swift`
- Create: `Tests/DarkbloomTelemetryTests/EarningsDatabaseTests.swift`

**Interfaces:**
- Produces `AccountEarningsResponse`, `RollingEarnings24h`, `AccountEarningsParser`, `AccountEarningsRequest`, compact `EarningsDatabase` hourly buckets, and `AuthenticatedEarningsClient.fetch(now:)`.

- [ ] Add fixture-style tests for fractional and whole-second dates, exact micro-USD summation at the 24-hour boundary, rejection of truncated windows, and the fixed authenticated GET request without exposing token content in descriptions.
- [ ] Run `swift test --filter AccountEarningsTests` and confirm the new tests fail for missing types.
- [ ] Implement decoding, completeness checks, request construction, fixed-path token loading, and the URL-session fetch.
- [ ] Rerun the focused tests and keep them green.

### Task 3: Store lifecycle and menu label

**Files:**
- Modify: `Sources/DarkbloomMonitor/MonitorStore.swift`
- Modify: `Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift`
- Modify: `Sources/DarkbloomMonitor/MenuBarLabel.swift`
- Test: `Tests/DarkbloomTelemetryTests/MonitorPresentationTests.swift`

**Interfaces:**
- `MonitorStore` publishes thermal state, earnings availability, and a computed menu presentation; it owns and cancels notification and polling tasks.

- [ ] Add a failing consumer-level test for the final menu label text and routing indicator inputs.
- [x] Subscribe to macOS thermal notifications, poll earnings every ten minutes, and cancel both during shutdown.
- [ ] Persist `MenuBarDisplayMode` with `AppStorage` at the app scene boundary.
- [ ] Render the semantic circle plus selected compact metric and full accessibility value.

### Task 4: Collapsible popover

**Files:**
- Modify: `Sources/DarkbloomMonitor/MonitorPopover.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift`

**Interfaces:**
- The popover accepts the store and selected display-mode binding; its header stays visible and all detail sections use independent disclosure state.

- [ ] Add a failing layout/behavior test that instantiates the popover at 420 by 680 points and verifies collapsed defaults through exposed presentation state rather than source-text matching.
- [ ] Replace the dense always-expanded stack with the approved summary and seven disclosure groups.
- [ ] Add the persisted display-mode picker inside the Menu-bar settings disclosure.
- [ ] Preserve all existing detail views and their unavailable/stale copy.

### Task 5: Full proof and live handoff

**Files:**
- Modify documentation only if implemented behavior differs from the old privacy contract.

- [ ] Run `swift test` and confirm zero failures.
- [ ] Run `swift build -c release` and confirm a successful warning-free build.
- [ ] Stop only the current project monitor process, relaunch the release executable, and open the popover.
- [ ] Inspect the visible result at normal scale and check the running process network destinations.
- [ ] Report the live status, verification evidence, and any remaining endpoint-history limitation.
