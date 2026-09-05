# Menu Presentation Options

The telemetry model stays identical across all options.

**Current implementation: Option D, the infographic dashboard.** Options A, B,
and C remain design history and are not alternate modes in the application.

## Option D: Infographic dashboard (current)

A fixed 400-by-600-point SwiftUI popover shows two large throughput values, two
large completed-job values, and color-coded model capsules. Its first row keeps
a labeled Settings control and an icon-only door control that stops the
accessory app cleanly; a second row exposes Start, Stop, and Restart provider
controls. Stop and Restart show an explicit customer-impact confirmation when
activity is active or unknown. The confirmation is a deliberate override, not
a claim that the operation is interruption-free.

Settings opens in the same process with General and Models tabs. Models uses
separate My Catalog and Available sections: Download/Delete remain distinct
from Enable/Disable and Preload/Unpreload, and a changed configuration displays
restart-required rather than restarting automatically. Detailed diagnostics
stay in the telemetry layer rather than becoming popover prose. Trade-off:
operators still use the CLI or logs for low-level diagnostics.

The Models settings expose the official one-model **Memory Saver** and
two-model capacity choices. The second slot is provider capacity, not a
monitor-reserved staging slot. The monitor does not offer Warm, automatic
demand-based switching, or live resident switching because the official CLI
does not expose the required operator API; applying a different resident model
uses the normal official CLI configuration/startup path.

The popup shows compact demand rows for enabled local models only, ranked by
urgent/high/moderate/low pressure, and labels the last-good sample when it is
stale. Demand rows are informational network context; they do not authorize a
local model switch or residency mutation. Model rows report current official
telemetry state and do not expose a Warm action.

Unsupported live switching is represented as unavailable/Coming Soon rather
than as a retrying action. The monitor never implies that it can evict another
model or stage a replacement in a second slot.

The presentation uses typed source freshness to gate Save and Download, while
the service repeats fresh validation before those commands. Model pills fail
closed to `Model state unavailable` when the required residency sources are not
fresh. Model-row actions name their target in accessibility labels and include
hints for disabled or cancellation behavior. Lifecycle controls use labels,
help text, and identifiers; their customer-impact detail appears in the
Stop/Restart confirmation alert. Rendered diagnostics are bounded and redacted.
Raw or unbounded CLI output is not presented, except that a current download may
show one latest sanitized progress line from stdout or stderr with a 4,096-byte
input bound.

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
