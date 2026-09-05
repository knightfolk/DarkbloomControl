# Darkbloom Control branding

The app uses an original geometric DC monogram, not the official provider logo.
Its app tile pairs mint and ivory lettering with a dark teal background. A
single-color variant remains legible and tintable in the menu bar and popup.

- App icon master: `assets/brand/dc-app-icon.svg`.
- Popup mark: `Sources/DarkbloomMonitor/Resources/dc-mark.svg`.
- Menu-bar mask: `Sources/DarkbloomMonitor/Resources/dc-menubar.svg`.
- Native icon: `Sources/DarkbloomMonitor/Resources/AppIcon.icns`.

The assets are editable project-native vectors. Regenerate the native icon by
running `swift tools/render_app_icon.swift assets/brand/dc-app-icon.svg` followed
by a new output directory argument, then run `iconutil -c icns` on the generated
`AppIcon.iconset`. The renderer refuses to overwrite an existing output directory.

Packaging produces `Darkbloom Control.app` with its display name and native icon.
The internal executable, bundle identifier, resource bundle, preference keys,
data locations, window restoration keys and single-instance lock retain their
previous names for compatibility. Rebranding does not alter the official CLI.

Qwen, Google and OpenAI marks identify models, not this app, and retain their
existing attribution. Historical official provider logo files are excluded
from the package. They are not used as the application's brand.

When replacing an installed monitor, follow `REVIEW_LAUNCH.md`; do not launch
by a generic name, change login items, or terminate the provider as part of a
cosmetic upgrade.
