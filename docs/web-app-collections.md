# Web App Collections

Collections add web apps and Mac apps to every Start menu, in two levels:

- A **first-level item** is listed by name with the Mac's apps.
- A **folder** holds items on the second level.

This repository has no source of entries, so it lists none: `Collections.provider` stays `DisabledCollectionsProvider`. A provider decides what the
entries are and what opening one does, and `Collections.install(_:)` in `AppCollections.install()` puts one in place.

| Start menu | First-level items | Folders |
|---|---|---|
| Winstripe 95 / 98 / ME / 2000 | With the apps under **Programs** | A submenu under **Programs**, after *Accessories* |
| XP | With the apps in the **All Programs** flyout | A folder at the top of the **All Programs** flyout |
| Vista / 7 | With the apps in **All Programs** | A folder row at the end of **All Programs**; click it to expand or collapse |
| 8 | With the apps in the **Apps** view | A headed column at the end of the **Apps** view |
| 10 | In the letter sections of **All apps** | A folder row in the letter sections of **All apps**; click it to expand or collapse |
| 11 | With the apps in **All apps** | A folder row among the apps in **All apps**; click it to expand or collapse |

The item description is shown as a tooltip, and as a subtitle in the Vista/7 list. Themes with
search (Vista/7, 8, 10, 11 and the Windows 10 taskbar search box) match items by name.

Collections are always on and have no settings. To hide an entry, use [**Hide**](#right-click-show-in-finder-hide-and-pin-to-taskbar).

## The interface

The app talks to collections only through `Collections.provider`, a `CollectionsProviding` from `Sources/Winstripe/Collections.swift`:

| `CollectionsProviding` | Used by |
|---|---|
| `isAvailable` | Default pins and `--collections-selftest`; false for `DisabledCollectionsProvider` |
| `start(log:)` | Once at launch; load what the provider needs, and send diagnostics to `log` |
| `rootItems(localeIdentifier:)`, `folders(localeIdentifier:)` | All Start menus, search and taskbar pins, often; keep them fast |
| `open(_:)` | Choosing an item in any Start menu, in search, on the taskbar or in a pinned folder's menu |

A `CollectionItem` has these fields:

| Field | Notes |
|---|---|
| `id` | A UUID in canonical (uppercase) form, unique within its level or folder. Pins and hidden entries follow it, so keep it stable. |
| `folderID` | The `id` of the folder holding it; nil on the first level. |
| `name`, `detail` | Text in the language asked for. |
| `icon` | Any `NSImage`. |
| `webURL` | An `https` URL: the web app, or the fallback of a Mac app. |
| `url` | What the item stands for: `webURL`, or the file URL of the installed Mac app. |
| `bundleId` | Set for Mac apps. |
| `pinnedByDefault` | See [Default taskbar pins](#default-taskbar-pins). |

A `CollectionFolder` has an `id` (any non-empty string), `name`, `icon`, `items` and `pinnedByDefault`. Its `sourceIDs` lists `id` first; a provider
that shows several folders as one lists the others after it, so pins and hidden entries of those folders keep working.

`Collections.didChange` tells the app to rebuild open lists when entries change.

## Mac apps

An item whose `url` is a file URL is treated as that app: it shows in lists as usual, and **Pin to taskbar** pins the app itself. A provider resolves this when it builds the item, for example with `NSWorkspace.urlForApplication(withBundleIdentifier:)`.

Opening a pinned app launches it directly, like any other pinned app, and does not go through `open(_:)`. A pinned web item
whose entry is gone opens the URL saved with the pin, since the provider no longer has that item.

## Default taskbar pins

An item or folder with `pinnedByDefault` is pinned to the taskbar of a new install, after any pins already there: first-level items,
then each folder followed by its items. An installed Mac app pins as that app.

This happens once. At launch Winstripe checks whether it has any preferences from before; if it has none, this is a new install. Either way
it then records that the check is done (`collectionDefaultPinsHandled`), so:

- An existing user never gets default pins, even when an update adds some.
- A pin the user removes does not come back on a later launch.
- Changing `pinnedByDefault` later affects only installs that have not launched yet.

Someone who ran an earlier version without Winstripe ever saving a preference counts as a new install.

**Reset to defaults** in Properties also adds the default pins that are missing, for any user, existing users included. The user's
own pins stay, and a default entry that is hidden is pinned all the same.

## Right-click: Show in Finder, Hide and Pin to taskbar

Right-clicking a row in a Start menu list, whether it is an app or a folder, offers **Pin to taskbar** and **Hide**. This covers
macOS apps and folders as well as collection items and folders. Rows outside the app list, such as pinned Start tiles, offer
no **Hide**, because hiding would not remove them.

**Show in Finder** appears for rows that are files: macOS apps and folders, and Mac-app items whose app is installed. Taskbar pins
of those offer it too. Web items and collection folders have nothing to show.

**Hide** removes the entry from the lists and from search. A hidden folder hides as a whole, with every id in its `sourceIDs`, and a folder whose
items are all hidden is not listed. Entries are restored in **Properties → Hidden apps and folders**, one at a time or with **Show All**. Hiding is
stored in Winstripe's preferences, not in the provider. A pinned entry stays on the taskbar when it is hidden.

**Pin to taskbar** depends on the row:

| Row | Clicking the taskbar button |
|---|---|
| macOS app, or a Mac-app item whose app is installed | Launches the app, as any pinned app |
| macOS folder | Opens it in Finder |
| Web item, or a Mac-app item whose app is not installed | Opens the item |
| Collection folder | Shows a menu of its visible items |

A collection pin follows its item or folder by `id`, so a changed name, icon or URL shows up on the taskbar. If the entry is gone,
the pin keeps the saved name and URL, and a pinned folder shows an empty menu.

Web items and folders cannot be pinned to Start, only to the taskbar.

## Testing

- `Winstripe --collections-selftest` (the older `--web-collections-selftest` still works) checks the public API, then checks that the
  installed provider keeps to what the app relies on: canonical, unique UUIDs, names, `https` web URLs, and each item's folder.
  It reads only what the provider returns, opens nothing, and names the provider it found. With no provider installed it prints `SKIP` and exits 0.
- `Winstripe --collection-pins-selftest` checks that default pins go to new installs only, once, in order and without duplicates, and that
  Reset to defaults brings them back.
- `Winstripe --collection-folders-selftest` checks first-level items and folders in the Windows 10 and 11 **All apps** lists, expands and
  collapses a folder with a real click and press, runs the **Hide** and **Pin to taskbar** menu actions, checks how collection pins are
  stored, and checks that each way of opening an item ends at the provider.
- Offscreen snapshots (`--snapshot-dir`) and these last two never use a real provider: they install `FixtureCollectionsProvider`, whose
  entries are written in `AppCollections.swift`. To render collections, pass `--collections-fixture`.
  With it, the set also includes Windows 10 and 11 renders with every folder expanded and a Windows 11 taskbar with collection pins.
