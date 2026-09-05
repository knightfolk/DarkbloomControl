# Local App Packaging Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline; no subagent work is authorized for this task. Preserve the existing dirty main checkout. Use an isolated packaging worktree for implementation, then review focused changes before integrating them into the ongoing checkout.

**Goal:** Assemble a relocatable local-review app bundle and exact artifact manifest without launching or publishing it.

**Architecture:** Standard Contents/MacOS and Contents/Resources layout. A lazy resource resolver checks packaged resources before the SwiftPM development fallback. A standard-library packaging tool copies only the specified executable and resource bundle into a new output directory and records hashes.

**Tech Stack:** Swift 6, macOS 14+, Python 3 standard library, plistlib, SHA-256.

**Spec:** docs/MEGA_APP_INTEGRATION_PLAN.md Phase 8 and docs/REVIEW_LAUNCH.md. This is a packaging subtask, not full Phase 8 completion.

## Global Constraints

- No app launch, registration, restart, code-signing identity use, notarization, installation, publication or push.
- No provider configuration, customer job or user preference changes.
- Preserve the dirty checkout and obsolete artifacts; refuse existing output targets.
- Never infer source cleanliness or release approval from a version string.
- Keep the bundle identifier `dev.darkbloom.monitor`; do not reuse `dev.darkbloom.monitor.visual-verification` or the export-fixture identifier.
- Output is explicitly local-review/unnotarized. The existing tag v0.1.0-alpha.1 is not proof that a newly assembled dirty artifact is that release.

## Task 1: Relocatable resource lookup

Files: create Sources/DarkbloomMonitor/AppResources.swift and Tests/DarkbloomTelemetryTests/AppResourcesTests.swift; modify only the asset lookup in MenuBarLabel.swift.

Interface: `AppResources.url(named:extension:appBundle:developmentBundle:) -> URL?`. `appBundle` defaults to Bundle.main; `developmentBundle` is a lazy closure returning Bundle.module. Resolve DarkbloomMonitor_DarkbloomMonitor.bundle inside appBundle.resourceURL first. Do not evaluate the development closure if the packaged resource exists.

- [ ] Create a temporary synthetic app bundle with Contents/Info.plist and Contents/Resources/DarkbloomMonitor_DarkbloomMonitor.bundle. Place a test SVG inside the resource bundle using the same structure as the actual SwiftPM output.
- [ ] Write assertions that the resolved URL is inside the temporary app, that the development fallback is not called, that development lookup works without a packaged resource, and that an absent asset returns nil.
- [ ] Run `swift test --filter AppResourcesTests` and verify the missing resolver fails before implementation.
- [ ] Implement the packaged-first resolver and replace the single Bundle.module.url call in DarkbloomLogoAsset.load. Do not alter logo sizing, color or status-item layout.
- [ ] Run the focused tests and existing menu/logo tests. Verify packaged resource lookup without using the original build-directory fallback.

## Task 2: Non-overwriting bundle assembler

Files: create tools/package_app.py and Tests/Packaging/test_package_app.py.

CLI contract:

```text
python3 tools/package_app.py --executable ABSOLUTE_EXECUTABLE \
  --resources ABSOLUTE_SWIFTPM_BUNDLE --output NEW_OUTPUT_DIRECTORY \
  --version 0.1.0 --build-number 1
```

Outputs inside the new directory: DarkbloomMonitor.app and artifact-manifest.json. The manifest is schema version 1 and explicitly says local-review, not distribution-signed/notarized. Record SHA-256 and byte size for every regular app file using sorted relative paths; do not include absolute user paths, credentials, timestamps pretending to be source provenance, or a clean-git claim. Caller-supplied version/build values are metadata only.

- [ ] Test with temporary executable/resource fixtures: exact byte preservation; executable mode; valid Info.plist; LSUIElement true; macOS floor 14.0; stable bundle identifier; expected standard resource location; matching manifest hashes; rejection of existing output, missing/nonregular inputs, resource symlinks and invalid version/build values. The prior output must survive a refused overwrite.
- [ ] Run `python3 -m unittest discover -s Tests/Packaging -v` and verify failure before implementing the tool.
- [ ] Implement argument validation before creating output, exclusive output-directory creation, safe copies and deterministic JSON/plist content. Do not run shell commands or implicitly build/launch anything. On failure leave an explicitly incomplete new output for diagnosis; never remove a caller's directory.
- [ ] Repeat the tests and run `python3 tools/package_app.py --help`.

## Task 3: Real local artifact proof

- [ ] Integrate only the reviewed packaging/resource changes into the ongoing checkout, preserving all other edits. Run `swift test`, `swift build -c release` and packaging unit tests.
- [ ] Resolve the architecture-specific release executable and resource bundle. Assemble into a new ignored `.build` review output, never overwrite the old visual-evidence app.
- [ ] Parse the packaged Info.plist and recompute every manifest hash. Verify executable/resources are copied bytes, not symlinks into the development tree. Verify both SVGs decode from the packaged resource bundle.
- [ ] Record artifact path/hash and the source revision plus dirty-state caveat separately in the progress audit. Do not call the manifest an SBOM or reproducible-build proof.
- [ ] Add the assembly command and limitations to README. Stop at the unsigned/local-review artifact checkpoint. Live relaunch remains pending draft safety; signing, CI publication, notarization, upgrade/Gatekeeper and SBOM remain open.

## Self-review

This plan addresses assembly, resource relocation and artifact identity only. It intentionally leaves app launch, old-process activation, live UI, CI publication, distribution signatures and migration proof to their existing gates. Resource lookup and packaging tests run without touching the user's running app, provider, settings or model cache.
