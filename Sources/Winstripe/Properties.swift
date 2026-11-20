import AppKit
import Combine
import ApplicationServices
import LaunchAtLogin
import SwiftUI
import UniformTypeIdentifiers

struct ThemePopupItem: Identifiable {
    let id: String
    let title: String
    let selected: Bool
}

struct ThemePopupGroup {
    let title: String
    let items: [ThemePopupItem]
}

struct ThemePopupMenuModel {
    let builtIn: ThemePopupGroup
    let user: ThemePopupGroup?
}

enum ThemePopupMenu {
    @MainActor
    static func build(language: Language, selection: String,
                      userThemes: [UserThemeRecord]) -> ThemePopupMenuModel {
        let builtIn = ThemePopupGroup(
            title: L.t("Built-in", language),
            items: ThemeKind.allCases.map { kind in
                ThemePopupItem(id: kind.id, title: L.t(kind.rawValue, language), selected: selection == kind.id)
            })
        let user: ThemePopupGroup? = userThemes.isEmpty ? nil : ThemePopupGroup(
            title: L.t("My themes", language),
            items: userThemes.map { record in
                let code = language.resolvedLanguage.localeIdentifier
                let fallbacks = [code, code == "zh-Hant" ? "zh-Hans" : nil, code.hasPrefix("pt") ? "pt" : nil, "en", "zh-Hans"]
                let title = fallbacks.lazy.compactMap { $0.flatMap { record.name[$0] } }.first ?? record.id
                return ThemePopupItem(id: record.id, title: title, selected: selection == record.id)
            })
        return ThemePopupMenuModel(builtIn: builtIn, user: user)
    }
}


/// AppKit popup used for the theme list so menu tracking never runs SwiftUI layout.
struct ThemePopUpButton: NSViewRepresentable {
    var menuModel: ThemePopupMenuModel
    var selection: String
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        button.autoenablesItems = false
        // Size to content (widest item, so picks never change the width) and
        // match the borderless look of the SwiftUI Pickers in the grouped Form.
        button.isBordered = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityIdentifier("setting.theme")
        context.coordinator.rebuild(button, menuModel: menuModel, selection: selection)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.rebuild(button, menuModel: menuModel, selection: selection)
    }

    final class Coordinator: NSObject {
        var onSelect: (String) -> Void
        private var lastMenuKey = ""
        private var lastSelection = ""
        private var pendingSelection: String?

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func rebuild(_ button: NSPopUpButton, menuModel: ThemePopupMenuModel, selection: String) {
            if pendingSelection == selection { pendingSelection = nil }
            let key = menuKey(menuModel)
            if key != lastMenuKey {
                button.removeAllItems()
                let menu = NSMenu()
                menu.addItem(header(menuModel.builtIn.title))
                for item in menuModel.builtIn.items { menu.addItem(entry(item)) }
                if let user = menuModel.user {
                    menu.addItem(NSMenuItem.separator())
                    menu.addItem(header(user.title))
                    for item in user.items { menu.addItem(entry(item)) }
                }
                button.menu = menu
                // A fresh menu defaults to item 0 (the header); force a reselect.
                lastSelection = ""
                lastMenuKey = key
            }
            // While a user pick is pending, leave AppKit selection alone.
            if pendingSelection != nil {
                lastSelection = pendingSelection ?? lastSelection
                return
            }
            if selection != lastSelection || button.selectedItem?.representedObject as? String != selection
                || !isEntry(button.selectedItem) {
                if let index = button.itemArray.firstIndex(where: { ($0.representedObject as? String) == selection }) {
                    NSAnimationContext.beginGrouping()
                    NSAnimationContext.current.duration = 0
                    button.selectItem(at: index)
                    NSAnimationContext.endGrouping()
                }
                lastSelection = selection
            }
        }

        private func isEntry(_ item: NSMenuItem?) -> Bool {
            guard let item else { return false }
            return item.isEnabled && !item.isSeparatorItem && item.representedObject is String
        }

        /// Never leave a header/separator as the popup's selected item.
        private func revert(_ button: NSPopUpButton) {
            let target = pendingSelection ?? lastSelection
            if let index = button.itemArray.firstIndex(where: { ($0.representedObject as? String) == target }) {
                button.selectItem(at: index)
            } else if let index = button.itemArray.firstIndex(where: { isEntry($0) }) {
                button.selectItem(at: index)
            }
        }

        private func menuKey(_ model: ThemePopupMenuModel) -> String {
            let built = model.builtIn.items.map { "\($0.id):\($0.title)" }.joined(separator: ",")
            let user = model.user?.items.map { "\($0.id):\($0.title)" }.joined(separator: ",") ?? ""
            return "\(model.builtIn.title)|\(built)|\(model.user?.title ?? "")|\(user)"
        }

        private func header(_ title: String) -> NSMenuItem {
            // Disabled, gray, non-selectable header. Same font as the items so the
            // popup's intrinsic size (and Settings layout) is unchanged.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.target = nil
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: 0)])
            return item
        }

        private func entry(_ item: ThemePopupItem) -> NSMenuItem {
            let menuItem = NSMenuItem(title: item.title, action: #selector(changed(_:)), keyEquivalent: "")
            menuItem.representedObject = item.id
            menuItem.target = self
            return menuItem
        }

        @objc func changed(_ sender: Any?) {
            let id: String?
            if let button = sender as? NSPopUpButton {
                guard isEntry(button.selectedItem) else { revert(button); return }
                id = button.selectedItem?.representedObject as? String
            } else if let item = sender as? NSMenuItem {
                id = item.representedObject as? String
            } else {
                id = nil
            }
            guard let id else { return }
            pendingSelection = id
            lastSelection = id
            RunLoop.main.perform(inModes: [.default]) { [onSelect] in
                DispatchQueue.main.async { onSelect(id) }
            }
        }
    }
}

@MainActor
private final class ThemePopupMenuCache: ObservableObject {
    private var key: String?
    private var cached: ThemePopupMenuModel?

    func menu(language: Language, selection: String,
              userThemes: [UserThemeRecord]) -> ThemePopupMenuModel {
        let userKey = userThemes.map { record in
            let en = record.name["en"] ?? ""
            let zh = record.name["zh-Hans"] ?? ""
            return "\(record.id)|\(en)|\(zh)"
        }.joined(separator: "\u{1F}")
        // Selection must not bust the cache: rebuilding the menu model during
        // an open NSPopUpButton is what made the first pick stall the main thread.
        let nextKey = "\(language.rawValue)|\(userKey)"
        if let key, key == nextKey, let cached { return cached }
        let value = ThemePopupMenu.build(language: language,
                                         selection: selection,
                                         userThemes: userThemes)
        key = nextKey
        cached = value
        return value
    }
}

@MainActor
protocol PropertiesStoreTarget: AnyObject {
    var current: TaskbarSettings { get }
    func update(_ new: TaskbarSettings)
}

extension SettingsStore: PropertiesStoreTarget {}

/// The hidden list entries, kept current for the Properties section that manages them.
@MainActor
final class HiddenItemsModel: ObservableObject {
    @Published private(set) var entries = HiddenStore().entries
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: HiddenStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.entries = HiddenStore().entries }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func icon(for entry: HiddenEntry) -> NSImage {
        if let path = entry.path, FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: entry.isFolder ? "folder.fill" : "globe", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }
}

extension HiddenEntry {
    var rowID: String { "\(kind.rawValue):\(key)" }
}

@MainActor
final class PropertiesModel: NSObject, ObservableObject {
    @Published var draft = TaskbarSettings() {
        didSet {
            guard !isSyncingFromStore else { return }
            apply()
        }
    }
    @Published var accessibilityGranted = SnapshotFixture.isActive ? true : AXIsProcessTrusted()
    @Published var screenRecordingGranted = SnapshotFixture.isActive ? false : ScreenRecordingAccess.preflight()
    @Published var userThemes: [UserThemeRecord] = []
    @Published var themeWarning: String?
    @Published private(set) var themeCapabilities = ThemeKind.win95.capabilities
    /// While true, appearance/notification previews keep the previous strip and
    /// syncFromStore ignores SettingsStore publishes from our own theme commit.
    private var themeCommitInFlight = false
    private var suppressStoreSync = false
    private var pendingThemeCommit: TaskbarSettings?
    var onClose: (() -> Void)?
    var onPermissionsRefresh: (() -> Void)?
    var previewApps: (() -> [AppEntry])?
    var previewActivePID: (() -> pid_t?)?
    private let store: any PropertiesStoreTarget
    private var accessibilityTimer: Timer?
    private var storeObserver: NSObjectProtocol?
    private var isSyncingFromStore = false
    private var isRefreshingThemes = false
    private var lastCommittedDraft: TaskbarSettings?
    private var themeValidationGeneration = 0
    private var applyingThemeFallback = false
    private var appearancePreviewSettings: TaskbarSettings?
    private var appearancePreviewApps: [AppEntry] = []
    private var appearancePreviewPID: pid_t?
    private var appearancePreviewImage: NSImage?
    /// Width of the preview row as laid out by SwiftUI. Previews render at exactly
    /// this width (cached per width; resizes are coalesced).
    private(set) var previewWidth: CGFloat = SnapshotFixture.isActive ? PreviewRenderer.snapshotPreviewWidth : 0
    private var previewResizeGeneration = 0
    private var appearancePreviewWidth: CGFloat = -1
    private var notificationPreviewWidth: CGFloat = -1
    private var appearancePreviewQueuedWidth: CGFloat = -1
    private var notificationPreviewQueuedWidth: CGFloat = -1
    private var appearancePreviewGeneration = 0
    private var appearancePreviewGenerating = false
    private var appearancePreviewQueuedSettings: TaskbarSettings?
    private var appearancePreviewQueuedApps: [AppEntry] = []
    private var appearancePreviewQueuedPID: pid_t?
    private var notificationPreviewSettings: TaskbarSettings?
    private var notificationPreviewImage: NSImage?
    private var notificationPreviewGeneration = 0
    private var notificationPreviewGenerating = false
    private var notificationPreviewQueuedSettings: TaskbarSettings?

    override convenience init() {
        self.init(store: SettingsStore.shared)
    }

    init(store: any PropertiesStoreTarget) {
        self.store = store
        super.init()
        isSyncingFromStore = true
        draft = store.current
        isSyncingFromStore = false
        lastCommittedDraft = draft
        themeCapabilities = draft.capabilities
        refreshThemes()
        if store is SettingsStore {
            storeObserver = NotificationCenter.default.addObserver(
                forName: SettingsStore.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncFromStore()
                }
            }
        }
    }

    func refreshThemes() {
        isRefreshingThemes = true
        defer { isRefreshingThemes = false }
        let catalog = UserThemeCatalog.records()
        userThemes = catalog.0
        themeWarning = catalog.1.first
        let id = draft.activeThemeID
        if SnapshotFixture.isActive {
            applyThemeValidation(id: id, result: try? ThemeResolutionCache.shared.loadSync(id), catalogWarning: catalog.1.first)
        } else {
            validateThemeAsync(id: id, catalogWarning: catalog.1.first)
        }
    }

    private func validateThemeAsync(id: String, catalogWarning: String?) {
        themeValidationGeneration += 1
        let generation = themeValidationGeneration
        ThemeResolutionCache.shared.loadAsync(id) { [weak self] result in
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          generation == self.themeValidationGeneration,
                          self.draft.activeThemeID == id else { return }
                    self.applyThemeValidation(id: id, result: result, catalogWarning: catalogWarning)
                }
            }
        }
    }

    private func applyThemeValidation(id: String, result: ThemeLoadResult?, catalogWarning: String?) {
        let selectedFailure = result?.diagnostics.first(where: { $0.severity == .error })?.message
            ?? (result == nil ? "unknown theme \(id)" : nil)
        themeWarning = selectedFailure ?? catalogWarning
        if let result {
            Theme.preload(id, result: result)
            if draft.activeThemeID == id { themeCapabilities = draft.capabilities }
        }
        if let warning = themeWarning {
            let line = "properties: \(warning)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/winstripe-theme.log")) {
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } catch {}
                } else {
                    FileManager.default.createFile(atPath: "/tmp/winstripe-theme.log", contents: data)
                }
            }
        }
        guard selectedFailure != nil, draft.activeThemeID == id else { return }
        applyingThemeFallback = true
        var fallback = draft
        fallback.userThemeID = nil
        fallback.theme = .win95
        draft = fallback
        themeCapabilities = fallback.capabilities
        themeWarning = selectedFailure
    }

    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .folder, .zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ThemeImportExport.importTheme(url)
            refreshThemes()
        } catch ThemeImportError.duplicate {
            let alert = NSAlert()
            alert.messageText = L.t("Theme already exists", draft.resolvedLanguage)
            alert.informativeText = L.t("Save as copy?", draft.resolvedLanguage)
            alert.addButton(withTitle: L.t("Save as copy", draft.resolvedLanguage))
            alert.addButton(withTitle: L.t("Cancel", draft.resolvedLanguage))
            if alert.runModal() == .alertFirstButtonReturn {
                do { _ = try ThemeImportExport.importTheme(url, allowCopy: true); refreshThemes() }
                catch { themeWarning = error.localizedDescription }
            }
        } catch {
            themeWarning = error.localizedDescription
        }
    }

    func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(draft.activeThemeID).rdtheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ThemeImportExport.exportTheme(id: draft.activeThemeID, to: url) }
        catch { themeWarning = error.localizedDescription }
    }

    func openThemesFolder() {
        try? FileManager.default.createDirectory(at: ThemePaths.userThemesDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ThemePaths.userThemesDirectory)
    }

    func refreshPermissions() {
        let accessibility = SnapshotFixture.isActive || AXIsProcessTrusted()
        let screenRecording = SnapshotFixture.isActive ? false : ScreenRecordingAccess.preflight()
        let changed = accessibilityGranted != accessibility || screenRecordingGranted != screenRecording
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if screenRecordingGranted != screenRecording { screenRecordingGranted = screenRecording }
        if changed { onPermissionsRefresh?() }
    }

    func startPermissionMonitoring() {
        refreshPermissions()
        guard !SnapshotFixture.isActive, accessibilityTimer == nil else { return }
        let timer = Timer(timeInterval: 2, target: self,
                          selector: #selector(refreshAccessibility), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func stopPermissionMonitoring() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    @objc private func refreshAccessibility() { refreshPermissions() }

    private func syncFromStore() {
        if suppressStoreSync || themeCommitInFlight { return }
        let current = store.current
        guard current != draft else { return }
        isSyncingFromStore = true
        draft = current
        isSyncingFromStore = false
        lastCommittedDraft = draft
        themeCapabilities = draft.capabilities
        refreshThemes()
    }

    /// Commits a theme pick without rebuilding the Settings Form on the menu-tracking turn.
    /// The AppKit popup keeps the selection locally. Taskbar store update runs after
    /// tracking ends; @Published draft / capabilities / previews update one turn later.
    func commitThemeSelection(_ value: String) {
        var updated = draft
        if let kind = ThemeKind(themeID: value) { updated.userThemeID = nil; updated.theme = kind }
        else { updated.userThemeID = value; updated.theme = UserThemeCatalog.familyKind(id: value) }
        guard updated.activeThemeID != draft.activeThemeID else { return }
        if SnapshotFixture.isActive {
            draft = updated
            return
        }
        pendingThemeCommit = updated
        themeCommitInFlight = true
        suppressStoreSync = true
        // After tracking ends: wait two main turns + a short delay so the menu
        // can dismiss and paint before any store / Form / taskbar work.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.flushThemeCommitToStore()
                }
            }
        }
    }

    private func flushThemeCommitToStore() {
        guard let updated = pendingThemeCommit else {
            themeCommitInFlight = false
            suppressStoreSync = false
            return
        }
        lastCommittedDraft = updated
        if !(SnapshotFixture.isActive && store is SettingsStore) {
            store.update(updated)
        }
        if !isRefreshingThemes {
            validateThemeAsync(id: updated.activeThemeID, catalogWarning: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.publishThemeCommit(updated)
        }
    }

    private func publishThemeCommit(_ updated: TaskbarSettings) {
        pendingThemeCommit = nil
        isSyncingFromStore = true
        draft = updated
        isSyncingFromStore = false
        lastCommittedDraft = updated
        themeCapabilities = updated.capabilities
        themeCommitInFlight = false
        suppressStoreSync = false
    }

    func apply() {
        guard lastCommittedDraft != draft else { return }
        let themeChanged = lastCommittedDraft?.activeThemeID != draft.activeThemeID
        lastCommittedDraft = draft
        // Snapshot renders use the real singleton for their model setup. Keep those
        // renders isolated from the user's preferences while still allowing injected
        // test stores to observe every live edit.
        if SnapshotFixture.isActive, store is SettingsStore { return }
        store.update(draft)
        if themeChanged && !applyingThemeFallback && !isRefreshingThemes {
            if SnapshotFixture.isActive {
                refreshThemes()
            } else {
                validateThemeAsync(id: draft.activeThemeID, catalogWarning: nil)
            }
        }
        applyingThemeFallback = false
    }

    deinit {
        accessibilityTimer?.invalidate()
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    func resetToDefaults() {
        draft = TaskbarSettings()
        AppCollections.restoreDefaultPins()
    }

    func chooseQuickLaunchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L.t("OK", draft.resolvedLanguage)
        if !draft.quickLaunchPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.quickLaunchPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            var updated = draft
            updated.quickLaunchPath = url.path
            updated.showQuickLaunch = true
            draft = updated
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestAccessibility() {
        guard !SnapshotFixture.isActive else { return }
        guard !AXIsProcessTrusted() else {
            refreshPermissions()
            return
        }
        // Ask WindowServer to authorize event posting by sending a harmless
        // key-up event with an unused virtual key. This is the same input path
        // Winstripe needs for window activation and avoids relying on the AX
        // prompt helper, which is unreliable for sandboxed/App Store builds.
        CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode.max, keyDown: false)?
            .post(tap: .cghidEventTap)
        refreshPermissions()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenRecording() {
        _ = ScreenRecordingAccess.request()
        refreshPermissions()
    }

    func previewImage() -> NSImage {
        PreviewRenderer.image(settings: draft, apps: previewApps?() ?? [], activePID: previewActivePID?() ?? nil)
    }

    func setPreviewWidth(_ raw: CGFloat) {
        let width = raw.rounded(.down)
        guard width >= 160, width != previewWidth else { return }
        if SnapshotFixture.isActive { return }
        let first = previewWidth == 0
        previewWidth = width
        previewResizeGeneration += 1
        let generation = previewResizeGeneration
        // First measurement renders right away; live window resizes are coalesced.
        DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.15)) { [weak self] in
            guard let self, generation == self.previewResizeGeneration else { return }
            self.objectWillChange.send()
        }
    }

    private var placeholderPreview: NSImage {
        NSImage(size: NSSize(width: max(previewWidth, PreviewRenderer.stripWidth), height: 40))
    }

    func appearancePreview() -> NSImage {
        let apps = previewApps?() ?? []
        let activePID = previewActivePID?() ?? nil
        if themeCommitInFlight, let image = appearancePreviewImage { return image }
        if previewWidth == 0 { return appearancePreviewImage ?? placeholderPreview }
        if appearancePreviewSettings == draft,
           appearancePreviewWidth == previewWidth,
           appearancePreviewApps == apps,
           appearancePreviewPID == activePID,
           let image = appearancePreviewImage { return image }
        if !SnapshotFixture.isActive {
            if themeCommitInFlight {
                return appearancePreviewImage ?? placeholderPreview
            }
            scheduleAppearancePreview(settings: draft, apps: apps, activePID: activePID)
            if let image = appearancePreviewImage { return image }
            return placeholderPreview
        }
        let image = PreviewRenderer.stripImage(settings: draft, kind: .appearance,
                                               apps: apps, activePID: activePID, width: previewWidth)
        appearancePreviewWidth = previewWidth
        appearancePreviewSettings = draft
        appearancePreviewApps = apps
        appearancePreviewPID = activePID
        appearancePreviewImage = image
        return image
    }

    func notificationPreview() -> NSImage {
        if themeCommitInFlight, let image = notificationPreviewImage { return image }
        if previewWidth == 0 { return notificationPreviewImage ?? placeholderPreview }
        if notificationPreviewSettings == draft, notificationPreviewWidth == previewWidth,
           let image = notificationPreviewImage { return image }
        if !SnapshotFixture.isActive {
            if themeCommitInFlight {
                return notificationPreviewImage ?? placeholderPreview
            }
            scheduleNotificationPreview(settings: draft)
            if let image = notificationPreviewImage { return image }
            return placeholderPreview
        }
        let image = PreviewRenderer.stripImage(settings: draft, kind: .notification,
                                               apps: [], activePID: nil, width: previewWidth)
        notificationPreviewWidth = previewWidth
        notificationPreviewSettings = draft
        notificationPreviewImage = image
        return image
    }

    private func scheduleAppearancePreview(settings: TaskbarSettings, apps: [AppEntry], activePID: pid_t?) {
        if appearancePreviewGenerating,
           appearancePreviewQueuedSettings == settings,
           appearancePreviewQueuedWidth == previewWidth,
           appearancePreviewQueuedApps == apps,
           appearancePreviewQueuedPID == activePID { return }
        appearancePreviewGenerating = true
        appearancePreviewGeneration += 1
        let generation = appearancePreviewGeneration
        appearancePreviewQueuedSettings = settings
        appearancePreviewQueuedWidth = previewWidth
        let width = previewWidth
        appearancePreviewQueuedApps = apps
        appearancePreviewQueuedPID = activePID
        ThemeResolutionCache.shared.loadAsync(settings.activeThemeID) { [weak self] result in
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishAppearancePreview(generation: generation, settings: settings, width: width,
                                                  apps: apps, activePID: activePID, result: result)
                }
            }
        }
    }

    private func scheduleNotificationPreview(settings: TaskbarSettings) {
        if notificationPreviewGenerating, notificationPreviewQueuedSettings == settings,
           notificationPreviewQueuedWidth == previewWidth { return }
        notificationPreviewGenerating = true
        notificationPreviewGeneration += 1
        let generation = notificationPreviewGeneration
        notificationPreviewQueuedSettings = settings
        notificationPreviewQueuedWidth = previewWidth
        let width = previewWidth
        ThemeResolutionCache.shared.loadAsync(settings.activeThemeID) { [weak self] result in
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishNotificationPreview(generation: generation, settings: settings, width: width, result: result)
                }
            }
        }
    }

    private func finishAppearancePreview(generation: Int, settings: TaskbarSettings, width: CGFloat,
                                         apps: [AppEntry], activePID: pid_t?, result: ThemeLoadResult?) {
        guard generation == appearancePreviewGeneration else { return }
        appearancePreviewGenerating = false
        guard draft == settings, let result else { return }
        Theme.preload(settings.activeThemeID, result: result)
        // Keep the previous strip on screen for this turn; render on the next
        // main-queue pass so a theme-menu dismiss is never blocked by PreviewRenderer.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.appearancePreviewGeneration, self.draft == settings else { return }
            if self.themeCommitInFlight { return }
            let image = PreviewRenderer.stripImage(settings: settings, kind: .appearance,
                                                   apps: apps, activePID: activePID, width: width)
            self.appearancePreviewWidth = width
            self.appearancePreviewSettings = settings
            self.appearancePreviewApps = apps
            self.appearancePreviewPID = activePID
            self.appearancePreviewImage = image
            self.objectWillChange.send()
        }
    }

    private func finishNotificationPreview(generation: Int, settings: TaskbarSettings, width: CGFloat,
                                           result: ThemeLoadResult?) {
        guard generation == notificationPreviewGeneration else { return }
        notificationPreviewGenerating = false
        guard draft == settings, let result else { return }
        Theme.preload(settings.activeThemeID, result: result)
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.notificationPreviewGeneration, self.draft == settings else { return }
            if self.themeCommitInFlight { return }
            let image = PreviewRenderer.stripImage(settings: settings, kind: .notification,
                                                   apps: [], activePID: nil, width: width)
            self.notificationPreviewWidth = width
            self.notificationPreviewSettings = settings
            self.notificationPreviewImage = image
            self.objectWillChange.send()
        }
    }
}

@MainActor
enum PreviewRenderer {
    static let size = NSSize(width: 400, height: 140)
    static let stripWidth: CGFloat = 320
    /// Deterministic preview-row width for Settings reference snapshots.
    static let snapshotPreviewWidth: CGFloat = 620

    /// Preview style of the theme actually shown. User themes report a coarse
    /// family kind (every "modern" theme is .win11), so resolve their real base.
    @MainActor static func previewStyle(_ settings: TaskbarSettings) -> PreviewStyle {
        if let id = settings.userThemeID, let base = UserThemeCatalog.baseKind(id: id) {
            return base.capabilities.previewStyle
        }
        return settings.capabilities.previewStyle
    }

    /// Compact (Win10 search / Win11 acrylic) preview pass, decided from the
    /// real theme's layout rather than the family kind's.
    @MainActor static func usesCompactLayout(_ settings: TaskbarSettings) -> Bool {
        Theme.make(settings).layoutStyle.fixedItems.contains("win10Search") || previewStyle(settings) == .acrylic
    }

    enum StripKind {
        case appearance
        case notification
    }

    static func stripImage(settings: TaskbarSettings, kind: StripKind,
                           apps: [AppEntry], activePID: pid_t?,
                           width requestedWidth: CGFloat? = nil,
                           snapshotTrayLayout: ((TrayView) -> Void)? = nil) -> NSImage {
        // nil = legacy 320pt torn strip (tray snapshot sheets). A width renders the
        // whole taskbar at exactly that width: task buttons, tray and clock included.
        let fullBar = requestedWidth != nil
        let stripWidth = max(160, (requestedWidth ?? Self.stripWidth).rounded(.down))
        let startTheme = Theme.make(settings)
        let overflow = startTheme.startStyle.overflow
        if snapshotTrayLayout != nil { precondition(SnapshotFixture.isActive) }
        var previewSettings = settings
        previewSettings.edge = settings.edge == .top ? .top : .bottom
        if kind == .appearance && Self.previewStyle(settings) == .acrylic && settings.taskbarGrouping != .neverCombine {
            previewSettings.taskbarGrouping = .alwaysCombine
        }
        let thickness = TaskbarView.thickness(for: previewSettings)
        let sourceWidth: CGFloat = fullBar ? stripWidth : 720
        let source = taskbarImage(settings: previewSettings, width: sourceWidth, compactWidth: stripWidth,
                                  apps: kind == .appearance ? previewApps(apps: apps) : [],
                                  activePID: activePID, kind: kind, fullBar: fullBar,
                                  snapshotTrayLayout: snapshotTrayLayout)
        let height = kind == .appearance && settings.capabilities.startButtonOverflow ? thickness + overflow.previewExtraHeight : thickness
        let outputSize = NSSize(width: stripWidth, height: height)
        let output = NSImage(size: outputSize)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(stripWidth * 2),
                                         pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return output }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = NSAffineTransform()
        scale.scale(by: 2)
        scale.concat()
        if kind == .appearance && !fullBar {
            let cut = NSBezierPath()
            cut.move(to: .zero)
            cut.line(to: NSPoint(x: stripWidth - 4, y: 0))
            for y in stride(from: CGFloat(4), through: height, by: 4) {
                cut.line(to: NSPoint(x: stripWidth - (Int(y / 4).isMultiple(of: 2) ? 0 : 6), y: y))
            }
            cut.line(to: NSPoint(x: stripWidth - 4, y: height))
            cut.line(to: NSPoint(x: 0, y: height))
            cut.close()
            cut.addClip()
        }
        let sourceRect: NSRect
        if kind == .appearance {
            sourceRect = NSRect(x: 0, y: 0, width: stripWidth, height: thickness)
        } else {
            sourceRect = NSRect(x: sourceWidth - stripWidth, y: 0, width: stripWidth, height: thickness)
        }
        source.draw(in: NSRect(x: 0, y: 0, width: stripWidth, height: thickness), from: sourceRect,
                    operation: .sourceOver, fraction: 1)
        if kind == .appearance && settings.capabilities.startButtonOverflow {
            let orb = RetroButton(frame: NSRect(x: 0, y: 0, width: overflow.panelWidth,
                                               height: overflow.panelHeight))
            orb.kind = .start
            orb.theme = startTheme
            orb.smoothing = startTheme.layoutStyle.forcedSmoothing || settings.fontSmoothing
            orb.title = L.t(startTheme.startStyle.label.key, settings.resolvedLanguage)
            if SnapshotFixture.isActive { orb.appearance = NSAppearance(named: .aqua) }
            if let orbRep = SnapshotFixture.bitmap(for: orb) {
                orb.cacheDisplay(in: orb.bounds, to: orbRep)
                let orbImage = NSImage(size: orb.bounds.size)
                orbImage.addRepresentation(orbRep)
                orbImage.draw(in: NSRect(x: 0, y: -overflow.panelInset,
                                        width: overflow.panelWidth, height: overflow.panelHeight),
                              from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        rep.size = outputSize
        output.addRepresentation(rep)
        return output
    }

    private static func previewApps(apps: [AppEntry]) -> [AppEntry] {
        if let first = apps.first { return [first] }
        let icon = SnapshotFixture.isActive
            ? NSImage(systemSymbolName: "app", accessibilityDescription: "Winstripe")
            : NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        return [AppEntry(pid: 1, name: "Winstripe", icon: icon, badge: "2", windowCount: 1, isHidden: false)]
    }

    private static func taskbarImage(settings: TaskbarSettings, width: CGFloat, compactWidth: CGFloat,
                                     apps: [AppEntry], activePID: pid_t?, kind: StripKind, fullBar: Bool,
                                     snapshotTrayLayout: ((TrayView) -> Void)?) -> NSImage {
        let barSize = NSSize(width: width, height: TaskbarView.thickness(for: settings))
        let view = TaskbarView(frame: NSRect(origin: .zero, size: barSize))
        if SnapshotFixture.isActive { view.appearance = NSAppearance(named: .aqua) }
        view.isPreview = true
        view.usesStartOverflowPanel = settings.capabilities.startButtonOverflow
        view.settings = settings
        view.apps = apps
        view.activePID = activePID ?? apps.first?.pid
        view.quickLaunchItems = settings.showQuickLaunch
            ? Array(QuickLaunch.items(at: settings.quickLaunchPath).prefix(2))
            : []
        if settings.showQuickLaunch && view.quickLaunchItems.isEmpty {
            view.quickLaunchItems = [URL(fileURLWithPath: "/System/Applications/Calculator.app")]
        }
        view.clockText = Clock.time(settings.resolvedLanguage)
        view.shortDateText = Clock.shortDate()
        view.inputText = InputSource.abbreviation()
        view.reload()
        view.layoutSubtreeIfNeeded()
        if kind == .appearance {
            // Compact only this offscreen instance so the sample task stays visible.
            let layoutStyle = Theme.make(settings).layoutStyle
            if layoutStyle.fixedItems.contains("win10Search") {
                for child in view.subviews where child !== view.startButton && child !== view.tray {
                    if let button = child as? RetroButton, button.kind == .task || button.kind == .quickLaunch {
                        continue
                    }
                    child.isHidden = true
                }
            }
            if Self.usesCompactLayout(settings) {
                let buttons = [view.startButton] + view.subviews.compactMap { $0 as? RetroButton }
                    .filter { $0.kind == .quickLaunch || $0.kind == .task }
                let widths = buttons.map { button -> CGFloat in
                    button.kind == .task && !button.title.isEmpty ? 140 : 40
                }
                let total = widths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 4
                var x: CGFloat = layoutStyle.alignmentOptions.contains("center") && settings.alignment == .center
                    ? max(4, (compactWidth - total) / 2) : 4
                for (index, button) in buttons.enumerated() {
                    button.frame = NSRect(x: x, y: (barSize.height - 40) / 2,
                                          width: widths[index], height: 40)
                    button.isHidden = false
                    x += widths[index] + 4
                }
            }
            // Full-width Appearance preview: Start + Quick Launch/task area only.
            if fullBar { view.tray.isHidden = true }
        } else {
            view.tray.showDesktop = settings.showDesktopButton
            view.tray.frame.origin.x = width - view.tray.frame.width
            view.tray.arrange()
            // Full-width Notification preview: right-aligned tray + clock only.
            if fullBar {
                for child in view.subviews where child !== view.tray { child.isHidden = true }
            }
        }
        snapshotTrayLayout?(view.tray)
        guard let rep = SnapshotFixture.bitmap(for: view) else {
            return NSImage(size: barSize)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: barSize)
        image.addRepresentation(rep)
        return image
    }

    /// Renders a small "desktop" with the taskbar (as configured by `settings`) at its edge.
    static func image(settings: TaskbarSettings, apps: [AppEntry], activePID: pid_t?) -> NSImage {
        let vertical = settings.edge.isVertical
        let startTheme = Theme.make(settings)
        let overflow = startTheme.startStyle.overflow
        let wallpaper = startTheme.startStyle.wallpaper
        let barSize = vertical ? NSSize(width: TaskbarView.verticalWidth(for: settings), height: size.height)
            : NSSize(width: size.width, height: TaskbarView.thickness(for: settings))
        let view = TaskbarView(frame: NSRect(origin: .zero, size: barSize))
        if SnapshotFixture.isActive { view.appearance = NSAppearance(named: .aqua) }
        view.isPreview = true
        view.usesStartOverflowPanel = settings.capabilities.startButtonOverflow && !vertical
        view.settings = settings
        view.apps = Array(apps.prefix(vertical ? 3 : 2))
        view.activePID = activePID
        view.quickLaunchItems = settings.showQuickLaunch ? Array(QuickLaunch.items(at: settings.quickLaunchPath).prefix(4)) : []
        view.clockText = Clock.time(settings.resolvedLanguage)
        view.shortDateText = Clock.shortDate()
        view.inputText = InputSource.abbreviation()
        view.reload()

        let out = NSImage(size: size)
        guard let barRep = SnapshotFixture.bitmap(for: view),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return out }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return out }
        view.cacheDisplay(in: view.bounds, to: barRep)
        let barImage = NSImage(size: barSize)
        barImage.addRepresentation(barRep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let scale = NSAffineTransform()   // context starts in pixel units; draw in points at 2x
        scale.scale(by: 2)
        scale.concat()
        if wallpaper != "none" { AeroDrawing.wallpaper(NSRect(origin: .zero, size: size), vista: wallpaper == "vista") }
        else {
            NSColor(hex: 0x008080).setFill()   // classic teal desktop
            NSRect(origin: .zero, size: size).fill()
        }
        var barRect = NSRect(origin: .zero, size: barSize)   // unflipped coordinates here
        switch settings.edge {
        case .bottom: barRect.origin = .zero
        case .top: barRect.origin = NSPoint(x: 0, y: size.height - barSize.height)
        case .left: barRect.origin = .zero
        case .right: barRect.origin = NSPoint(x: size.width - barSize.width, y: 0)
        }
        barImage.draw(in: barRect, from: .zero, operation: .sourceOver, fraction: 1)
        if settings.capabilities.startButtonOverflow && !vertical {
            let orb = RetroButton(frame: NSRect(x: 0, y: 0, width: overflow.panelWidth, height: overflow.panelHeight))
            orb.kind = .start
            orb.theme = startTheme
            orb.smoothing = startTheme.layoutStyle.forcedSmoothing || settings.fontSmoothing
            orb.title = L.t(startTheme.startStyle.label.key, settings.resolvedLanguage)
            if SnapshotFixture.isActive { orb.appearance = NSAppearance(named: .aqua) }
            if let orbRep = SnapshotFixture.bitmap(for: orb) {
                orb.cacheDisplay(in: orb.bounds, to: orbRep)
                let image = NSImage(size: orb.bounds.size)
                image.addRepresentation(orbRep)
                image.draw(in: NSRect(x: 0, y: settings.edge == .bottom ? -overflow.panelInset
                                          : size.height + overflow.panelInset - overflow.panelHeight,
                                      width: overflow.panelWidth, height: overflow.panelHeight), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        out.addRepresentation(rep)
        return out
    }
}

struct PropertiesView: View {
    static let sectionIdentifiers = ["section.general", "section.language", "section.permissions", "section.appearance",
                                     "section.taskbar", "section.tray", "section.windows", "section.hiddenItems", "section.advanced"]
    static let settingIdentifiers = ["setting.launchAtLogin", "setting.language", "setting.permission.accessibility",
                                    "setting.permission.screenRecording", "setting.permission.refresh", "setting.theme", "setting.startMenu",
                                    "setting.theme.import", "setting.theme.export", "setting.theme.folder", "setting.win8StartColor",
                                    "setting.edge", "setting.alignment", "setting.grouping", "setting.fontSmoothing", "setting.locked",
                                    "setting.autoHide", "setting.showBadges", "setting.quickLaunch",
                                    "setting.quickLaunch.folder",
                                    "setting.windowPreviews", "setting.clock", "setting.inputLanguage",
                                    "setting.showDesktop", "setting.collapseTray", "setting.trayCustomize",
                                    "setting.allDisplays", "setting.debugLogging", "setting.reset"]
    @ObservedObject var model: PropertiesModel
    var showStartMenuRow = true
    var initialTab = 0
    var snapshotFullContent = false
    @State private var showingTrayCustomize = false
    @StateObject private var themeMenuCache = ThemePopupMenuCache()
    @StateObject private var hiddenItems = HiddenItemsModel()

    private func t(_ key: String) -> String { L.t(key, model.draft.resolvedLanguage) }

    var body: some View {
        Group {
            if snapshotFullContent {
                VStack(alignment: .leading, spacing: 0) {
                    generalSection
                    languageSection
                    permissionsSection
                    appearanceSection
                    taskbarSection
                    traySection
                    windowsSection
                    hiddenSection
                    advancedSection
                    SettingsFooterBar(quitLabel: t("Quit Winstripe"), settingsLabel: t("Settings"),
                                      aboutLabel: t("About"), sourceCodeLabel: t("View Source Code"),
                                      checkForUpdatesLabel: t("Check for Updates…"))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 620, alignment: .topLeading)
                .toggleStyle(SettingsSnapshotToggleStyle())
            } else {
                if #available(macOS 13.0, *) {
                    Form {
                        generalSection
                        languageSection
                        permissionsSection
                        appearanceSection
                        taskbarSection
                        traySection
                        windowsSection
                        hiddenSection
                        advancedSection
                        // Trailing space inside the scroll content so the last row clears the floating
                        // bar at full scroll. The grouped Form ignores NSScrollView content insets, and
                        // safeAreaInset would shrink the scroll view (leaving nothing behind the blur).
                        Section {} footer: {
                            Color.clear.frame(height: SettingsFooterBar.formTrailingSpace).accessibilityHidden(true)
                        }
                    }
                    .formStyle(.grouped)
                    .background(BottomScrollInset(inset: SettingsFooterBar.height))
                    .overlay(SettingsFooterBar(quitLabel: t("Quit Winstripe"), settingsLabel: t("Settings"),
                                              aboutLabel: t("About"), sourceCodeLabel: t("View Source Code"),
                                              checkForUpdatesLabel: t("Check for Updates…")), alignment: .bottom)
                    .frame(minWidth: 600, idealWidth: 620, minHeight: 700, idealHeight: 820)
                } else {
                    // macOS 11 and 12 do not provide the grouped Form style.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            GroupBox { generalSection }
                            GroupBox { languageSection }
                            GroupBox { permissionsSection }
                            GroupBox { appearanceSection }
                            GroupBox { taskbarSection }
                            GroupBox { traySection }
                            GroupBox { windowsSection }
                            GroupBox { hiddenSection }
                            GroupBox { advancedSection }
                        }
                        .padding(12)
                        .padding(.bottom, SettingsFooterBar.height)
                    }
                    .overlay(SettingsFooterBar(quitLabel: t("Quit Winstripe"), settingsLabel: t("Settings"),
                                              aboutLabel: t("About"), sourceCodeLabel: t("View Source Code"),
                                              checkForUpdatesLabel: t("Check for Updates…")), alignment: .bottom)
                    .frame(minWidth: 600, idealWidth: 620, minHeight: 700, idealHeight: 820)
                }
            }
        }
        .sheet(isPresented: $showingTrayCustomize) {
            TrayAppsCustomizeView(model: model)
        }
    }

    private var generalSection: some View {
        Section {
            LaunchAtLogin.Toggle(t("Launch at login"))
                .accessibilityIdentifier("setting.launchAtLogin")
        } header: {
            Text(t("General")).accessibilityIdentifier("section.general")
        }
    }

    private var languageSection: some View {
        Section { Picker(t("Language"), selection: pickerBinding(
            get: { model.draft.language },
            set: { model.draft.language = $0 })) {
            ForEach(Language.allCases) { language in
                Text(language == .system ? L.t("System", model.draft.resolvedLanguage) : language.rawValue).tag(language)
            }
        }.accessibilityIdentifier("setting.language") } header: {
            Text(t("Language")).accessibilityIdentifier("section.language")
        }
    }

    private var permissionsSection: some View {
        Section { permissionRow("Accessibility", granted: model.accessibilityGranted,
                               help: PermissionHelpButton(title: t("AccessibilityHelpTitle"), body: t("AccessibilityHelpBody"),
                                                          identifier: "setting.permission.accessibility.help"),
                               request: { model.requestAccessibility() },
                               open: { model.openAccessibilitySettings() })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("setting.permission.accessibility")
            permissionRow("Screen Recording", granted: model.screenRecordingGranted,
                          help: PermissionHelpButton(title: t("ScreenRecordingHelpTitle"), body: t("ScreenRecordingHelpBody"),
                                                     identifier: "setting.permission.screenRecording.help"),
                          request: { model.requestScreenRecording() },
                          open: { model.openScreenRecordingSettings() })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setting.permission.screenRecording")
        } header: {
            HStack {
                Text(t("Permissions")).accessibilityIdentifier("section.permissions")
                Spacer()
                Button {
                    model.refreshPermissions()
                } label: {
                    Label(t("Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("setting.permission.refresh")
            }
        }
    }

    private var appearanceSection: some View {
        Section { preview(model.appearancePreview())
            let menu = themeMenuCache.menu(language: model.draft.resolvedLanguage,
                                           selection: model.draft.activeThemeID,
                                           userThemes: model.userThemes)
            if #available(macOS 13.0, *) {
                LabeledContent(t("Theme")) {
                    ThemePopUpButton(menuModel: menu, selection: model.draft.activeThemeID, onSelect: setTheme)
                        // Fixed size so selecting a longer/shorter theme name cannot
                        // invalidate the surrounding Form layout during menu dismiss.
                        .fixedSize()
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .trailing)
                }.accessibilityIdentifier("setting.theme")
            } else {
                HStack {
                    Text(t("Theme"))
                    Spacer(minLength: 8)
                    ThemePopUpButton(menuModel: menu, selection: model.draft.activeThemeID, onSelect: setTheme)
                        .fixedSize()
                        .frame(minHeight: 24, alignment: .trailing)
                }.accessibilityIdentifier("setting.theme")
            }
            HStack { Button(t("Import…")) { model.importTheme() }.accessibilityIdentifier("setting.theme.import")
                Button(t("Export…")) { model.exportTheme() }.accessibilityIdentifier("setting.theme.export")
                Button(t("Open Themes Folder")) { model.openThemesFolder() }.accessibilityIdentifier("setting.theme.folder") }
            if let warning = model.themeWarning { Text(t("Theme failed to load: %@").replacingOccurrences(of: "%@", with: warning)).font(.caption).foregroundColor(.orange) }
            if showStartMenuRow { Picker(t("Start menu"), selection: pickerBinding(
                get: { model.draft.startMenuStyleChoice?.rawValue ?? "__default__" },
                set: { model.draft.startMenuStyleChoice = $0 == "__default__" ? nil : StartMenuStyle(rawValue: $0) })) {
                    Text(t("Theme default (%@)").replacingOccurrences(of: "%@", with: t(model.draft.theme.defaultStartMenu.displayName))).tag("__default__")
                    ForEach(StartMenuStyle.allCases, id: \.rawValue) { Text(t($0.displayName)).tag($0.rawValue) }
            }.accessibilityIdentifier("setting.startMenu") }
            if model.themeCapabilities.usesWin8StartColor || model.draft.startMenuStyle == .win8 {
                Picker(t("Start screen color"), selection: pickerBinding(
                    get: { model.draft.win8StartColor },
                    set: { model.draft.win8StartColor = $0 })) {
                    ForEach(Win8Drawing.accents, id: \.value) { Text(t($0.name)).tag($0.value) }
                }.accessibilityIdentifier("setting.win8StartColor")
            }
        } header: { Text(t("Appearance")).accessibilityIdentifier("section.appearance") }
    }

    private var taskbarSection: some View {
        Section {
            Picker(t("Location"), selection: pickerBinding(
                get: { model.draft.edge },
                set: { model.draft.edge = $0 })) { ForEach(TaskbarEdge.allCases) { Text(t($0.titleKey)).tag($0) } }.accessibilityIdentifier("setting.edge")
            if model.themeCapabilities.layoutStyle.alignmentOptions.count > 1 {
                Picker(t("Taskbar alignment"), selection: pickerBinding(
                    get: { model.draft.alignment },
                    set: { model.draft.alignment = $0 })) { ForEach(TaskbarAlignment.allCases) { Text(t($0.rawValue)).tag($0) } }.accessibilityIdentifier("setting.alignment")
            }
            Picker(t("Taskbar buttons"), selection: pickerBinding(
                get: { model.draft.taskbarGrouping },
                set: { model.draft.taskbarGrouping = $0 })) {
                ForEach(TaskbarGrouping.allCases) { Text(t($0 == .alwaysCombine ? "Always combine" : $0 == .combineWhenFull ? "Combine when full" : "Never combine")).tag($0) }
            }.accessibilityIdentifier("setting.grouping")
            Toggle(t("Allow font smoothing"), isOn: model.themeCapabilities.layoutStyle.forcedSmoothing ? .constant(true) : $model.draft.fontSmoothing).disabled(model.themeCapabilities.layoutStyle.forcedSmoothing).accessibilityIdentifier("setting.fontSmoothing")
            Toggle(t("Lock the taskbar"), isOn: $model.draft.locked).accessibilityIdentifier("setting.locked")
            Toggle(t("Auto-hide the taskbar"), isOn: $model.draft.autoHide).accessibilityIdentifier("setting.autoHide")
            Toggle(t("Show badges"), isOn: $model.draft.showBadges).accessibilityIdentifier("setting.showBadges")
            Toggle(t("Show taskbar on all displays"), isOn: $model.draft.allDisplays).accessibilityIdentifier("setting.allDisplays")
            Text(t("MultiHelp")).font(.caption).foregroundColor(.secondary)
            HStack { Toggle(t("Show Quick Launch"), isOn: $model.draft.showQuickLaunch).accessibilityIdentifier("setting.quickLaunch")
                Spacer(); Button(t("Select location…")) { model.chooseQuickLaunchFolder() }.accessibilityIdentifier("setting.quickLaunch.folder") }
            if !model.draft.quickLaunchPath.isEmpty { Text(model.draft.quickLaunchPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) }
        } header: { Text(t("Taskbar")).accessibilityIdentifier("section.taskbar") }
    }

    private var traySection: some View {
        Section {
            preview(model.notificationPreview())
            Toggle(t("Show the clock"), isOn: $model.draft.showClock).accessibilityIdentifier("setting.clock")
            Toggle(t("Show the input language"), isOn: $model.draft.showInputLanguage).accessibilityIdentifier("setting.inputLanguage")
            Toggle(t("Add the Show Desktop button"), isOn: $model.draft.showDesktopButton).accessibilityIdentifier("setting.showDesktop")
            HStack { Toggle(t("Collapse notification area icons"), isOn: $model.draft.collapseTrayIcons).accessibilityIdentifier("setting.collapseTray")
                Spacer(); Button(t("Customize…")) { showingTrayCustomize = true }.disabled(!model.draft.collapseTrayIcons).accessibilityIdentifier("setting.trayCustomize") }
            Text(t("BadgesHelp")).font(.caption).foregroundColor(.secondary)
            Text(t("Badge counts need Accessibility")).font(.caption).foregroundColor(.secondary)
        } header: { Text(t("Notification area")).accessibilityIdentifier("section.tray") }
    }

    private var windowsSection: some View {
        Section {
            Toggle(t("Show window previews (thumbnails)"), isOn: $model.draft.showWindowPreviews).accessibilityIdentifier("setting.windowPreviews")
            if !model.accessibilityGranted { Text(t("Per-window buttons require Accessibility permission.")).font(.caption).foregroundColor(.secondary) }
            Text(t("PreviewsHelp")).font(.caption).foregroundColor(.secondary)
        } header: { Text(t("Windows and previews")).accessibilityIdentifier("section.windows") }
    }

    private var hiddenSection: some View {
        Section {
            if hiddenItems.entries.isEmpty {
                Text(t("No hidden apps or folders")).foregroundColor(.secondary).accessibilityIdentifier("setting.hidden.empty")
            } else {
                ForEach(hiddenItems.entries, id: \.rowID) { entry in
                    HStack {
                        Image(nsImage: hiddenItems.icon(for: entry)).resizable().frame(width: 16, height: 16)
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        Button(t("Show")) { HiddenStore().show(entry) }
                    }
                }
                HStack {
                    Spacer()
                    Button(t("Show All")) { HiddenStore().showAll() }.accessibilityIdentifier("setting.hidden.showAll")
                }
            }
            Text(t("HiddenItemsHelp")).font(.caption).foregroundColor(.secondary)
        } header: { Text(t("Hidden apps and folders")).accessibilityIdentifier("section.hiddenItems") }
    }

    private var advancedSection: some View {
        Section {
            Toggle(t("Enable debug logging"), isOn: $model.draft.debugLogging).accessibilityIdentifier("setting.debugLogging")
            Button(t("Reset to defaults")) { model.resetToDefaults() }.accessibilityIdentifier("setting.reset")
        } header: { Text(t("Advanced")).accessibilityIdentifier("section.advanced") }
    }

    private func permissionRow(_ key: String, granted: Bool, help: PermissionHelpButton,
                               request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(granted ? Color.green : Color.orange).frame(width: 8, height: 8)
            HStack(spacing: 4) {
                Text(t(key))
                help.fixedSize().accessibilityIdentifier(help.identifier)
            }
            Text(granted ? t("Granted") : t("Not granted")).foregroundColor(.secondary)
            Spacer()
            if !granted { Button(t("Request…"), action: request) }
            Button(t("Open System Settings"), action: open)
        }
    }

    private func setTheme(_ value: String) {
        model.commitThemeSelection(value)
    }

    private func pickerBinding<Value>(get: @escaping () -> Value,
                                     set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get) { value in
            deferPickerMutation { set(value) }
        }
    }

    private func deferPickerMutation(_ mutation: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.default], block: mutation)
    }

    private func preview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .interpolation(.none)
            // Natural size, never stretched; the model re-renders at the row width.
            .frame(maxWidth: .infinity, minHeight: image.size.height, maxHeight: image.size.height, alignment: .leading)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { model.setPreviewWidth(geometry.size.width) }
                    .modifier(PreviewWidthChangeModifier(width: geometry.size.width,
                                                          onChange: model.setPreviewWidth))
            })
            .clipped()
            .overlay(Rectangle().stroke(Color.gray.opacity(0.65), lineWidth: 1))
            .padding(.bottom, 2)
    }
}

private struct PreviewWidthChangeModifier: ViewModifier {
    let width: CGFloat
    let onChange: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            content.onChange(of: width) { _, newValue in onChange(newValue) }
        } else if #available(macOS 13.0, *) {
            content.onChange(of: width) { newValue in onChange(newValue) }
        } else {
            content
        }
        #else
        if #available(macOS 13.0, *) {
            content.onChange(of: width) { newValue in onChange(newValue) }
        } else {
            content
        }
        #endif
    }
}

private struct SettingsSnapshotToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
                RoundedRectangle(cornerRadius: 10)
                    .fill(configuration.isOn ? Color.accentColor : Color(.quaternaryLabelColor))
                    .frame(width: 36, height: 20)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.4)
                            .offset(x: configuration.isOn ? 8 : -8),
                        alignment: .center)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct TrayAppsCustomizeView: View {
    @ObservedObject var model: PropertiesModel
    @State private var selection: String?
    @Environment(\.presentationMode) private var presentationMode

    private var language: Language { model.draft.language }
    private func t(_ key: String) -> String { L.t(key, language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Notification area apps")).font(.headline)
            List(selection: $selection) {
                ForEach(model.draft.trayApps, id: \.self) { path in
                    let info = TrayAppInfo.resolve(path)
                    HStack(spacing: 8) {
                        Image(nsImage: info?.icon ?? NSWorkspace.shared.icon(forFile: path))
                            .resizable().interpolation(.none).frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Toggle(t("Always show"), isOn: alwaysShowBinding(for: path))
                            .toggleStyle(.checkbox)
                    }
                    .tag(path as String?)
                }
            }
            HStack {
                Button(t("Add…")) { add() }
                Button(t("Remove")) { remove() }.disabled(selection == nil)
                Spacer()
                Button(t("Move Up")) { move(-1) }.disabled(selection == nil)
                Button(t("Move Down")) { move(1) }.disabled(selection == nil)
                Button(t("Close")) { presentationMode.wrappedValue.dismiss() }
            }
        }
        .padding(12)
        .frame(width: 560, height: 330)
        .background(Color(.windowBackgroundColor))
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        var updated = model.draft
        var paths = updated.trayApps
        for url in panel.urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame, !paths.contains(path) else { continue }
            paths.append(path)
        }
        updated.trayApps = paths
        model.draft = updated
    }

    private func remove() {
        guard let selection else { return }
        var updated = model.draft
        updated.trayApps.removeAll { $0 == selection }
        updated.trayAppsAlwaysShow.removeAll { $0 == selection }
        model.draft = updated
        self.selection = nil
    }

    private func move(_ offset: Int) {
        guard let selection, let index = model.draft.trayApps.firstIndex(of: selection) else { return }
        let target = index + offset
        guard model.draft.trayApps.indices.contains(target) else { return }
        var updated = model.draft
        updated.trayApps.swapAt(index, target)
        model.draft = updated
    }

    private func alwaysShowBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { model.draft.trayAppsAlwaysShow.contains(path) },
            set: { value in
                var updated = model.draft
                if value {
                    if !updated.trayAppsAlwaysShow.contains(path) { updated.trayAppsAlwaysShow.append(path) }
                } else {
                    updated.trayAppsAlwaysShow.removeAll { $0 == path }
                }
                model.draft = updated
            })
    }
}

@MainActor
private final class PropertiesLiveSelfTestStore: PropertiesStoreTarget {
    private(set) var current = TaskbarSettings()
    private(set) var updates: [TaskbarSettings] = []

    func update(_ new: TaskbarSettings) {
        current = new
        updates.append(new)
    }
}

@MainActor
enum PropertiesLiveSelfTest {
    static func run() -> Int {
        let store = PropertiesLiveSelfTestStore()
        let model = PropertiesModel(store: store)
        model.draft.theme = .win10
        model.draft.edge = .top
        model.draft.showQuickLaunch = true
        model.draft.language = .chinese

        let host = NSHostingView(rootView: PropertiesView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 820)
        host.layoutSubtreeIfNeeded()
        let buttons = buttons(in: host)
        let hasCloseButton = buttons.contains { $0.title == L.t("Close", .english) }
        let scrollCount = scrollViews(in: host).count
        let changesAreImmediate = store.updates.count == 4 &&
            store.updates[0].theme == .win10 &&
            store.updates[1].edge == .top &&
            store.updates[2].showQuickLaunch &&
            store.updates[3].language == .chinese
        guard changesAreImmediate, !hasCloseButton, scrollCount == 1,
              PropertiesView.sectionIdentifiers == ["section.general", "section.language", "section.permissions", "section.appearance",
                                                    "section.taskbar", "section.tray", "section.windows", "section.hiddenItems", "section.advanced"],
              PropertiesView.settingIdentifiers.count >= 21 else {
            fputs("properties live selftest failed: updates=\(store.updates.count) close=\(hasCloseButton) scrolls=\(scrollCount) sections=\(PropertiesView.sectionIdentifiers) settings=\(PropertiesView.settingIdentifiers.count)\n", stderr)
            return 1
        }
        print("PASS")
        return 0
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview in
            let own = (subview as? NSButton).map { [$0] } ?? []
            return own + buttons(in: subview)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

@MainActor
enum ThemeSwitchBench {
    static func run() -> Int {
        let store = PropertiesLiveSelfTestStore()
        let model = PropertiesModel(store: store)
        var failed = false
        var maximum = 0.0
        for kind in ThemeKind.allCases {
            ThemeResolutionCache.shared.clearForBenchmark()
            Theme.clearCachesForBenchmark()
            var updated = model.draft
            updated.userThemeID = nil
            updated.theme = kind
            let start = DispatchTime.now().uptimeNanoseconds
            model.draft = updated
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            maximum = max(maximum, elapsed)
            let formatted = String(format: "%.3f", elapsed)
            print("theme-switch \(kind.id) main_ms=\(formatted)")
            // Draft assignment is synchronous; apply/theme load may continue async.
            // Treat a published draft change as success for this main-thread stall bench.
            if model.draft.activeThemeID != kind.id { failed = true }
        }
        let formattedMaximum = String(format: "%.3f", maximum)
        print("theme-switch max_main_ms=\(formattedMaximum)")
        if !failed { print("PASS bench-theme-switch") }
        return failed ? 1 : 0
    }
}

struct ThemeMenuSnapshotView: View {
    let menu: ThemePopupMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group(menu.builtIn)
            if let user = menu.user {
                Divider().padding(.vertical, 5)
                group(user)
            }
        }
        .padding(8)
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private func group(_ group: ThemePopupGroup) -> some View {
        Text(group.title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.bottom, 2)
        ForEach(group.items) { item in
            HStack(spacing: 6) {
                Text(item.selected ? "✓" : "")
                    .frame(width: 12, alignment: .center)
                Text(item.title)
                Spacer(minLength: 12)
            }
            .font(.body)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
        }
    }
}

@MainActor
private final class PropertiesWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let commandW = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command &&
            event.charactersIgnoringModifiers?.lowercased() == "w"
        if commandW {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PropertiesWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    let model = PropertiesModel()
    private var languageObserver: AnyCancellable?

    override init() {
        super.init()
        model.onClose = { [weak self] in self?.window?.close() }
        // Live language switch: the SwiftUI content rebuilds itself; the AppKit
        // window title has to follow too.
        languageObserver = model.$draft
            .map(\.resolvedLanguage)
            .removeDuplicates()
            .sink { [weak self] language in
                self?.window?.title = L.t("Winstripe Settings", language)
            }
    }

    func show() {
        ThemeResolutionCache.shared.prewarmBuiltIns()
        model.draft = SettingsStore.shared.current
        model.refreshPermissions()
        if window == nil {
            let host = NSHostingController(rootView: PropertiesView(model: model))
            let w = PropertiesWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            // Unified titlebar: an empty toolbar gives a real titlebar/toolbar area above the content
            // (no full-size content view, so nothing scrolls under it), with the standard title.
            let toolbar = NSToolbar(identifier: "WinstripeSettingsToolbar")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            w.toolbar = toolbar
            w.toolbarStyle = .unified
            w.titleVisibility = .visible
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            // Screenshot aid: `--settings-appearance light|dark` forces this window's appearance.
            if let i = CommandLine.arguments.firstIndex(of: "--settings-appearance"), i + 1 < CommandLine.arguments.count {
                w.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
            }
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.level = .normal
            w.minSize = NSSize(width: 600, height: 620)
            w.center()
            window = w
        }
        window?.title = L.t("Winstripe Settings", model.draft.resolvedLanguage)
        model.startPermissionMonitoring()
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.orderFrontRegardless()
        window.makeKey()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.startPermissionMonitoring()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPermissionMonitoring()
    }
}
