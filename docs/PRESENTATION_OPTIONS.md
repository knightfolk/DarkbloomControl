# Menu Presentation Options

The telemetry model stays identical across all options.

**Selected and implemented: Option A, the structured popover.** Options B and C
remain design history and are not alternate modes in the application.

## Option A: Structured popover (selected)

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

Decision: Option A, with no charts. A chart would imply historical precision
that the current cumulative counters do not provide.
