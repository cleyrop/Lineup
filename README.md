# Lineup

**A focused, list-only macOS window switcher.**

Lineup is a Cleyrop-maintained fork of
[DevSwitcher2](https://github.com/vaspike/DevSwitcher2), trimmed to a single,
fast list view and made English-only. It lives in the menu bar and gives you two
switchers:

- **Same-app window switcher** (default `⌘ + \``) — cycle the windows of the
  current app, with smart project-name extraction from window titles.
- **App switcher** (default `⌘ + Tab`) — an enhanced Command-Tab across all apps.

## What's different from DevSwitcher2

- **List-only.** The circular/radial layout, outer-ring styles and floating-item
  effects are removed — one clean list, less to configure, less to maintain.
- **English-only.** The Chinese localization and language picker are gone.
- **Arrow-key navigation** (issue #6) — while the switcher is open, use **↑ / ↓**
  to move through the list and **Enter** to activate, in addition to holding the
  modifier and the number keys.
- **Windows from all Spaces** (issue #7) — the same-app switcher lists the app's
  windows from every Space / desktop, not just the current one. Toggle it under
  *Preferences → Advanced → Show Windows From All Spaces* (on by default).

## Build

Requires Xcode (macOS 12+ deployment target).

```sh
./scripts/build-macos.sh        # unsigned Lineup.app for local use
```

Or open `Lineup/Lineup.xcodeproj` in Xcode and run the **Lineup** scheme.

For signed/notarized release builds and the CI pipeline, see [SIGNING.md](SIGNING.md).

## Permissions

Lineup needs **Accessibility** permission (System Settings → Privacy & Security →
Accessibility) to read and switch application windows.

## License

MIT — see [LICENSE](LICENSE). Originally created by River (DevSwitcher2);
fork maintained by Cleyrop.
