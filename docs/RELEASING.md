# Release signing and notarization

Build and test the exact commit to release. Package with `tools/package_app.py`, using absolute executable/resource/output paths and the version from `VERSION`. The downloadable build targets Apple Silicon and macOS 14 or newer.

1. First sign embedded Sparkle components inside-out as described below. Then sign the assembled app using a valid **Developer ID Application** identity, hardened runtime, and secure timestamp: `codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"`.
2. Verify with `codesign --verify --deep --strict --verbose=2 "$APP"` and inspect `codesign -d --verbose=4 "$APP"`.
3. Create a submission ZIP with `ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_ZIP"`.
4. Submit using a previously configured Keychain profile: `xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --output-format json`. Wait for Apple to return **Accepted**; inspect the notarization log if rejected.
5. Run `xcrun stapler staple "$APP"`, `xcrun stapler validate "$APP"`, and `spctl --assess --type execute --verbose=4 "$APP"`. Gatekeeper must accept the exact app as a notarized Developer ID application.
6. Create the distribution ZIP **after** stapling. Generate SHA-256 checksums and an artifact manifest from the final bytes; the unsigned local-review manifest is not distribution evidence.
7. Tag the verified source commit, push it, and upload the ZIP/checksums/release manifest. Verify GitHub's uploaded asset digests match local files before publishing.

Signing and notarization do not disable Gatekeeper. They provide the distribution signature and Apple ticket it checks. Standard first-launch and privacy-permission prompts can still appear. Do not strip quarantine attributes or disable Gatekeeper as a release step.

Keep signing keys, passwords, and API keys out of the repository and release assets. Notarization profiles remain in Keychain.

## Control app updates (Sparkle)

Control uses Sparkle 2.9.6 for signed app updates. Provider CLI checks are read-only;
Control never installs or enables updates to the CLI. Automatic checking and
installation for Control are separate user opt-ins. Do not enable either by
rewriting user defaults during packaging or release.

The release feed and **public** Ed25519 key are in `docs/updates/config.json`.
The private signing key is stored in the local login Keychain under Sparkle
account `dev.darkbloom.monitor`; never export it into this repository. A future
release signing machine needs an authorized secure transfer of that key.

Package with the existing arguments plus:

- `--sparkle-framework /absolute/checkout/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`
- `--update-feed-url` set to `feed_url` from the configuration.
- `--update-public-key` set to `public_ed_key` from the configuration.

Embed Sparkle even for local review builds because the executable links to it.
Omit both update configuration arguments to disable app updating in an isolated
review build. Verify `otool -L` resolves Sparkle through the app's Frameworks
folder rather than a developer build path.

Sign Sparkle's nested executable components inside-out with the release Developer
ID, hardened runtime, and timestamp before signing the containing app. Follow
Sparkle's signing guidance at https://sparkle-project.org/documentation/ rather
than using `codesign --deep` as a signing shortcut. Notarize and staple the complete
app, then create the final distribution ZIP before signing update metadata.

Generate the appcast from **only final, notarized distribution ZIPs** using the
pinned Sparkle `bin/generate_appcast` tool with `--account dev.darkbloom.monitor`
and a download URL prefix matching the intended GitHub release asset location.
Review the generated item: increasing `sparkle:version` (build number), displayed
version, arm64 compatibility, minimum macOS 14, exact final ZIP length, HTTPS
asset URL, and `sparkle:edSignature`. Publish that item in `docs/updates/appcast.xml`
only after the matching authorized GitHub release assets exist and their digests
are verified. Preserve older valid items where needed.

v1.1.0 is the first updater-enabled release; v1.0.0 users must download it
manually. Before subsequent releases, test a signed older updater-enabled app against the final signed newer
ZIP, including installation/relaunch, automatic installation on quit, signature
rejection, and preservation of app preferences. Keep the provider running throughout.

When SwiftPM uses the Xcode build backend, resource files are under the generated
`.bundle/Contents/Resources` directory. Pass that directory as `--resources`;
with the native SwiftPM backend, pass the flat generated `.bundle` directory.
