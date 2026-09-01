# Routing Health Menu Redesign

## Goal

Make the Darkbloom monitor glanceable: the menu bar communicates routing health and the most useful live metric, while the popover keeps a concise summary visible and moves detail into independently collapsible sections.

## Menu-bar contract

The supplied Darkbloom logo silhouette represents overall routing health in place of a generic circle. It uses macOS semantic system colors rather than fixed RGB values:

- Green: routable with nominal thermal pressure.
- Yellow: routable with fair thermal pressure; Darkbloom treats the provider as degraded.
- Orange: routable with serious thermal pressure; Darkbloom applies a stronger routing penalty.
- Red: not routable for any reason. Critical thermal pressure is one possible reason, but offline, unavailable, and other blocking provider states also take precedence and render red.

The logo geometry remains constant across states. Its accessible label always names both the routing condition and thermal state, and the popover repeats the status in text so color is never the sole status channel.

The default menu metric is automatic:

- While inference is active, show the derived token rate as `N tok/s`.
- While idle, show authenticated rolling 24-hour earnings as `$N.NN/24h`.
- If the selected value is not yet available, show a compact em dash rather than a fabricated zero.

Settings also offer Throughput, Earnings, Model, and Status-only modes. The preference is persisted with `AppStorage`.

## Thermal source and precedence

The app observes `ProcessInfo.processInfo.thermalState` and `thermalStateDidChangeNotification`. The mapping to nominal, fair, serious, and critical is one-to-one. An unknown future Apple state is treated as serious, preserving a visible warning without falsely claiming routing is blocked.

Routing state has precedence over the thermal color. A provider that is offline, unavailable, stale beyond the routing-safe window, or critical is red. When red, the popover names the actual blocking reason.

## Earnings boundary

The monitor performs a read-only authenticated `GET` to `https://api.darkbloom.dev/v1/provider/account-earnings?limit=1000`, using the CLI device token from the fixed path `~/.darkbloom/auth_token` as a Bearer token. The token is trimmed in memory, never displayed, persisted, or logged.

The response is decoded into per-job earning records. Rolling 24-hour earnings are summed directly only when those records cover the full window. For busy accounts that hit the 1,000-row cap, the monitor derives the account's official pseudonym from the authenticated account ID and reads the exact server-computed row from the public 24-hour earnings leaderboard. If neither source covers the account, the value remains explicitly unavailable rather than undercounted.

The endpoint is polled every ten minutes so the capped 1,000-row page is unlikely to be exhausted between observations. A single earning-ID high-water mark deduplicates overlapping pages. Inference work is stored in compact hourly aggregates by model; entries marked `base_reward` are stored in a separate hourly reward series and never increment work job or token totals. Changed lifetime, available-balance, and withdrawable-balance values are stored at most once per hour; unchanged polls write no history. The private SQLite database under Application Support does not retain one row per job, account IDs, provider keys, or tokens. The menu's rolling 24-hour amount includes work and all rewards. Failures preserve the last good value as stale for the popover, but the menu bar does not silently present stale money as current.

## Popover hierarchy

The fixed 420 by 680 point popover remains. Its always-visible summary contains:

- routing status and reason;
- active or idle state;
- current model;
- token rate when active or rolling 24-hour earnings when idle;
- current thermal state.

Every detail area is an independent `DisclosureGroup`, collapsed by default:

- Performance
- Models and slots
- Memory and process
- Trust
- Recent events
- Advanced
- Menu-bar settings

Blocking warnings remain visible in the summary even when every disclosure is collapsed. Existing source provenance, stale reasons, unavailable reasons, event bounds, and diagnostic content remain intact inside their sections.

## Verification

- Pure tests cover thermal mapping, red routing precedence, menu metric selection, accessibility copy, earnings decoding, 24-hour summation, incomplete-history handling, and request construction.
- Existing service and parsing tests remain green.
- `swift test` and release `swift build` pass.
- The running app is relaunched and visually inspected at normal macOS scale with the popover open.
- The live process is checked to ensure the only new network destination is the approved Darkbloom API endpoint.
