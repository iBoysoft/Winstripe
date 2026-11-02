import AppKit

@MainActor
enum Dialogs {
    static func activate() {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        #else
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    /// Win95-style "Run" dialog: opens an app name, bundle id, path, or URL.
    static func run(lang: Language) {
        activate()
        let alert = NSAlert()
        alert.messageText = L.t("Run", lang)
        alert.informativeText = L.t("RunPrompt", lang)
        alert.icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Safari, ~/Documents, https://example.com"
        field.stringValue = Prefs.defaults.string(forKey: "lastRunCommand") ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L.t("OK", lang))
        alert.addButton(withTitle: L.t("Cancel", lang))
        alert.addButton(withTitle: L.t("Browse…", lang))
        alert.window.initialFirstResponder = field
        alert.window.level = .modalPanel
        let response = alert.runModal()

        if response == .alertThirdButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            if panel.runModal() == .OK, let url = panel.url { NSWorkspace.shared.open(url) }
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Prefs.defaults.set(text, forKey: "lastRunCommand")
        if !open(text) {
            let err = NSAlert()
            err.alertStyle = .warning
            err.messageText = text
            err.informativeText = String(format: L.t("CannotFind", lang), text)
            err.runModal()
        }
    }

    static func open(_ text: String) -> Bool {
        let fm = FileManager.default
        if !text.hasPrefix("/"), !text.hasPrefix("~"), let url = URL(string: text),
           let scheme = url.scheme, scheme.count > 1 {
            return NSWorkspace.shared.open(url)
        }
        let path = (text as NSString).expandingTildeInPath
        if fm.fileExists(atPath: path) {
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        let name = text.lowercased().hasSuffix(".app") ? text : text + ".app"
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let p = dir + "/" + name
            if fm.fileExists(atPath: p) { return NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) {
            return NSWorkspace.shared.open(appURL)
        }
        if text.contains("."), !text.contains(" "), let url = URL(string: "https://" + text) {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    static func confirmShutDown(lang: Language) -> Bool {
        activate()
        let alert = NSAlert()
        alert.messageText = L.t("Shut Down Winstripe", lang)
        alert.informativeText = L.t("ShutDownPrompt", lang)
        alert.icon = NSImage(systemSymbolName: "power.circle", accessibilityDescription: nil)
        alert.addButton(withTitle: L.t("Yes", lang))
        alert.addButton(withTitle: L.t("No", lang))
        alert.window.level = .modalPanel
        return alert.runModal() == .alertFirstButtonReturn
    }
}
