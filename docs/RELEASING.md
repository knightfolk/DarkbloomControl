# Release signing and notarization

Build and test the exact commit to release. Package with `tools/package_app.py`, using absolute executable/resource/output paths and the version from `VERSION`. The downloadable build targets Apple Silicon and macOS 14 or newer.

1. Sign the assembled app using a valid **Developer ID Application** identity, hardened runtime, and secure timestamp: `codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"`.
2. Verify with `codesign --verify --deep --strict --verbose=2 "$APP"` and inspect `codesign -d --verbose=4 "$APP"`.
3. Create a submission ZIP with `ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_ZIP"`.
4. Submit using a previously configured Keychain profile: `xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --output-format json`. Wait for Apple to return **Accepted**; inspect the notarization log if rejected.
5. Run `xcrun stapler staple "$APP"`, `xcrun stapler validate "$APP"`, and `spctl --assess --type execute --verbose=4 "$APP"`. Gatekeeper must accept the exact app as a notarized Developer ID application.
6. Create the distribution ZIP **after** stapling. Generate SHA-256 checksums and an artifact manifest from the final bytes; the unsigned local-review manifest is not distribution evidence.
7. Tag the verified source commit, push it, and upload the ZIP/checksums/release manifest. Verify GitHub's uploaded asset digests match local files before publishing.

Signing and notarization do not disable Gatekeeper. They provide the distribution signature and Apple ticket it checks. Standard first-launch and privacy-permission prompts can still appear. Do not strip quarantine attributes or disable Gatekeeper as a release step.

Keep signing keys, passwords, and API keys out of the repository and release assets. Notarization profiles remain in Keychain.
