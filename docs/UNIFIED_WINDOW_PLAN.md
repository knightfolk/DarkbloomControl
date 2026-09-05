# Unified Dashboard and Settings

User direction: use one window rather than separate Settings and Dashboard windows. Settings belongs in the Dashboard sidebar; the popup gear opens that section directly. Model management remains in Models.

## Current source findings

- StatusItemController eagerly creates a separate 720×620 settings window and lazily retains DashboardWindowController.
- DashboardRootView already has Models, backed by the same ProviderControlStore. MonitorSettingsView duplicates model management in a tab next to General.
- General currently contains the menu-bar display preference, persisted with AppStorage. Provider drafts live in ProviderControlStore and must not be replaced during navigation.
- Dashboard sidebar selection is persisted with AppStorage but currently private to its view. External Settings entry points need an explicit navigation model instead of opening another window.
- App commands and popup actions both route through StatusItemController.showSettings. Dashboard toolbar currently routes back to that separate window.

## Implementation sequence

1. Add one retained dashboard navigation state with typed sections including Settings; preserve the existing selected-section preference and unknown-value fallback. Test selection routing and persistence with isolated defaults.
2. Render the existing General settings controls in Settings; remove the duplicate Models tab from that route. Keep Models on the existing shared control store. Do not refresh or reconstruct the store on selection changes.
3. Make showSettings select Settings and present the same retained DashboardWindowController used by showDashboard. Remove the separate settings window allocation and obsolete window-specific test accessors. Replace their tests with same-window identity, direct Settings routing and retained draft assertions.
4. Route toolbar, popup gear and Command-comma through the same action. Inspect the app's Settings scene so it cannot expose a second usable settings surface. Preserve menu-bar-only launch behavior and existing Dashboard command.
5. Verify close/reopen and frame restoration, Models draft navigation, menu preference persistence and startup without an extra window. Run full tests and release build.
6. Inspect the actual unified window at its minimum size. Only after checking for an open unsaved draft, relaunch the monitor in the background for review. Never restart the provider for this UI change.

## Acceptance evidence

One NSWindow identity across Dashboard and Settings actions; visible Settings sidebar selection from gear and Command-comma; no duplicate Models controls in Settings; unsaved provider draft unchanged after Settings/Models navigation; persisted menu preference; successful minimum-size visual review; full suite and release build. Implementation and visual verification are still pending.

This supersedes the integration plan's separate-settings-window assumptions without shrinking its other requirements. No commit, push or release publication is implied.

## Implementation checkpoint

Additional appearance proof: settingsMinimumSize now covers Aqua and Dark Aqua at the configured minimum dashboard size. renderModelContext covers both appearances at 620-point detail width and 560/900-point heights. Inspected the minimum-height screenshots /tmp/darkbloom-unified-settings-light.png, /tmp/darkbloom-unified-settings-dark.png, /tmp/darkbloom-model-context-560-light.png and /tmp/darkbloom-model-context-560-dark.png. Settings text is readable without a duplicate Models tab; Models scrolls while Reload/Save Changes remain fixed and visible. The staged draft is unchanged. Six render cases passed (/tmp/unified-appearance.log), and all test windows close. These are isolated view fixtures, not proof of native gear/Command-comma operation in the running app.

Runtime update: the latest release was launched via the exact executable path after the user reported another stale instance. Current monitor PID 58793 replaces 44544. Stale visual-evidence bundle PID 52590 was separately stopped; its appearance followed an app-name lookup, which must not be repeated. Provider PIDs 49767/49775 were preserved. Startup error log was empty on the post-launch check. This supersedes the earlier relaunch-pending notes below, but native gear/Command-comma interaction proof remains open.

StatusItemController now routes Settings and Dashboard to the same retained DashboardWindowController. Settings is a sidebar destination; General controls render there without the duplicate Models tab. Explicit navigation state preserves the saved destination and falls back to Overview for unknown values. Test preferences are isolated. Removed the unused Dashboard openSettings callback.

Verified same-window routing, saved destination/fallback, unchanged staged model/slot draft across Models → Settings → Models, and minimum-width rendering. Inspected /tmp/darkbloom-unified-settings.png. Full suite after capacity validation and routing cleanup: 508 tests in 49 suites passed; release build passed. The existing running monitor was not replaced because native window inspection could not establish whether an unsaved draft existed. User confirmation to save/discard remains pending; native gear/Command-comma end-to-end verification is therefore still open.

Copy audit found a separate calendar consistency gap, now corrected in source: MonitorStore.menuPresentation uses dated todayEarnings rather than rolling account earnings. ObservedEarningsWindow carries day start, capture time and day-to-date coverage. Calendar menu values reject observations older than 600 seconds, future observations, missing provenance and a different local day. Complete values display /d; partial observations display /d* with explicit accessibility coverage text. A store regression uses $9 rolling versus $1.23 partial calendar earnings and verifies the calendar amount is selected. Isolated native rendering caught truncation with the longer /day* suffix; /d* fits the unchanged 96×18 content size. Inspected /tmp/darkbloom-calendar-menu.png. Latest full suite: 511 tests in 50 suites passed; release build and whitespace check passed. This is isolated label proof, not a live system menu-bar screenshot. Monitor relaunch remains pending.
