# Native export fixture

This opt-in app hosts the production export view with a fixed synthetic snapshot.
It does not start a provider or read credentials/log files. It is not shipped.
The Swift test runner renders the view but does not expose its windows reliably
to external accessibility automation, so native save-dialog proof uses this app.

From the repository root, after `swift test` has built debug telemetry objects:

```sh
mkdir -p .build/native-export-proof/DarkbloomExportFixture.app/Contents/MacOS
cp Tests/NativeUI/Info.plist .build/native-export-proof/DarkbloomExportFixture.app/Contents/Info.plist
swiftc -target arm64-apple-macosx14.0 -parse-as-library -I .build/arm64-apple-macosx/debug/Modules Tests/NativeUI/LogExportFixture.swift Sources/DarkbloomMonitor/Dashboard/LogExportPreviewView.swift Sources/DarkbloomMonitor/Dashboard/LogsView.swift Sources/DarkbloomMonitor/Components/EventRow.swift .build/arm64-apple-macosx/debug/DarkbloomTelemetry.build/*.o -lsqlite3 -o .build/native-export-proof/DarkbloomExportFixture.app/Contents/MacOS/DarkbloomExportFixture
open -g .build/native-export-proof/DarkbloomExportFixture.app
```

Keep the explicit deployment target: this host's standalone compiler otherwise
produced a macOS 28 minimum on a macOS 27 host. `open -g` targets the app bundle,
never a raw executable (which can open Terminal).

Check Save is disabled before acknowledgement. Acknowledge, open the native
dialog, cancel and verify no output. Open it again and use **Go to Folder** to
select a newly created temporary directory before exporting. Do not put an
absolute path into the filename field: macOS may turn slashes into colons and
save in its remembered directory. Compare the resulting UTF-8 bytes with the
accessibility text of the JSON preview. Test replacement only against that
synthetic file: cancel should preserve a sentinel edit; confirm should restore
the exact preview bytes. Quit the fixture when finished.

The native proof performed on 2026-09-04 verified the review gate, cancellation,
546-byte exact output, overwrite cancellation and confirmed replacement. Failure
injection and the parent Logs filter-to-preview route remain separate checks.

For the parent route, launch the closed fixture with:

```sh
open -g .build/native-export-proof/DarkbloomExportFixture.app --args --logs-route
```

The two synthetic events have different sources/severities. Native selection of
Source = Legacy must leave one row and produce one legacy event in Preview export,
with `source_status = last-known` and the original source timestamp. Adding
Severity = Error must leave no matches and disable Preview export. These picker
checks passed on 2026-09-04 without saving a file. Direct accessibility assignment
to the text field did not update its SwiftUI binding and is not text-entry proof.
Do not issue keyboard events unless the fixture is confirmed foreground; prefer
targeted accessibility actions. Actual keyboard search and failure injection
remain separate checks.

## CLI 0.9.7 settings fixture

`CLI097Fixture.swift` hosts the production extras settings and slot explanation with an in-memory actor. It reads no provider files, starts no collectors, and its Save/Enable/Disable actions only alter synthetic data. It is not shipped.

With the current Xcode SwiftPM build layout, after `swift test`, compile it with:

```sh
swiftc -target arm64-apple-macosx14.0 -parse-as-library -I .build/out/Products/Debug Tests/NativeUI/CLI097Fixture.swift Sources/DarkbloomMonitor/ProviderExtrasStore.swift Sources/DarkbloomMonitor/ProviderExtrasViews.swift Sources/DarkbloomMonitor/Components/SlotCard.swift .build/out/Products/Debug/libDarkbloomTelemetry.a -lsqlite3 -o /absolute/path/to/CLI097Fixture.app/Contents/MacOS/CLI097Fixture
```

Supply a normal local app Info.plist with executable `CLI097Fixture` and identifier `dev.darkbloom.cli097fixture`. Native review on September 21 verified the corrected single-line idle field, typed 60-minute draft, Save becoming enabled then disabled, reread summary and restart-required feedback, MTP automatic-to-enabled state, and unknown feature read-only presentation. All changes stayed in the synthetic actor. This proves those view interactions, not live provider setting writes or macOS removable-volume access.

## Models fixture

`ModelsFixture.swift` hosts the production model editor with an in-memory controller. It never reads provider files. Its Save action changes only synthetic values; Finish simulated work changes only fake activity. Compile against the debug telemetry library with ModelManagerView and ProviderControlStore. Use a separate app identifier and keep the synthetic banner visible.

Native review verified populated cards, Capacity selection, unsaved changes, refresh preserving the draft, and synthetic save. This is interaction proof, separate from real CLI/configuration integration tests and live drive access.
