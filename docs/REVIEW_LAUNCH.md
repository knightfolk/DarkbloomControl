# Reviewing the current monitor without reviving an old build

The monitor is a menu-bar-only SwiftPM app. A successful background launch need
not show a window. App-name lookup can resolve a registered, obsolete test bundle;
never use it to select the review build. Never pass the raw executable to `open`,
which can create a Terminal window. Do not use Terminal UI for this procedure.

## Before replacing anything

1. Check the checkout and preserve its dirty changes. Build and test the current
   working tree, not an assumed clean main or an existing visual-evidence bundle.
2. Resolve `.build/release` to its architecture-specific directory. Record the
   executable's absolute path, hash, modification time and inode.
3. Inspect live process commands and the owner of the user-scoped
   `Library/Application Support/Darkbloom Monitor/darkbloom-monitor.lock` file.
   Metadata in the file is diagnostic only; a live kernel-held descriptor is
   authority. Do not delete the lock to force another instance.
4. Compare the executable mapping (`lsof` text descriptors) with the current file.
   A matching path is insufficient after a rebuild: the running process can map
   the previous inode. Report any incomplete process-inspection warnings.
5. Establish whether the monitor contains an unsaved provider draft. Save or
   discard only with user direction. If native inspection cannot establish this,
   ask and pause the replacement; a hidden window is not proof of no draft.

## Scoped background replacement

After draft safety and replacement authority are established, remove only the
known review launchd job `com.darkbloom.monitor.codex-review`. Verify its exact
monitor PID exits. If an obsolete fixture is running separately, identify its
full executable path and task ownership before stopping that individual process.
Never broadly kill Darkbloom processes: the CLI/provider is a separate service
and must keep customer jobs running during a monitor-only update.

Submit the resolved current release executable directly using `launchctl submit`
under the review label, with output redirected to the existing review log files
in `/tmp`. Do not resolve by app name or select `.build/visual-evidence` as a
fallback. This is a manual review workflow, not an automatic updater.

## Proof after launch

- Exactly one expected monitor process and one live lock owner.
- Its executable mapping matches the built artifact, not merely the same path.
- Startup error log has no new crash; absence of a foreground window is normal.
- Provider PID/process identity and configuration were not changed.
- The actual popup and unified dashboard/settings window still require visible
  review. Process, test and build success alone do not establish UI correctness.

Do not delete obsolete artifacts, register/unregister bundles, change login items,
or terminate unrelated Terminal windows as an implicit part of this procedure.
Those require separately resolved targets and appropriate user authority.
