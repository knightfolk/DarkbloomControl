# Store reconciliation cleanup report

## Scope

Changed only the assigned provider-control store, its focused tests, and this
report. No provider command, lifecycle action, configuration write, model
download/delete, relaunch, or live UI action was performed.

## Changes

- Lifecycle Start/Stop/Restart attempts now await the immediate monitor
  telemetry/status refresh and the controller snapshot refresh after success,
  nonzero failure, or timeout-shaped failure.
- The lifecycle operation remains active until reconciliation completes. If
  the controller refresh also fails, the original command error remains the
  user-facing outcome.
- Save now maps `ProviderControlError` through the same closed safe inventory
  catalog used by other controls. The catalog-unavailable,
  local-list-unavailable, and invalid/ambiguous saved-selection messages are
  covered exactly; arbitrary associated text remains generic.
- Delete's closed catalog now includes the exact provider-activity-unavailable
  and loaded-state-unavailable preflight messages. The focused table covers
  every fixed Delete blocker currently emitted by `ProviderControlService`.
- Test doubles can mutate the authoritative snapshot before returning a
  nonzero or timeout-shaped error, and reconciliation gates use a bounded wait
  so a regression fails instead of hanging.

## Verification

| Check | Result |
|---|---|
| Regression mutation check | Removing the store fix made the new Save and failed-lifecycle regressions fail for the intended missing mapping/reconciliation behavior |
| `swift test --filter ProviderControlStoreTests` | Pass: 30 tests in 1 suite |
| `swift test` | Pass: 258 tests in 23 suites |
| `swift build -c release` | Pass |
| `git diff --check` | Silent/pass |
| Assigned diff inspection | Only the requested store behavior, exact safe-message catalogs, focused fake capabilities, and regressions are present |

## Commit

Committed as `fix: reconcile failed provider controls`. The unrelated
untracked `Sources/DarkbloomMonitor/Resources/DarkbloomLogo.svg` and concurrent
model-manager/lifecycle-presentation edits remain outside this scoped commit.

## Fix round 1 — cancellation boundary

The review found that the failed-command reconciliation path also caught
`CancellationError`, and that cancellation arriving during either awaited
reconciliation stage could still publish a refreshed controller snapshot.

The store now rethrows command cancellation before reconciliation. It checks
for cancellation immediately after the telemetry/status refresh and again
after the controller refresh before accepting that snapshot. A cancellation
during reconciliation is also propagated instead of being replaced by an
earlier ordinary command failure. Non-cancellation command failures retain the
original reconciliation and error-precedence behavior.

Three focused regressions cover controller-thrown cancellation, caller
cancellation while telemetry reconciliation is gated, and caller cancellation
while controller reconciliation is gated. Each proves a clean return to idle,
no user-facing error, and no stale snapshot publication; the first two also
prove that later reconciliation stages are not called.

Fix-round verification:

- RED: all three new cancellation tests failed against the reviewed code for
  the intended reconciliation/publication defects.
- `swift test --filter ProviderControlStoreTests`: passed, 33 tests in 1 suite.
- `swift test`: passed, 261 tests in 23 suites.
- `swift build -c release`: passed.
- `git diff --check`: silent/pass.

No live provider command, lifecycle action, configuration write, model
mutation, relaunch, or UI action was performed. The unrelated untracked logo
remains untouched.
