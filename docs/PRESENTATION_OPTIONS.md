# Menu Presentation Options

The telemetry model stays identical across all options.

**Current implementation: Option D, the infographic dashboard.** Options A, B,
and C remain design history and are not alternate modes in the application.

## Option D: Infographic dashboard (current)

A fixed 400-by-560-point SwiftUI popover shows two large throughput values, two
large completed-job values, and color-coded model capsules. A labeled Settings
control opens the monitor-owned settings window, while an icon-only door control
stops the accessory app cleanly. Detailed diagnostics stay in the telemetry
layer rather than becoming popover prose. Trade-off: operators use the CLI or
logs when they need low-level diagnostics.

## Option A: Structured popover (superseded)

A compact SwiftUI popover with a top health row, primary live metrics, model
and slot cards, then a scrollable recent-events list. It supports every field,
explicit unavailable states, and enough hierarchy to keep dense telemetry
scannable. Trade-off: slightly more custom UI than a standard menu.

## Option B: Native hierarchical menu

Use a standard `MenuBarExtra` menu with disabled value rows and nested model,
slot, and event submenus. It feels maximally native and keyboard-friendly.
Trade-off: dense data is harder to scan, long event messages fit poorly, and
unavailable explanations become cumbersome.

## Option C: Minimal menu plus inspector window

Keep the menu to trust, model, activity, derived rate, and warnings; open a
separate resizable inspector for all fields and events. This best accommodates
future telemetry growth. Trade-off: full detail is no longer one click away in
the menu itself and window management adds complexity.

The original no-chart decision remains: a chart would imply historical
precision that the current cumulative counters do not provide.
