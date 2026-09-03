# Popup Earnings and Model Throughput Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add truthful calendar earnings, earnings/hour, per-model token-rate averages, and stable model-state pills to the compact popup.

**Architecture:** Pure presentation derivation owns earnings-rate and display-threshold rules. Dedicated SQLite actors own locally observed earnings and model-rate samples for the current local date; `MonitorStore` publishes their aggregates. SwiftUI consumes those presentation values without doing source inference.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing, SQLite3, Swift Package Manager

**Spec:** `docs/superpowers/specs/2026-09-02-popup-earnings-model-throughput-design.md`

## Global Constraints

- Use the current local calendar date, from local midnight through now.
- Use the current local calendar week for the weekly total and label incomplete retained history as observed.
- Never attribute a token delta across process, model, timestamp, or counter discontinuities.
- Omit unavailable values and show the model breakdown only for at least two observed models.
- Keep read-only model presentation independent from the settings control snapshot's mutation-safety timeout.
- Preserve the 400-by-600 popup viewport and existing controls, jobs, and model-state pills.

---

### Task 1: Pure rate and presentation rules

**Files:**
- Modify: `Sources/DarkbloomTelemetry/DashboardPresentation.swift`
- Modify: `Sources/DarkbloomTelemetry/TelemetryDeriver.swift`
- Test: `Tests/DarkbloomTelemetryTests/DashboardPresentationTests.swift`
- Test: `Tests/DarkbloomTelemetryTests/TelemetryTests.swift`

**Interfaces:**
- Produces: `EarningsHourlyRate.derive(microUSD:observedSeconds:)`, model-aware token-delta validation, and the two-model breakdown threshold.

- [x] Write tests proving full and partial earnings windows divide by their actual hours, invalid windows are unavailable, one model uses the aggregate presentation, and two models use a breakdown.
- [x] Run the focused tests and confirm failures are caused by missing behavior.
- [x] Implement the minimal pure derivations.
- [x] Run the focused tests and confirm they pass.

### Task 2: Calendar-day model token-rate database

**Files:**
- Create: `Sources/DarkbloomTelemetry/ModelTokenRateDatabase.swift`
- Create: `Tests/DarkbloomTelemetryTests/ModelTokenRateDatabaseTests.swift`

**Interfaces:**
- Produces: `ModelTokenRateRecording.record(...)` and `averages(from:through:) -> [ModelTokenRateAverage]`.

- [x] Write tests for valid records, duplicate rejection, prior-date pruning, and grouped averages.
- [x] Run the focused tests and confirm the missing database API fails compilation.
- [x] Implement the SQLite actor with 0600 file permissions and bounded retention.
- [x] Run the focused tests and confirm they pass.

### Task 3: Store integration

**Files:**
- Modify: `Sources/DarkbloomMonitor/DarkbloomMonitorApp.swift`
- Modify: `Sources/DarkbloomMonitor/MonitorStore.swift`
- Modify: `Sources/DarkbloomTelemetry/AuthenticatedEarningsClient.swift`
- Test: `Tests/DarkbloomTelemetryTests/MonitorStoreDashboardTests.swift`
- Test: `Tests/DarkbloomTelemetryTests/MonitorStoreEarningsTests.swift`

**Interfaces:**
- Consumes: the rolling database and pure presentation derivations.
- Produces: published `earningsPerHour` and `modelTokenRateAverages` values.

- [x] Write store tests proving valid samples are persisted/published and earnings refresh publishes hourly rate.
- [x] Run the tests and confirm expected failures.
- [x] Inject the database through app startup and connect refresh/telemetry acceptance.
- [x] Run store tests and confirm they pass.

### Task 4: Compact popup presentation

**Files:**
- Modify: `Sources/DarkbloomMonitor/MonitorPopover.swift`
- Modify: `Tests/DarkbloomTelemetryTests/MonitorPopoverLayoutTests.swift`

**Interfaces:**
- Consumes: published store values and continuously refreshed telemetry.
- Produces: compact Earnings cards, a conditional weekly total, conditional per-model throughput rows, and stable model pills.

- [x] Write layout/presentation tests for the earnings section, complete/partial weekly labels, two-model threshold, stable model-state precedence, and fixed viewport.
- [x] Run the tests and confirm expected failures.
- [x] Implement the scrollable compact layout, accessible metric rows, calendar-week card, and read-only model-state derivation.
- [x] Run layout tests and confirm they pass.

### Task 5: Whole-product verification

**Files:**
- Verify only unless a failing check reveals an in-scope defect.

- [x] Run `swift test` and read the complete result.
- [x] Run `swift build -c release` and confirm exit zero.
- [x] Stop only the current Darkbloom Monitor process, launch `.build/release/DarkbloomMonitor`, and open its popup for normal-scale review.
- [x] Have the user inspect the live popup for clipping, spacing, hierarchy, and readable values; the user approved the rendered result.
- [x] Review `git diff` and `git status`, preserving unrelated files and leaving changes ready for review.
