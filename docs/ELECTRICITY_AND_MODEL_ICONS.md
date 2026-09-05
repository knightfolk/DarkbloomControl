# Electricity and model-family indicators

Tracking is off by default. Settings → Electricity accepts a nonnegative,
finite USD-per-kWh price (for example, 0.15 means fifteen cents). No currency
conversion is performed. Clearing or invalidating the price hides the metrics.

On supported Macs, the app reads AppleSmartBattery PowerTelemetryData's
SystemPowerIn through IOKit without administrator access. The value is interpreted
as milliwatts, corroborated by the power-monitor implementation at
https://gist.github.com/robzr/2abf9c7e7f576d8af00d90b671489b48.
This is an undocumented hardware-dependent source: missing, disconnected, zero,
or implausible readings are unavailable. It measures estimated whole-Mac DC
adapter input, not wall power or the provider's isolated consumption. Adapter
losses and other operating expenses are excluded. No privileged helper is used.

Samples are taken approximately every ten seconds. Trapezoidal integration uses
actual elapsed time; intervals over thirty seconds, tariff/source changes, clock
reversal, disabled tracking and app restarts break continuity. A rate of zero is
accepted only when explicitly entered. Unknown power is never treated as zero.

History is stored atomically in `~/Library/Application Support/Darkbloom Monitor/energy-history.json`,
bounded to 60,480 intervals and 24 MiB. Restart restores completed intervals,
not an unfinished measurement chain. Each interval retains its original tariff.
Unreadable history is preserved instead of silently replaced.

The popup shows fresh adapter watts immediately. Electricity and earnings after
electricity appear only for completed, recorded earnings hours fully covered by
energy measurements within the current local calendar date. Incomplete hours
are excluded, not prorated. The matched-hour count and estimated/partial labels
remain visible. This is not a full net-profit calculation or a full-day total.
The first matched result normally requires tracking through a complete hour.

The menu bar uses Qwen, OpenAI (GPT-OSS), or Google (Gemma) marks during current
inference. A process-matched unified `loop` log beginning `Loading model:` can
also establish a loading indication for up to sixty seconds. Completion,
unloading, loop errors, residency, stale telemetry or expired evidence clear it.
Legacy logs without process IDs cannot establish loading. Unknown families,
offline providers and warm-but-idle models use the Darkbloom mark. Providers
without usable unified logs retain the default icon during loading rather than
guessing. Long loads may outlast the conservative indication window.

The fixed menu-bar dimensions and rate text are unchanged. Icon tint retains
routing-health meaning. Model assets and the MIT notice are bundled together;
see `Resources/MODEL-ICONS-LICENSE.txt` for pinned provenance. Brand marks identify
models, not affiliation or endorsement; the asset license grants no trademark rights.
