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
