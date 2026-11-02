import AppKit

/// Debug aid: `--appearance-preview-dump DIR` renders the Settings Appearance
/// strip for every built-in and user theme (left + center alignment). Read-only.
@MainActor
enum AppearancePreviewDump {
    static func run(directory: String) -> Int {
        _ = NSApplication.shared
        let base = SettingsStore.load(from: Prefs.defaults)
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ids = ThemeKind.allCases.map(\.id)
        ids += UserThemeCatalog.records().0.map(\.id)
        for id in ids {
            for alignment in [TaskbarAlignment.left, .center] {
                var s = base
                if let kind = ThemeKind(themeID: id) { s.userThemeID = nil; s.theme = kind }
                else { s.userThemeID = id; s.theme = UserThemeCatalog.familyKind(id: id) }
                s.alignment = alignment
                let image = PreviewRenderer.stripImage(settings: s, kind: .appearance, apps: [], activePID: nil, width: 620)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: out.appendingPathComponent("\(id)-\(alignment.rawValue.lowercased()).png"))
            }
        }
        print("DONE \(ids.count) themes")
        return 0
    }
}
