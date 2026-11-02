import AppKit

@MainActor
struct TrayAppInfo: Equatable {
    let path: String
    let name: String
    let bundleID: String?
    let icon: NSImage

    static func resolve(_ path: String) -> TrayAppInfo? {
        let input = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if let parsed = URL(string: input), parsed.isFileURL {
            url = parsed.standardizedFileURL.resolvingSymlinksInPath()
        } else if !input.contains("/"),
                  let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: input) {
            url = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            url = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        }
        let normalized = url.path
        let fixtureName = url.deletingPathExtension().lastPathComponent
        let fixtureApp = SnapshotFixture.isActive ? SnapshotFixture.catalog.first { $0.name == fixtureName } : nil
        guard fixtureApp != nil || (url.pathExtension.caseInsensitiveCompare("app") == .orderedSame &&
                                    FileManager.default.fileExists(atPath: normalized)) else { return nil }
        let bundle = Bundle(url: url)
        let name = fixtureApp?.name ?? bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: normalized).replacingOccurrences(of: ".app", with: "")
        let sourceIcon = fixtureApp?.icon ?? NSWorkspace.shared.icon(forFile: normalized)
        let icon: NSImage
        if let copy = sourceIcon.copy() as? NSImage {
            copy.isTemplate = false
            icon = copy
        } else {
            icon = sourceIcon
        }
        return TrayAppInfo(path: normalized, name: name, bundleID: bundle?.bundleIdentifier, icon: icon)
    }

    func activate() {
        guard !SnapshotFixture.isActive else { return }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == normalized
        }) {
            running.activate(options: [.activateAllWindows])
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: normalized), configuration: NSWorkspace.OpenConfiguration())
    }
}

enum TrayBadgeLayout {
    static let minimumTextFontSize: CGFloat = 6.5
    static let horizontalPadding: CGFloat = 3

    enum Content: Equatable {
        case text(String)
        case dot
    }

    static func content(for label: String?) -> Content? {
        guard let label, !label.isEmpty else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "99+" { return .text("99+") }
        if let value = Int(trimmed) {
            if value == 0 { return nil }
            return .text(value > 99 ? "99+" : String(value))
        }
        return .dot
    }

    static func iconRect(in cellRect: NSRect, iconSize: CGFloat) -> NSRect {
        let size = min(iconSize, min(cellRect.width, cellRect.height))
        return NSRect(x: floor(cellRect.midX - size / 2), y: floor(cellRect.midY - size / 2),
                      width: size, height: size)
    }

    static func font(for cellRect: NSRect, label: String?, baseFont: NSFont) -> NSFont {
        guard case .text(let text) = content(for: label) else { return baseFont }
        var size = baseFont.pointSize
        while size > minimumTextFontSize {
            let font = baseFont.withSize(size)
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            if width + horizontalPadding <= cellRect.width { return font }
            size = max(minimumTextFontSize, size - 0.25)
        }
        return baseFont.withSize(size)
    }

    static func rect(for cellRect: NSRect, iconRect: NSRect, label: String?, font: NSFont) -> NSRect? {
        guard let content = content(for: label) else { return nil }
        let text: String = {
            if case .text(let value) = content { return value }
            return ""
        }()
        let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding
        let size = min(7, cellRect.width, cellRect.height)
        let width = content == .dot ? size : measuredWidth
        let height = content == .dot
            ? size
            : min(max(7, ceil(font.pointSize + 1)), max(7, iconRect.height - 3), cellRect.height)
        let x = max(iconRect.minX - 2, cellRect.minX)
        let maxY = min(max(iconRect.maxY + 2, cellRect.minY + height), cellRect.maxY)
        return NSRect(x: x, y: maxY - height, width: width, height: height)
    }

    static func rect(for iconRect: NSRect, label: String?, font: NSFont) -> NSRect? {
        rect(for: iconRect, iconRect: iconRect, label: label, font: font)
    }
}
