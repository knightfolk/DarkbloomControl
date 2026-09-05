# Live Model Control and Demand Design

Date: 2026-09-03
Status: Implemented locally across monitor and provider; runtime installation pending

## Goal

Let an operator enable multiple downloaded models, see current network demand for each enabled model, and choose which model to warm without restarting the provider for each choice. Never interrupt customer inference. Keep the Mac usable by making residency limits and staging headroom explicit.

## Separate concepts

- **Downloaded** means present in the local model cache.
- **Enabled** means advertised to the coordinator and eligible for network work.
- **Preload** means preferred for provider startup.
- **Resident** means weights currently occupy a provider model slot.
- **Active** means a resident model is serving inference.
- **Demand** is current network work and warm-provider supply from the public capacity endpoint. It is not provider payout.

Enable, Preload, Download, Delete, and Warm remain separate operations.

## Capacity modes

The app edits the provider's real `max_model_slots` setting through the existing conflict-checked, metadata-preserving configuration transaction. Saving a capacity change requires one provider restart before it takes effect.

### 1 - Memory Saver

- At most one model is resident.
- A manual change waits for fresh idle state.
- The old idle model must unload before the requested model can load.
- No customer request is interrupted, but the provider has a cold-load availability gap.
- If the replacement load fails after the old model retires, fresh reconciliation
  reports the partial state; the monitor does not claim an automatic rollback.

This mode cannot satisfy load-before-unload because there is no second place to hold the incoming weights.

### 2 - Two-model capacity

- The coordinator may load and serve as many as two enabled models.
- The second slot is shared network capacity, not a monitor-reserved staging slot.
- A coordinator-prefetched or otherwise unknown resident also consumes that slot.
- A coordinator hard swap keeps two-slot capacity while the superseded model is no longer advertised but remains resident long enough to drain; effective capacity is derived from the distinct advertised/resident union and never exceeds the configured cap.
- A manual staged load is considered when fewer than two models are resident. An existing customer job may continue on the old model while the new model loads.
- A configurable 8-24 GiB reserve, defaulting to 16 GiB, must remain after the target's padded weight estimate. The gate uses the lower of provider-reported free capacity and live whole-system reclaimable memory so other applications count against staging room.
- In exact terms, staging requires `min(max(0, total - gpuActive - gpuCache), systemAvailable) >= targetSize * 1.2 + reserve`.
- If both slots are occupied, headroom is insufficient, or system-memory evidence is unavailable, the action remains unavailable; it never evicts to make room.

## Provider capability boundary

Darkbloom CLI 0.8.15 has an authenticated unified local endpoint, but its local chat-completion acquisition uses the provider's ordinary eviction-capable load path. The local provider branch `codex/protected-model-control` now exposes a separate authenticated operator surface:

- `GET /v1/provider/model-control` advertises the versioned protected-load and idle-retire capabilities, current residency, the mutable advertised set, the immutable launch selection, and the raw running Enable/Preload/hard-cap configuration.
- `POST /v1/provider/model-control/load` calls `ensureModelLoaded(modelId:allowEviction:false)` inside the provider actor.
- `POST /v1/provider/model-control/retire` unloads one exact model only when it has no coordinator or local request in flight.

Therefore:

- one-slot cold switching retires the old model through the idle-only operation before loading the target;
- two-model switching loads the target first, then asks the provider to retire the previous model;
- a previous model that gained customer work during staging is not retired, so both models remain resident;
- the legacy chat-completion warmup client remains classified `mayEvictResident` and is not used by the live service;
- capability discovery, rather than version guessing, controls whether the action is offered.

This capability gate is mandatory. A host-side free-memory estimate alone cannot prove the provider will not evict because memory and slot state can change between processes.

## Idle retirement

The installed provider accepts idle timeout in whole minutes and its idle monitor scans periodically, so the monitor does not repurpose that global setting. The local provider branch adds exact targeted retirement:

1. Protected-load the target with eviction disabled.
2. Confirm it is resident.
3. Ask to retire the previous model immediately after the target is confirmed by the load response.
4. Retire it only when it has no coordinator request or local reservation.
5. If work arrived during the load, refuse retirement and leave both models resident.

## Network demand

The monitor polls `https://api.darkbloom.dev/v1/models/capacity` every 30 seconds. It displays enabled models only and preserves the last successful sample as stale when refresh fails. Samples older than two minutes or more than five seconds in the future are never actionable, and an older overlapping response cannot replace a newer accepted sample.

Each compact row shows:

- demand band derived from queued work and active requests per warm provider;
- active request count;
- queued request count when nonzero;
- warm-provider count.

Rows are ranked urgent, high, moderate, then low. These values describe network pressure, not expected revenue. Public customer pricing must not be presented as provider earnings.

## Manual warm flow

1. Require one exact downloaded, saved-enabled catalog model.
2. Require fresh daemon and loaded-model evidence.
3. Return immediately if the target is already resident.
4. In one-slot mode, wait for idle and retire the resident before loading. In two-slot mode, allow the old customer job to continue.
5. Apply the selected capacity and memory-headroom rules.
6. Require a private, current, loopback endpoint discovery record.
7. Send one bounded authenticated protected-load request for the exact model.
8. In two-slot mode, request exact idle retirement of the prior resident only after load succeeds.
9. Reconcile fresh local state even when either HTTP result is ambiguous and report success only when the target is resident.

The popup presents those transitions as compact progress text: preparing, loading into the active slot or staging in the free slot, retiring the previous idle model, and confirming model state.

The action never edits Enable or Preload, invokes Stop or Restart, uses `--all`, disables endpoint authentication, or targets a remote coordinator request.

The app's explicit provider Restart control re-runs the CLI's non-interactive Start path with every exact saved enabled model and `--local-endpoint`. The CLI's native restart preserves its old launchd arguments, so it cannot apply a newly saved model selection or add the protected endpoint to an older provider registration. The restart-required gate persists across monitor relaunches and clears only when a fresh provider snapshot proves that raw Enable, Preload, and configured slot-cap values plus immutable launch model IDs match the saved configuration. Live advertised models are intentionally not used for equality because coordinator prefetch can change that set legitimately.

## Cancellation, partial outcomes, and shutdown

Warm uses the same operation serialization for manual and automatic requests.
Cancellation before the protected load or retire request reaches the provider is
a no-op. Once a load or retire may have started, cancellation still runs fresh
telemetry and protected-control reconciliation; if that refresh cannot establish
the outcome, actionable state is invalidated rather than presenting cancellation
as proof that no residency changed. Success is reported only when fresh local
state confirms the target resident.

The one-slot cold-load gap is therefore an expected availability trade-off, not
an active-job interruption guarantee. Protected Warm never invokes Stop or
Restart and never unloads an active customer model. The user-facing Quit path
waits for monitor-owned telemetry shutdown. App termination cancels automatic
switching and the current control task and begins monitor shutdown; it does not
target the provider process, but an OS termination callback does not guarantee
that an in-flight provider request or reconciliation completes before exit.

## Automatic selection

Automatic demand-aware selection is opt-in and disabled by default. It reuses the exact manual warmup policy, requires three distinct high-or-urgent demand samples, and permits at most one launched mutation every 30 minutes. A preflight rejection does not consume the cooldown. The last-attempt timestamp persists across monitor relaunches and disabling/re-enabling automation does not clear it. It never acts on stale demand, unsaved or unapplied settings, an already-resident recommendation, an unsupported provider, mismatched live capacity, a full slot set, insufficient whole-system memory, or while another provider action is running. One-slot mode still waits for idle; two-slot mode may stage beside an active job and leaves that job's model resident if retirement is refused.

A recommendation may combine current network pressure, warm-provider scarcity, locally observed model throughput, and locally observed provider earnings history. It must be labeled an opportunity index, not projected dollars per hour, unless direct per-model residency time and payout evidence make that calculation defensible.

## Acceptance criteria

- Settings offers exactly one- and two-model capacity and writes `max_model_slots` without disturbing unrelated TOML bytes or security metadata.
- UI states plainly that the coordinator can use both slots.
- A configurable staging reserve is visible for two-model mode.
- Active customer work disables one-slot switching but may continue during a protected two-slot load.
- A full two-model capacity disables staging rather than selecting an eviction victim.
- Eviction-capable clients cannot execute a protected two-model stage.
- Network demand is current, compact, enabled-model-scoped, and honest about stale data.
- Automatic switching is default-off, requires three fresh consistent samples, and has a 30-minute attempt cooldown.
- Manual and automatic switching expose the same ordered load, retire, and reconciliation progress.
- A saved restart requirement survives monitor relaunch and cannot clear from command dispatch alone or from incomplete runtime evidence.
- All success states are confirmed from fresh local residency evidence.
- No active customer request is stopped, restarted, or unloaded by the monitor.
