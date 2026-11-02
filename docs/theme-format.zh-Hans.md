# Winstripe 主题格式

Winstripe 主题是由 `ThemeLoader` 解析的 JSON 文档。`Themes/*.json` 中编译的内置主题和用户主题使用同一套
schema。每个主题都必须使用 `$schema`：`"winstripe-theme/1"`。

## 主题位置与打包方式

内置主题是 `Themes/` 中的十个文件：`win95`、`win98`、`winme`、`win2000`、`winxp`、`vista`、`win7`、`win8`、`win10`、`win11`，并会编译进应用。
用户主题从以下目录读取：

```text
~/Library/Application Support/Winstripe/Themes/
```

该目录可以包含单独的 JSON 文件，也可以包含 `.rdtheme` 目录。目录中有一个 `theme.json`，以及它引用的相对路径资源：

```text
win95-teal.rdtheme/
  theme.json
  assets/
    orb.png
```

`.rdtheme` zip 使用相同的布局（压缩包可以有一层外部目录）。导入支持 `.rdtheme` 文件夹、`.rdtheme` zip 和单独的
`.json` 文件。导出会生成一个 zip，里面是完整解析后的主题 JSON，以及 `file` 字段引用的资源。用户主题必须有 `id`，
并会被规范化（`winXP` 变为 `winxp`）；`id` 不能等于任何内置 id，用户主题之间也不能重复。界面或导入命令选择“另存为副本”
时，id 依次使用 `id-copy`、`id-copy-2` 等，并把本地化 `name` 改写为带 `(Copy)` 的名称。

压缩包条目不能是绝对路径，不能包含 `..` 路径组成部分，也不能是符号链接。资源路径相对于声明该路径的 JSON 文件；即使
资源来自 `extends`，`startButton.drawerParams` 的路径仍然保留其声明文件的目录。

## 顶层文档与继承

加载器接受以下顶层字段：`$schema`、`id`、`name`、`version`、`extends`、`family`、`metrics`、`palette`、`bar`、`buttons`、
`layout`、`tray`、`fonts`、`startButton`、`startMenu`、`previews`。`name` 是包含 `en` 和/或
`zh-Hans` 字符串的对象。`version` 是随附主题使用的 schema 版本。未知字段会发出警告并忽略；源文件中以 `_` 开头的字段是注释，
在解析后的 dump 中会被删除。

`extends` 可以引用内置 id，也可以引用相对 JSON 文件或主题目录。对象会递归合并，带有 `inherit` 的按钮、托盘和开始按钮状态
会在合并后解析。缺少的字段再从 family 基础主题补齐：`classic` 使用 `win95`，`modern` 使用 `win11`。内置 Winstripe 7 文件
展示了这种写法：

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

因此用户主题通常只需覆盖调色板和少量策略字段：

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

## 任务栏和开始菜单颜色

任务栏颜色放在对应表面的字段中：共享的经典颜色位于 `palette`，任务栏背景和边缘位于 `bar.material` 与 `bar.edgeColor`，任务按钮颜色位于 `buttons.task`，开始按钮颜色位于 `startButton`，托盘颜色位于 `tray`。`startMenu.colors` 和 `startMenu.banner` 分别包含菜单表面、选中项、横幅渐变、横幅文字和后缀。加载器会把这些来源解析为渲染器使用的非可选颜色。

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

## 颜色

`ThemeColor` 接受以下颜色格式：

- `#RRGGBB` 和 `#RRGGBBAA`（sRGB；最后一个字节是 alpha）。
- `@paletteKey`，其中 key 在 `palette` 中定义。
- `system:<NSColor 名称>`，例如 `system:white`、`system:labelColor`、`system:clear`。
- `setting:win8StartColor`，读取 Properties 中的 Win8 开始颜色。
- `{ "white": 0.0...1.0 }`，表示灰度颜色。
- `{ "light": <color>, "dark": <color> }`，表示随外观变化的颜色。
- `{ "color": <color>, "alpha": 0.0...1.0 }`，给另一个颜色应用透明度。

真实的 Win95 文件同时使用调色板引用和字面颜色：

```json
"palette": {
  "face": "#C0C0C0",
  "highlight": "#FFFFFF",
  "shadow": "#808080",
  "text": "#000000",
  "separatorEtchedTopLeft": "@shadow"
}
```

## 任务栏和材质

`bar.material` 是材质对象。加载器识别 `none`、`solid`、`gradient`、`pattern`、`acrylic`、`aeroGlass`、`aeroButton`、`image`。
这些材质使用的字段包括 `type`、`color`、`alpha`、`stops`、`angle`、`pattern`、`colors`、`inset`、`appearance`、`nsMaterial`、
`snapshotFallback`、`variant`、`tint`、`hotTrack`、`file` 和 `slice`。真实内置主题中的纯色、渐变和 Win8 任务栏如下：

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

`bar.edge` 是包含 `bottom`、`top`、`left`、`right` 数组的对象。每条边的图层包含颜色和宽度。图片材质使用相对 `file`；
`slice` 是渲染器使用的可选图片切片参数。

## 按钮和开始按钮

`buttons.task`、`buttons.quickLaunch`、`buttons.plain`、`buttons.badge` 描述状态、填充、bevel、标题、图标和徽标。状态可以
使用 `inherit`；例如真实 Win95 文件含有 `"hover": { "inherit": "normal" }`。`buttons.bevels` 的每个名称对应一个由
`topLeft` 和 `bottomRight` 颜色组成的数组。

`startButton.drawer` 可以是 `win95Flag`、`xpPill`、`vistaOrb`、`win7Orb`、`win8Logo`、`win10Logo`、`win11Logo` 或 `image`。
`startButton.drawerParams` 包含所选绘制器的参数。内置文件实际使用的常见字段包括 `size`、`width`、`height`、`radius`、`angle`、
`gradient`、`diameter`、`gapFraction`、`minGap`、`square`、`pitch`、`originFromCenter`、`cornerRadius`、`color`、`roundOrigin`、
`classicFlag`、`aeroFlag`、`orb` 和 `plate`。`startButton.overflow` 包含 `outer`、`enabled`、`panelMargin`、`panelWidth`、
`panelHeight`、`panelInset`、`previewExtraHeight`、`menuPadding`。

图片绘制器是可移植的资源形式。它需要 `file`（或 `states.normal`），并支持 `width`、`height`、`size`、`fit`，以及
`states.normal`、`states.hover`、`states.pressed`：

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

`fit` 可以是 `contain`、`cover` 或 `stretch`。所有路径都必须是相对路径，并在继承时保持与声明主题文件的关系；资源必须是 PNG
或 PDF。`previewWallpaper` 可以是 `none`、`vista` 或 `win7`。标签使用 `startButton.label`；其中的 `key`、字体引用和颜色都是
内置文件中的真实字段。`startButton.states.normal`、`pressed`、`open` 使用与 `buttons.task` 相同的状态样式词汇。

## 布局引擎

`layout.engine` 可以是 `linear`、`aero` 或 `win8`。通用策略字段包括 `alignment`、`alignmentOptions`、`pins`（`superbar` 或
`quickLaunch`）、`labelMode`（`never`、`always`、`byGrouping`）、`groupingDefault`（`alwaysCombine`、`combineWhenFull`、
`neverCombine`）、`overflow`（`shrinkThenHide` 或 `shrinkLabelsThenHide`）、`grouping`、`fixedItems`、`startInGroup` 和
`classicOneButtonPerAppWidth`。

`layout.linear` 控制普通水平布局：`taskWidth`（`equalShare` 或 `measured`）、`rounding`、`subtractGaps`、`quickPlacement`（`none`、
`separate`、`group`）、`trayWidth`（`preferred`、`clamped`、`remaining`）、`buttonCross`、`startCross`、`startX`、`startY`、
`startHeight`、`startHeightInset`、`startAdvanceGap`、`taskY`、`taskHeight`、`taskHeightInset`、`iconWidth`、`pinnedIconWidth`、
`labelGap`、`quickSeparator`、`taskSeparator`、`trayY`、`trayHeight`、`trayHeightInset`、`trayTrailing`、`trayGap`、`hideGap`、
`availableTrailing`、`edgeMin`、`groupTrayGap`、`leading`、`quickTrailing`。

`layout.aero` 提供 Aero orb 和 superbar 几何参数：`taskHeight`、`verticalTaskHeight`、`orbSize`、`orbX`、`orbY`、`orbAnchor`（`fixed`
或 `outer`）、`orbVerticalY`、`orbWidthInset`、`contentLeading`、`trayVerticalReserve`、`afterOrbGap`、`quickSize`、`quickPitch`、
`quickHideGap`、`quickSeparatorGap`、`quickSeparatorGapVertical`、`taskWidthInset`、`iconWidth`、`limitPinnedWidth`、`combinedWidth`、
`labelledWidth`、`minWidth`、`fitGap`、`taskGap`、`taskGapVertical`。

`layout.compact` 由 Win8 引擎使用，包含 `size`、`smallSize`、`taskWidth`、`startGap`、`trayReserve`、`hideGap`、`gap`。`layout.vertical`
包含竖直任务栏设置，例如 `startWidth`、`taskWidth`、`traySizing`、`buttonHeight`、`taskPitch`、`quickLaunchWrap` 和托盘保留空间。
可选的 `layout.fixedItemParams` 为 `layout.fixedItems` 中的固定项目（`win10Search`、`win10TaskView`、`vistaShowDesktop`）提供几何参数。

## 托盘、开始菜单和预览

`tray.layout` 可以是 `linear`、`aero` 或 `win8`；`tray.items` 是 `chevron`、`inputLanguage`、`actionCenter`、`clock`、`showDesktop`
的列表。tray 对象还包含 `smoothing`、`baseWidth`、`minWidth`、`contentLeading`、`widthClamp`、`container`、`hover`，以及名为
`chevron`、`inputLanguage`、`actionCenter`、`clock`、`showDesktop`、`vertical`、`win8` 的组件对象。它们的真实字段描述组件样式、颜色、
字体、边框、步进值、时钟行和布局。例如 Win10 开启 action center：

```json
"tray": {
  "items": ["chevron", "inputLanguage", "clock", "actionCenter", "showDesktop"]
}
```

`startMenu.default` 接受 `classic95`、`classic98`、`classicME`、`classic2000`、`classicXP`、`win95`、`win98`、`winME`、`win2000`、`xp`、`vista`、`win7`、`win8`、`win10`、`win11`。
读取时 `classicXP` 会变为规范值 `xp`。Properties 可以保存显式的 `startMenuStyle` 覆盖；没有覆盖时使用主题默认值。

开始菜单混合规则由 `StartMenuTemplateRegistry` 实现：Vista 和 Winstripe 7 使用 Aero 菜单位置；只有开始按钮距离任务栏起点超过 64 点时，
水平锚点才切换到开始按钮。Winstripe 11 在任务栏居中且该主题支持居中时使用居中的开始菜单；即使 Winstripe 11 任务栏居中，classic 菜单样式
仍保持 classic。Win8 使用全屏开始屏幕，并且只有任务栏主题也是 Win8 时才覆盖任务栏。在 Properties 中选择 classic、Aero、Win8 或 Win11
样式会覆盖主题默认值，但不会修改主题 JSON。

`previews.style` 可以是 `classicTitleList`、`aeroGlass`、`flatDark` 或 `win11Acrylic`。Win11 预览还接受
`previews.params.cornerRadius`、`fill`、`color`、`fillAlpha`。

## 校验、回退与热重载

加载器会拒绝错误 schema、缺少 id、无效 JSON、继承循环和缺少的材质必需参数。无效颜色、未知策略、未知托盘项目、未知固定项目、不可用图片、
错误的绘制器或材质参数会发出警告并使用 family 默认值。`metrics.barThickness` 会被限制在 20...80，`metrics.buttonGap` 限制在 0...16，
`startButton.overflow.outer` 限制在 0...(barThickness / 2)；barThickness 会先被限制。严格校验会把警告视为失败。

导入的 PNG 和 PDF 资源不能大于 4 MiB。PNG 必须可以解码，且实际解码像素不能超过 1024×1024；检查的是像素尺寸，不是受 DPI 影响的点尺寸。
资源无效时导入不会复制任何文件。主题完整加载失败时会使用编译的 Win95 回退，Properties 显示本地化警告，诊断信息追加到
`/tmp/winstripe-theme.log`。

Winstripe 监听用户主题目录以及 debug `--theme-dir` 目录。文件变化会去抖 300 毫秒。成功变化会重新构建当前主题，并调用与 Properties「应用」
相同的 `TaskbarController.applySettings()` 路径。坏的编辑会保留上一次成功解析的主题，并显示警告。

## 导入、导出和调试命令

```sh
.build/release/Winstripe --validate-theme path/to/theme.json
.build/release/Winstripe --validate-theme builtin
.build/release/Winstripe --dump-theme win7
.build/debug/Winstripe --dump-theme win7 --theme-dir /tmp/theme-overrides
.build/release/Winstripe --import-theme theme.rdtheme --user-themes-dir /tmp/themes
.build/release/Winstripe --export-theme win7 /tmp/win7.rdtheme --user-themes-dir /tmp/themes
.build/release/Winstripe --hot-reload-test /tmp/themes
.build/debug/Winstripe --snapshot-dir /tmp/retro-snapshots --user-themes-dir /tmp/themes
```

`--theme-dir` 只用于 debug 构建，用来覆盖内置主题 JSON。`--user-themes-dir` 替换正常用户目录；测试和快照使用它，因此不会读取真实用户目录。
`--validate-theme` 可以校验 JSON 路径、文件夹、内置 id，或者用 `builtin` 校验全部十个内置主题。`--dump-theme` 输出完整解析后的 JSON。
`--import-theme`、`--export-theme` 和 `--hot-reload-test` 用于无头测试用户主题路径。`--check-theme-parity` 校验十个编译主题与旧渲染器的一致性。
以上命令都不会打开 GUI。

## 示例

仓库包含两个可以通过校验的主题包：

```text
docs/examples/win95-teal.rdtheme/theme.json
  extends: win95
  palette.face: #008080

docs/examples/win7-image-orb.rdtheme/theme.json
  extends: win7
  startButton.drawer: image
  startButton.drawerParams.file: assets/orb.png
```

第一个是青绿色的 Winstripe 95 任务栏。第二个使用图片绘制器和 `assets/orb.png` 作为 Winstripe 7 开始按钮圆球。两者都能通过
`--validate-theme`。
