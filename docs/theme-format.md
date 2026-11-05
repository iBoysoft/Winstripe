# Winstripe theme format

Winstripe themes are JSON documents resolved by `ThemeLoader`. The loader reads the same schema for the
compiled themes in `Themes/*.json` and for user themes. The schema marker is always
`"$schema": "winstripe-theme/1"`.

## Where themes live and how they are packaged

Built-ins are the ten JSON files in `Themes/`: `win95`, `win98`, `winme`, `win2000`, `winxp`, `vista`,
`win7`, `win8`, `win10`, and `win11`. They are compiled into the application. User themes are read from:

```text
~/Library/Application Support/Winstripe/Themes/
```

The directory accepts either a loose JSON document or an `.rdtheme` directory. A directory contains one
`theme.json` and any relative assets it references:

```text
win95-teal.rdtheme/
  theme.json
  assets/
    orb.png
```

An `.rdtheme` zip uses the same layout (the archive may have a single enclosing directory). Import accepts
an `.rdtheme` folder, an `.rdtheme` zip, and a loose `.json`. Export writes a zip containing a fully
resolved theme JSON and the assets referenced by `file` fields. A user `id` is required, is canonicalized
(`winXP` becomes `winxp`), and may not equal a built-in id. User ids must also be unique. When the UI or
import command chooses “Save as copy”, the ids are `id-copy`, `id-copy-2`, and so on; the localized
`name` is rewritten with `(Copy)`.

Archive entries must not be absolute, contain a `..` path component, or be symlinks. Asset paths are
relative to the JSON file that declared them, including inherited `startButton.drawerParams` paths.

## Top-level document and inheritance

These are the top-level keys accepted by the loader: `$schema`, `id`, `name`, `version`, `extends`,
`family`, `metrics`, `palette`, `bar`, `buttons`, `layout`, `tray`, `fonts`, `startButton`, `startMenu`,
`previews`. `name` is an object with `en` and/or `zh-Hans` strings.
`version` is the numeric schema version used by the shipped files. Unknown keys are ignored with a warning;
keys beginning with `_` are comments in the source files and are removed from the resolved dump.

A child theme may extend a built-in id or a relative JSON/folder path. Objects are merged recursively and
button/tray/start-button states with `"inherit"` are resolved after the merge. Missing values then come
from the selected family base: `classic` uses `win95`, and `modern` uses `win11`. The built-ins show the
pattern:

```json
{
  "$schema": "winstripe-theme/1",
  "id": "win7",
  "name": { "en": "Winstripe 7", "zh-Hans": "Winstripe 7" },
  "version": 1,
  "family": "modern",
  "extends": "win11",
  "bar": {
    "material": {
      "type": "aeroGlass",
      "variant": "win7",
      "tint": { "color": "#2D4B64", "alpha": 0.78 }
    }
  }
}
```

A minimal user theme can therefore override only a palette and a few strategy values:

```json
{
  "$schema": "winstripe-theme/1",
  "id": "my-classic",
  "name": { "en": "My Classic" },
  "version": 1,
  "family": "classic",
  "extends": "win95",
  "palette": { "face": "#008080", "highlight": "#B8FFFF" }
}
```

## Taskbar and Start menu colors

Taskbar colors live in the fields that own the corresponding surface. Shared classic colors are in `palette`; bar colors are in `bar.material` and `bar.edgeColor`; task button colors are in `buttons.task`; Start button colors are in `startButton`; and tray colors are in `tray`. `startMenu.colors` and `startMenu.banner` contain the menu surface, selection, banner gradient, banner text, and suffix. The loader resolves these sources into the renderer’s non-optional color values.

```json
{
  "palette": {
    "face": "@face", "highlight": "@highlight", "light": "@light",
    "shadow": "@shadow", "darkShadow": "@darkShadow", "inputBadge": "@inputBadge"
  },
  "bar": {
    "material": { "type": "solid", "color": "@face" },
    "edgeColor": "#00000000"
  },
  "buttons": {
    "task": {
      "normalFill": [], "activeFill": [], "borderColor": "#00000000", "textColor": "@text"
    }
  },
  "startButton": { "fill": [], "textColor": "@text" },
  "tray": { "textColor": "@text", "inputLanguage": { "fill": "@inputBadge" } },
  "startMenu": {
    "default": "classic95",
    "colors": { "face": "@face", "text": "@text", "highlight": "#000080" },
    "banner": { "fill": ["#808080"], "text": "#C0C0C0", "suffix": "95" }
  }
}
```

## Colors

Color values accepted by `ThemeColor` are:

- `#RRGGBB` and `#RRGGBBAA` (sRGB; the last byte is alpha).
- `@paletteKey`, where the key is defined in `palette`.
- `system:<NSColor name>`, such as `system:white`, `system:labelColor`, or `system:clear`.
- `setting:win8StartColor`, which reads the Properties Win8 start color.
- `{ "white": 0.0...1.0 }` for a grayscale color.
- `{ "light": <color>, "dark": <color> }` for an appearance-dependent color.
- `{ "color": <color>, "alpha": 0.0...1.0 }` to apply alpha to another color.

The built-in Win95 palette uses references and literal colors:

```json
"palette": {
  "face": "#C0C0C0",
  "highlight": "#FFFFFF",
  "shadow": "#808080",
  "text": "#000000",
  "separatorEtchedTopLeft": "@shadow"
}
```

## Bar and materials

`bar.material` is a material object. The loader recognizes `none`, `solid`, `gradient`, `pattern`,
`acrylic`, `aeroGlass`, `aeroButton`, and `image`. The fields used by these material types are `type`,
`color`, `alpha`, `stops`, `angle`, `pattern`, `colors`, `inset`, `appearance`, `nsMaterial`,
`snapshotFallback`, `variant`, `tint`, `hotTrack`, `file`, and `slice`. A solid, gradient, and Win8 bar
from the real built-ins look like this:

```json
"bar": {
  "material": { "type": "solid", "color": "@face" }
}
```

```json
"bar": {
  "material": {
    "type": "gradient",
    "stops": ["@xpBar1", "@xpBar2", "@xpBar3", "@xpBar4"],
    "angle": 90,
    "params": { "verticalAngleOffset": 90 }
  }
}
```

```json
"bar": {
  "material": { "type": "solid", "color": "setting:win8StartColor", "alpha": 0.78 }
}
```

`bar.edge` is an object with `bottom`, `top`, `left`, and `right` arrays. Each layer contains a color
and width. Image materials use a relative `file`; `slice` is the optional image-slice parameter used by
the renderer.

## Buttons and the Start button

`buttons.task`, `buttons.quickLaunch`, `buttons.plain`, and `buttons.badge` describe states, fills,
bevels, titles, icons, and badges. A state can use `inherit`, for example the real Win95 file contains
`"hover": { "inherit": "normal" }`. `buttons.bevels` names arrays of `topLeft` and `bottomRight`
colors.

`startButton.drawer` accepts `win95Flag`, `xpPill`, `vistaOrb`, `win7Orb`, `win8Logo`, `win10Logo`,
`win11Logo`, or `image`. `startButton.drawerParams` contains parameters for the selected drawer. Common
fields in the built-ins include `size`, `width`, `height`, `radius`, `angle`, `gradient`, `diameter`,
`gapFraction`, `minGap`, `square`, `pitch`, `originFromCenter`, `cornerRadius`, `color`, `roundOrigin`,
`classicFlag`, `aeroFlag`, `orb`, and `plate`. `startButton.overflow` contains `outer`, `enabled`,
`panelMargin`, `panelWidth`, `panelHeight`, `panelInset`, `previewExtraHeight`, and `menuPadding`.

The image drawer is the portable asset form. It requires `file` (or `states.normal`) and accepts
`width`, `height`, `size`, `fit`, and `states.normal`, `states.hover`, and `states.pressed`:

```json
"startButton": {
  "previewWallpaper": "win7",
  "drawer": "image",
  "drawerParams": {
    "file": "assets/orb.png",
    "width": 42,
    "height": 42,
    "fit": "contain",
    "states": {
      "normal": "assets/orb.png",
      "hover": "assets/orb-hover.png",
      "pressed": "assets/orb-pressed.png"
    }
  }
}
```

`fit` is `contain`, `cover`, or `stretch`. All paths are relative, remain tied to the declaring theme
file during inheritance, and must resolve to PNG or PDF assets. `previewWallpaper` is `none`, `vista`,
or `win7`. The label uses `startButton.label`; its `key`, font reference, and color are actual fields in
the built-ins. `startButton.states.normal`, `pressed`, and `open` use the same state-style vocabulary as
`buttons.task`.

## Layout engines

`layout.engine` is `linear`, `aero`, or `win8`. The shared strategy keys are `alignment`,
`alignmentOptions`, `pins` (`superbar` or `quickLaunch`), `labelMode` (`never`, `always`, or `byGrouping`),
`groupingDefault` (`alwaysCombine`, `combineWhenFull`, or `neverCombine`), `overflow` (`shrinkThenHide`
or `shrinkLabelsThenHide`), `grouping`, `fixedItems`, `startInGroup`, and
`classicOneButtonPerAppWidth`.

`layout.linear` controls normal horizontal placement: `taskWidth` (`equalShare` or `measured`),
`rounding`, `subtractGaps`, `quickPlacement` (`none`, `separate`, `group`), `trayWidth` (`preferred`,
`clamped`, `remaining`), `buttonCross`, `startCross`, `startX`, `startY`, `startHeight`,
`startHeightInset`, `startAdvanceGap`, `taskY`, `taskHeight`, `taskHeightInset`, `iconWidth`,
`pinnedIconWidth`, `labelGap`, `quickSeparator`, `taskSeparator`, `trayY`, `trayHeight`,
`trayHeightInset`, `trayTrailing`, `trayGap`, `hideGap`, `availableTrailing`, `edgeMin`, `groupTrayGap`,
`leading`, and `quickTrailing`.

`layout.aero` supplies Aero orb and superbar geometry: `taskHeight`, `verticalTaskHeight`, `orbSize`,
`orbX`, `orbY`, `orbAnchor` (`fixed` or `outer`), `orbVerticalY`, `orbWidthInset`, `contentLeading`,
`trayVerticalReserve`, `afterOrbGap`, `quickSize`, `quickPitch`, `quickHideGap`,
`quickSeparatorGap`, `quickSeparatorGapVertical`, `taskWidthInset`, `iconWidth`, `limitPinnedWidth`,
`combinedWidth`, `labelledWidth`, `minWidth`, `fitGap`, `taskGap`, and `taskGapVertical`.

`layout.compact` is used by the Win8 engine and contains `size`, `smallSize`, `taskWidth`, `startGap`,
`trayReserve`, `hideGap`, and `gap`. `layout.vertical` contains the vertical taskbar choices such as
`startWidth`, `taskWidth`, `traySizing`, `buttonHeight`, `taskPitch`, `quickLaunchWrap`, and tray reserves.
The optional `layout.fixedItemParams` object supplies geometry for the fixed items named in
`layout.fixedItems` (`win10Search`, `win10TaskView`, and `vistaShowDesktop`).

## Tray, start menu, and previews

`tray.layout` is `linear`, `aero`, or `win8`; `tray.items` is a list of `chevron`, `inputLanguage`,
`actionCenter`, `clock`, and `showDesktop`. The tray object also contains `smoothing`, `baseWidth`,
`minWidth`, `contentLeading`, `widthClamp`, `container`, `hover`, and component objects named
`chevron`, `inputLanguage`, `actionCenter`, `clock`, `showDesktop`, `vertical`, and `win8`. Their actual
fields describe the component style, colors, fonts, frames, advances, and clock lines. For example,
Win10 enables the action center:

```json
"tray": {
  "items": ["chevron", "inputLanguage", "clock", "actionCenter", "showDesktop"]
}
```

`startMenu.default` accepts `classic95`, `classic98`, `classicME`, `classic2000`, `classicXP`, `win95`, `win98`,
`winME`, `win2000`, `xp`, `vista`,
`win7`, `win8`, `win10`, and `win11`. `classicXP` is read as the canonical `xp` value. Properties can
store an explicit `startMenuStyle` override; when it is absent, the theme default is used.

The menu mix rules are implemented by `StartMenuTemplateRegistry`: Vista and Winstripe 7 use the Aero
menu placement whose horizontal anchor switches to the Start button only when that button is more than
64 points from the bar start. Winstripe 11 uses the centered Start menu when the taskbar alignment is
centered; classic menu styles remain classic even on a centered Winstripe 11 taskbar. Win8 uses the
full-screen start screen and covers the taskbar only when the taskbar theme is also Win8. Choosing a
classic, Aero, Win8, or Win11 style in Properties overrides the theme default without changing the
serialized theme.

`previews.style` is `classicTitleList`, `aeroGlass`, `flatDark`, or `win11Acrylic`. The Win11 preview
also accepts `previews.params.cornerRadius`, `fill`, `color`, and `fillAlpha`.

## Validation, fallback, and hot reload

The loader rejects a wrong schema, missing id, invalid JSON, inheritance cycles, and missing required
material parameters. It warns and uses the family default for invalid colors, unknown strategy values,
unknown tray items, unknown fixed items, unavailable images, and invalid drawer/material parameters.
It clamps `metrics.barThickness` to 20...80, `metrics.buttonGap` to 0...16, and
`startButton.overflow.outer` to 0...(barThickness / 2), after bar thickness itself is clamped. Strict
validation treats warnings as failures.

Imported PNG and PDF assets must be no larger than 4 MiB. PNGs must decode and must be no more than
1024×1024 pixels; the check uses decoded pixel dimensions, not DPI-scaled point size. Invalid assets
cause import to copy nothing. A complete load failure resolves the compiled Win95 fallback, Properties
shows the localized warning, and diagnostics are appended to `/tmp/winstripe-theme.log`.

Winstripe watches the user themes directory and the debug `--theme-dir` directory. File changes are
debounced for 300 ms. A successful change rebuilds the resolved active theme and calls the same
`TaskbarController.applySettings()` path used by Properties Apply. A broken edit retains the last good
resolved theme and exposes the warning.

## Import, export, and debug commands

```sh
.build/release/Winstripe --validate-theme path/to/theme.json
.build/release/Winstripe --validate-theme builtin
.build/release/Winstripe --dump-theme win7
.build/debug/Winstripe --dump-theme win7 --theme-dir /tmp/theme-overrides
.build/release/Winstripe --import-theme theme.rdtheme --user-themes-dir /tmp/themes
.build/release/Winstripe --export-theme win7 /tmp/win7.rdtheme --user-themes-dir /tmp/themes
.build/release/Winstripe --hot-reload-test /tmp/themes
.build/debug/Winstripe --snapshot-dir /tmp/winstripe-snapshots --user-themes-dir /tmp/themes
```

`--theme-dir` is a debug-only built-in override directory. `--user-themes-dir` replaces the normal
user directory and is used by tests and snapshots so they never read the real home directory.
`--validate-theme` validates a JSON path, folder, built-in id, or `builtin` (all eight built-ins).
`--dump-theme` prints the fully resolved JSON. `--import-theme`, `--export-theme`, and
`--hot-reload-test` exercise the user-theme paths headlessly. `--check-theme-parity` verifies the eight
compiled themes against their compatibility renderer. No command above opens the GUI.

## Examples

The repository includes two validating packages:

```text
docs/examples/win95-teal.rdtheme/theme.json
  extends: win95
  palette.face: #008080

docs/examples/win7-image-orb.rdtheme/theme.json
  extends: win7
  startButton.drawer: image
  startButton.drawerParams.file: assets/orb.png
```

The first is a teal Winstripe 95 bar. The second uses the image drawer and `assets/orb.png` for a Winstripe 7
orb. Both pass `--validate-theme`.
