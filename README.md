# Winstripe

A retro 95-style taskbar for macOS, written in pure Swift (AppKit, with a SwiftUI Properties window).
Inspired by [RetroBar](https://github.com/dremin/RetroBar) for Windows.

Winstripe floats a classic silver, 3D-beveled taskbar along an edge of your main display: a **Start**
button with a vector-drawn four-color waving flag, a Start menu, a button for every running app, and a
sunken notification area with a clock. Everything is drawn in code — no bitmap or copyrighted assets.

## Features

- **Taskbar** — borderless, always-on-top panel (status-bar level, joins all Spaces) at the bottom, top,
  left or right edge. Left/right use a vertical layout. It only floats; nothing in the system is reserved.
- **Themes** — Winstripe 95 (default), Winstripe 98, Winstripe ME, Winstripe 2000, Winstripe XP, Winstripe Vista and Winstripe 7,
  Winstripe 8 with a translucent Metro taskbar and full-screen tile Start screen, Winstripe 10 with a square
  dark taskbar, search box, three-column Start menu and live-tile-style pinned apps, and Winstripe 11 with
  appearance-aware native acrylic, a 48pt taskbar, centered icon buttons, running
  indicators, and a two-line clock. Winstripe 11 has a **Taskbar alignment: Center / Left** preference,
  uses the system font with smoothing, and supports a compact vertical layout on the left/right edges.
- **Winstripe Vista / Winstripe 7 Aero** — Vista uses a 30pt smoky black glass taskbar, a 54pt overflowing
  Start orb and labelled task buttons. Winstripe 7 uses a 40pt blue glass superbar, a blue Start orb,
  icon buttons with colour hover tracking, a two-line clock and a glass Show Desktop strip. Its
  **Taskbar buttons** preference supports Always combine, Combine when full, and Never combine. With
  Accessibility, standard windows use stable per-window buttons with their titles and app icons. Both have two-pane Start
  menus with live search, Enter to launch, a scrolling **All Programs / Back** view, folder and
  settings links, and shutdown controls. Both support all four taskbar edges. The old saved
  legacy combined Vista/7 theme setting automatically migrates to Winstripe 7; Winstripe 95 remains the default.
- **Winstripe 11 Start menu** — rounded acrylic flyout with app search, a scrolling Pinned grid populated
  from `/Applications` (plus system/user apps), an alphabetical All apps list, and a user/power bar.
  The power menu offers Run, Taskbar Properties and Shut Down (quits Winstripe only).
- **Winstripe 8 Start screen** — horizontally scrolling column groups of mixed-size Metro tiles with
  real app icons, an alphabetical Apps view, and typing to search. The user/power bar offers Run,
  Settings (Taskbar Properties) and Shut Down (quits Winstripe only). Properties offers six persisted
  Start screen colors, also used to tint the taskbar. Esc, the Start button, or launching an app closes
  the screen. Left/right taskbars stack buttons and keep a compact tray at the bottom.
- **Start menu** with the vertical side banner:
  - *Programs* — apps from `/Applications` (sub-folders become submenus), plus *Accessories*
    (`/System/Applications`) and `~/Applications`; click to launch.
  - *Documents* — opens `~/Documents`.
  - *Settings → Taskbar Properties…* — opens the Properties window.
  - *Run…* — opens an app name (`Safari`), bundle id, path (`~/Downloads`) or URL.
  - *Shut Down…* — asks for confirmation, then quits **Winstripe only**.
- **Task buttons** — one per regular running app (icon + name). The frontmost app is drawn sunken with the
  classic dither. Click to activate; click the active app to hide it. Updates on launch/terminate/activate/
  hide/unhide notifications.
- **Context menus** — right-click or Ctrl-click task buttons, the Start button, or empty taskbar space for
  window activation and closing, pinning, quitting, Finder access, taskbar tools, and Properties. Menus
  are localized in English and 简体中文; Accessibility-dependent commands are disabled without permission.
- **Notification area** — clock (updates every minute; tooltip shows the date), optional input-language
  indicator (current keyboard layout via TIS), optional Show Desktop button (hides / restores apps),
  optional collapse chevron.
- **Quick Launch** — small launch buttons for the items of any folder (*Select location…*).
- **Pinning and ordering** — pinned apps remain available when closed. Winstripe 7/10/11 place pins
  in taskbar order, merging combined running apps into their slots or placing window buttons immediately
  after their pins. Winstripe 95/98/ME/2000/XP/Vista/8 put pins before folder items in Quick Launch, even when
  folder Quick Launch is off. Right-click taskbar or Start app items to pin/unpin; drop Finder `.app`
  files onto the taskbar to insert pins. Unlock the taskbar to drag buttons along its axis to reorder
  pins or running apps; dragging off the bar keeps the pin. Winstripe 8/10/11 have a separate ordered
  Start pin list; an empty list restores the automatic selection.
- **Hover window previews** — enable *Show window previews* to open a themed, non-activating popup
  after 400ms over a task button. Combined buttons list all the app's windows; per-window buttons
  show their own window. Click a preview to raise it, or its hover close button to close it through
  Accessibility. The popup stays open while crossing into it and closes 300ms after leaving;
  outside clicks, menus and drags dismiss it. Large groups scroll to fit the screen.
  Winstripe 95/98/ME/2000/XP use title lists; Vista/7/8/10/11 show live, aspect-preserving thumbnails on
  macOS 14+, with app icons for minimized windows. Captures refresh only while open, with a
  two-second cache.
- **Properties** (right-click the taskbar → *Properties*, or Start → Settings) with *Taskbar* and *Advanced*
  tabs modelled on RetroBar: separate taskbar-appearance and notification-area preview strips, live preview,
  Language (English / 简体中文), Theme, Location, font smoothing,
  lock (unlock to drag the bar to another edge), auto-hide, badges, Quick Launch, window previews,
  notification-area options, debug logging, reset to defaults. **OK / Cancel / Apply**; all settings
  persist in `UserDefaults` (`com.iboysoft.winstripe`) and apply live.

## User themes

Winstripe loads user themes from `~/Library/Application Support/Winstripe/Themes/`. A theme can be a
`Name.rdtheme` folder containing `theme.json` and an optional `assets/` directory, or a loose `.json`
file. The Properties Theme menu separates built-in themes from **My themes**. Use **Import…**,
**Export…**, or **Open Themes Folder** to manage them; imported archives are validated before anything
is copied. See [docs/theme-format.md](docs/theme-format.md) for the schema, inheritance, assets,
validation limits, hot reload, and command-line examples. The same reference is available in
[简体中文](docs/theme-format.zh-Hans.md).

## Web App Collections

The Start menus can list web apps and Mac apps next to the Mac's apps, with first-level entries and folders. This repository has no source
of entries, so a build lists none. See [docs/web-app-collections.md](docs/web-app-collections.md).

## Requirements

- macOS 11.0 or later (Apple Silicon or Intel)
- Xcode 14.3 or later, or a compatible Swift toolchain. A build from Xcode 14 has no window thumbnails in taskbar previews, which need the macOS 14 SDK.

## Build & run

```bash
git clone git@github.com:iBoysoft/Winstripe.git
cd Winstripe
swift build -c release
.build/release/Winstripe          # run the bare binary (Ctrl-C to quit)
```

### Bundle as an app

```bash
./scripts/bundle.sh               # -> dist/Winstripe.app (LSUIElement, ad-hoc signed)
open dist/Winstripe.app
cp -R dist/Winstripe.app /Applications/   # optional
```

Direct-download builds include Sparkle and use the repository root as the update source:
`https://github.com/iBoysoft/Winstripe`. A minimal RSS appcast example is included at
[appcast.xml](appcast.xml); publish that file at the configured source
and replace the sample enclosure with each signed release archive.

### Open in Xcode

Open `Winstripe.xcodeproj` in Xcode and run the shared `Winstripe` scheme. The project uses the same
`Sources/Winstripe` sources and bundles `Themes/`, the asset catalog, and all localized resources.
Hardened Runtime is enabled for Debug and Release. By default every configuration is signed with
**Sign to Run Locally** (ad-hoc), so no Apple team or certificate is needed; see
[Building locally without a certificate](#building-locally-without-a-certificate).

### Building locally without a certificate

Winstripe builds and runs on your Mac with no Apple Developer account, certificate, team, or
provisioning profile. `Xcode/Signing.xcconfig` sets every configuration to ad-hoc
**Sign to Run Locally** signing (`CODE_SIGN_IDENTITY = -`); the entitlements file is still applied.

```bash
# Debug or Release
xcodebuild -project Winstripe.xcodeproj -scheme Winstripe -configuration Release build
# Hand-built bundle (after `swift build`); scripts/sign.sh signs it ad-hoc, inside-out
./scripts/bundle.sh
```

Check the result with `codesign --verify --deep --strict path/to/Winstripe.app` and
`codesign -dvv path/to/Winstripe.app` (`Signature=adhoc`). Ad-hoc builds cannot be notarized,
and macOS may ask you to re-grant Accessibility after each rebuild.

Xcode 27 no longer accepts the project's macOS 11.0 deployment target (minimum 12.0). To build a
local test copy with it, add `MACOSX_DEPLOYMENT_TARGET=12.0` to the `xcodebuild` commands.

`./scripts/bundle.sh` packages a hand-built local/dev `.app` after `swift build`. Its output is signed
ad-hoc or with the self-signed "Winstripe Local" identity, so it is not a notarizable shipping path.
Notarized Developer ID builds come from an Xcode Archive exported with Developer ID distribution
(signing set up in `Xcode/Signing.local.xcconfig`, below), not from `bundle.sh` alone.

The **Release** workflow in GitHub Actions publishes a build by hand: open **Actions → Release → Run workflow**,
enter a version such as `1.2.0`, and it attaches `Winstripe-1.2.0.zip` to a new `v1.2.0` release. It runs
`./scripts/package-release.sh`, which builds with Xcode and zips the app. The app is signed ad-hoc with no certificate and
is not notarized, so people who download it may have to clear the quarantine flag. Sparkle's `appcast.xml` is not updated.

To opt into real signing:

- **Xcode builds and archives:** copy `Xcode/Signing.local.xcconfig.example` to
  `Xcode/Signing.local.xcconfig` (git-ignored) and set your `DEVELOPMENT_TEAM`. Archive, then export
  with Developer ID distribution.

  > **Warning:** don't pick a Team or switch Signing to Automatic in the target's **Signing &
  > Capabilities** tab. Xcode writes `CODE_SIGN_*` / `DEVELOPMENT_TEAM` into `project.pbxproj`; those
  > target-level settings override `Xcode/Signing.xcconfig` and put your team ID back into the repo.
  > Edit only `Xcode/Signing.local.xcconfig`, and revert those `project.pbxproj` lines if the UI
  > rewrote them.
- **`scripts/sign.sh` / `bundle.sh`:** set `WINSTRIPE_SIGN_IDENTITY` to a keychain identity, or run
  `./scripts/setup-signing.sh` once for a stable self-signed "Winstripe Local" identity (keeps the
  Accessibility grant across rebuilds). Identities match by prefix, so `Developer ID Application` finds
  `Developer ID Application: Org Name (TEAMID)`. If a default identity isn't in your keychain, the script
  falls back to ad-hoc signing; an identity you set via `WINSTRIPE_SIGN_IDENTITY` must exist, or the
  script fails (`WINSTRIPE_SIGN_IDENTITY=-` forces ad-hoc). This output is ad-hoc or self-signed and
  cannot be notarized; for notarized distribution, use the Xcode archive and export above.

`LSUIElement` is set, so Winstripe has no Dock icon or menu bar. Quit it via **Start → Shut Down…**
(or `pkill Winstripe`). Test switches: `open dist/Winstripe.app --args --show-properties` and
`--open-start-menu`; `--activate-bundle <bundleID>` activates a running app through the taskbar
handler and writes diagnostics to `/tmp/winstripe-activate.log`. `--list-windows` writes the
Accessibility window model to `/tmp/winstripe-windows.log`; `--activate-window <pid> <title-substring>`
runs the per-window activation path.
`--pin <bundleID>` / `--unpin <bundleID>` change taskbar pins after the live app starts;
`--list-buttons` reports the current pinned/running/window button order. All three write the resulting
pin list and button order to `/tmp/winstripe-pins.log` and stdout. Multiple pin/unpin flags are processed
in argument order.
`--preview <pid>` opens that app's first visible task button preview after 1.5 seconds, keeps it
open for five seconds, and logs window IDs and capture results to `/tmp/winstripe-preview.log`
and stdout. This live debug flag opens the popup even when the preview setting is off.
`--dump-menus` builds representative combined-task, per-window-task, empty-taskbar, and Start-button
menus in English and 简体中文 and prints their titles, checkmarks, and enabled states without opening
the live app.
Use `.build/release/Winstripe --snapshot-dir /tmp/rd-win11` to generate offscreen previews for all themes,
including `taskbar-win10.png`, `startmenu-win10.png`, `taskbar-win11.png`, and `startmenu-win11.png`.
Pin fixtures are `taskbar-pinned-win7.png`, `taskbar-pinned-win10.png`, and `taskbar-pinned-win95.png`,
with Calculator and Maps closed, Safari pinned and running, and Notes running.
Winstripe 8 snapshots include `taskbar-win8.png` (1000x40), `taskbar-win8-left.png` (128x800),
`startscreen-win8.png`, `startscreen-win8-apps.png`, `startscreen-win8-search.png` (search "Ca"),
all three at 1440x900, and `preview-win8-left.png`. The renderer exits when complete. Offscreen
acrylic uses an appearance-aware solid fallback because there is no desktop behind it to blur.
Vista snapshots include `taskbar-vista.png` (1000x56, including wallpaper above the 30pt bar and the
overflowing orb), `taskbar-vista-left.png` (160x800), `startmenu-vista.png` and
`startmenu-vista-allapps.png`. Winstripe 7 includes `taskbar-win7.png` (1000x40),
`taskbar-win7-left.png` (62x800), `taskbar-win7-labels.png`, `startmenu-win7.png` and
`startmenu-win7-allapps.png`. Menu crops include the taskbar and orb; Vista uses a dark teal wallpaper
and Winstripe 7 uses blue. Properties previews are also written as `preview-WindowsVista.png` and
`preview-Windows7.png`; the Properties fixtures include `properties-taskbar-win95.png`,
`properties-taskbar-winxp.png`, `properties-taskbar-win7.png`, `properties-taskbar-win10.png`,
and `properties-taskbar-win11.png`. Per-window fixtures are written as `taskbar-perwindow-win95.png`,
`taskbar-perwindow-win7.png`, and `taskbar-perwindow-win10.png`. `--print-menu-geometry` includes
Vista and Winstripe 7 on every edge.
Hover fixtures include `preview-popup-win95.png`, `preview-popup-vista.png`,
`preview-popup-win7.png`, `preview-popup-win10.png`, and `preview-popup-win11.png`.
Each shows two windows above a short taskbar strip, with one hover close button visible;
thumbnails are drawn synthetic window chrome and never capture the desktop.

## Recommended (optional) macOS tweak

Winstripe does not modify any system settings. It sits on top of the Dock, so you may want to make the
Dock auto-hide yourself:

```bash
defaults write com.apple.dock autohide -bool true; killall Dock
# undo: defaults write com.apple.dock autohide -bool false; killall Dock
```

## Permissions

- **Accessibility** (optional) — used for *Show badges*, per-window task buttons, and restoring minimized
  windows / reliably raising taskbar apps, and closing windows from context menus. Grant it in System
  Settings → Privacy & Security → Accessibility.
- Pinning, launching pins, and drag ordering require no additional permissions. Window behavior still
  depends on Accessibility as described above.
- **Screen Recording** (optional) — needed for live preview thumbnails and CG window titles.
  The first hover requesting thumbnails prompts once (`askedScreenRecording` in UserDefaults).
  Without permission previews use clickable title lists. Properties → Advanced shows the current
  status and provides an **Open Screen Recording Settings…** button.

## Limitations

- Without Accessibility, task buttons fall back to one button per app. Window IDs normally come from the
  private `_AXUIElementGetWindow` symbol loaded dynamically as allowed by Feature 1; if unavailable,
  Winstripe matches process, frame, and title against layer-0 `CGWindowListCopyWindowInfo` entries.
  Identical windows can make this fallback ambiguous.
- Hover previews still discover CG window IDs without Accessibility. Missing titles fall back to
  the app name and window number. Raising an individual window and closing it require Accessibility;
  otherwise clicking a row activates its app and close controls are unavailable.
  macOS 13 uses title-only previews because the current SDK obsoletes `CGWindowListCreateImage`;
  live thumbnails use ScreenCaptureKit's screenshot API on macOS 14+. Protected or unavailable
  windows may show an app icon when capture fails. Windows on other Spaces remain subject to
  macOS capture and activation behavior.
- Activation restores minimized windows and raises windows through Accessibility. Apps with no windows
  receive the Dock “reopen” event. Minimized-window restore and reliable raising need Accessibility
  permission (Properties → Advanced). Because the bundle is ad-hoc signed, its code identity changes
  on every rebuild, so Accessibility permission may need re-granting (remove and re-add Winstripe)
  after rebuilding. For windows on other Spaces, macOS switches Space only if the app’s activation does so.
- The taskbar lives on the main display only; *Show taskbar on all displays* is a placeholder.
- It doesn't reserve screen space, so maximized windows can extend underneath it.
- Badges require Accessibility permission and depend on the Dock's accessibility tree.
- Winstripe XP uses a simplified colour scheme. Vista / 7 draw Aero glass and orbs in code; the glass
  shows the macOS desktop behind it, and menu links open macOS folders and settings.
- Winstripe 11 uses macOS acrylic materials rather than Mica.
- No system tray icons for other apps (macOS has no equivalent API); the tray holds the clock, input
  language and Show Desktop.
- Pins are stored in `UserDefaults` under `pinnedApps` and `startPins` as ordered optional bundle ID/path
  arrays. Running-app drag order is saved by bundle ID under `taskOrder`; windows retain their order
  within each app. Pins with missing or moved app paths remain saved and may fail to launch until
  removed and added again. Dragging off the bar does not remove pins.

## License

MIT © 2026 iBoysoft. Windows is a trademark of Microsoft; this project is not affiliated with Microsoft.
