# Winstripe

A retro taskbar for macOS, from Windows 95 to Windows 11, written in pure Swift. Inspired by
[RetroBar](https://github.com/dremin/RetroBar) for Windows. Everything is drawn in code, with no bitmap or copyrighted assets.

## Features

- **Taskbar** on any edge of the screen, with a Start button, a button for every running app, and a notification area with a clock.
- **Ten themes:** Winstripe 95, 98, ME, 2000, XP, Vista, 7, 8, 10 and 11, each with its own taskbar and Start menu.
- **Start menu** with your apps, search in the newer themes, *Run…*, and *Shut Down…*, which quits Winstripe only.
- **Pinning and ordering:** pin apps, drop `.app` files on the taskbar, and drag buttons to reorder them.
- **Window previews** when you hover over a task button, with live thumbnails on macOS 14 or later.
- **Quick Launch** for the items of any folder.
- **Properties window** with live preview, in English and 简体中文 among others. Open it by right-clicking the taskbar.
- **[User themes](docs/theme-format.md)** in JSON, which you can import and export. Also in [简体中文](docs/theme-format.zh-Hans.md).

## Install

Download the zip from [Releases](https://github.com/iBoysoft/Winstripe/releases) and move `Winstripe.app` to Applications. The app is not notarized, so if macOS blocks it, run:

```bash
xattr -dr com.apple.quarantine /Applications/Winstripe.app
```

Winstripe has no Dock icon or menu bar. To quit, use **Start → Shut Down…**.

It sits on top of the Dock, so each launch turns on auto-hide for a Dock at the bottom of the screen and restarts the Dock. A Dock on the left or right is left alone. The setting stays after you quit; to turn it off again:

```bash
defaults write com.apple.dock autohide -bool false; killall Dock
```

## Build

You need macOS 11 or later to run it, and Xcode 15.3 or later to build it. No certificate is needed.

```bash
git clone https://github.com/iBoysoft/Winstripe.git
```

```bash
cd Winstripe && ./scripts/bundle.sh
```

```bash
open dist/Winstripe.app
```

You can also open `Winstripe.xcodeproj` and run the `Winstripe` scheme. Xcode 27 no longer accepts the macOS 11.0 deployment target, so add `MACOSX_DEPLOYMENT_TARGET=12.0` when building with it.

Development notes, signing and debug flags are in [AGENTS.md](AGENTS.md).

## Permissions

Both are optional.

- **Accessibility:** per-window task buttons, restoring minimized windows, reliably raising windows, closing windows from menus, and badges. Without it, you get one button per app. Ad-hoc builds may need it granted again after each rebuild.
- **Screen Recording:** live preview thumbnails and window titles. Without it, previews are clickable title lists.

## Limitations

- It doesn't reserve screen space, so maximized windows can extend underneath it.
- Vista and 7 draw Aero glass in code, and Winstripe 11 uses macOS acrylic rather than Mica.
- Windows on other Spaces depend on how macOS handles activation and capture.

## License

MIT © 2026 iBoysoft. Windows is a trademark of Microsoft; this project is not affiliated with Microsoft.
