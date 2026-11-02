import AppKit
import SwiftUI

/// The Settings footer: "Winstripe" with one color per letter, then the bundle version in the
/// normal secondary color. Colors adapt: deeper shades on light backgrounds, brighter on dark.
enum Wordmark {
    static let name = "Winstripe"

    /// (light, dark) sRGB pairs: red, orange, gold, green, teal, blue, indigo, purple, magenta.
    private static let palette: [(UInt32, UInt32)] = [
        (0xD32F2F, 0xFF6B6B), (0xE65100, 0xFFA040), (0xB8860B, 0xFFD54F),
        (0x2E7D32, 0x66D97A), (0x00838F, 0x4DD8E6), (0x1565C0, 0x64A8FF),
        (0x3949AB, 0x8C9EFF), (0x7B1FA2, 0xCE93D8), (0xC2185B, 0xFF80AB),
    ]

    static func color(at index: Int) -> NSColor {
        let pair = palette[index % palette.count]
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            return rgb(dark ? pair.1 : pair.0)
        }
    }

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// "1.0.0" -> "1.0": trailing zero components past major.minor are dropped.
    static func displayVersion(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "1.0" }
        var parts = raw.split(separator: ".").map(String.init)
        while parts.count > 2, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    static var bundleVersion: String {
        displayVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    static func attributed(version: String = bundleVersion,
                           size: CGFloat = NSFont.preferredFont(forTextStyle: .caption1).pointSize) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bold = NSFont.systemFont(ofSize: size, weight: .bold)
        for (i, ch) in name.enumerated() {
            result.append(NSAttributedString(string: String(ch), attributes: [.font: bold, .foregroundColor: color(at: i)]))
        }
        result.append(NSAttributedString(string: " " + version, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }
}

/// SwiftUI host for the attributed wordmark (Text(AttributedString) needs macOS 12).
struct WordmarkLabel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: Wordmark.attributed())
        field.setAccessibilityIdentifier("settings.footer")
        field.setAccessibilityLabel("\(Wordmark.name) \(Wordmark.bundleVersion)")
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = Wordmark.attributed()
    }
}

/// Bottom bar of the Settings window: wordmark on the left, settings menu, and Quit on the right. In the live window
/// it floats over the scrolling content (which is padded by `height`); snapshots stack it last.
struct SettingsFooterBar: View {
    static let height: CGFloat = 40
    /// Extra scroll space at the end of the grouped Form, tuned on the live window: the shipped
    /// macOS 11-target build leaves a 20 pt gap between "Reset to defaults" and the bar at full
    /// scroll (a default-target dev build lays the empty footer out 12 pt taller: 32 pt).
    static let formTrailingSpace: CGFloat = 20
    static let sourceCodeURL = "https://github.com/iBoysoft/Winstripe"
    let quitLabel: String
    let settingsLabel: String
    let aboutLabel: String
    let sourceCodeLabel: String
    let checkForUpdatesLabel: String

    fileprivate static func showAbout() {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        #else
        NSApp.activate(ignoringOtherApps: true)
        #endif
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    fileprivate static func openSourceCode() {
        guard let url = URL(string: Self.sourceCodeURL) else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                WordmarkLabel().fixedSize()
                Spacer(minLength: 8)
                SettingsMenuButton(settingsLabel: settingsLabel, aboutLabel: aboutLabel,
                                   sourceCodeLabel: sourceCodeLabel,
                                   checkForUpdatesLabel: checkForUpdatesLabel)
                    .frame(width: 24, height: 24)
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(BorderlessButtonStyle())
                .help(quitLabel)
                .accessibilityLabel(Text(quitLabel))
                .accessibilityIdentifier("settings.quit")
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height - 1)
        }
        .background(FooterMaterial())
    }
}

/// AppKit's pull-down control keeps the popup menu in the native macOS menu system while the
/// button itself remains a compact icon in the footer.
private struct SettingsMenuButton: NSViewRepresentable {
    let settingsLabel: String
    let aboutLabel: String
    let sourceCodeLabel: String
    let checkForUpdatesLabel: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24), pullsDown: true)
        button.autoenablesItems = false
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: settingsLabel)
        button.imagePosition = .imageOnly
        button.toolTip = settingsLabel
        button.setAccessibilityLabel(settingsLabel)
        button.setAccessibilityIdentifier("settings.menu")
        context.coordinator.update(button, aboutLabel: aboutLabel, sourceCodeLabel: sourceCodeLabel,
                                   checkForUpdatesLabel: checkForUpdatesLabel)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.toolTip = settingsLabel
        button.setAccessibilityLabel(settingsLabel)
        context.coordinator.update(button, aboutLabel: aboutLabel, sourceCodeLabel: sourceCodeLabel,
                                   checkForUpdatesLabel: checkForUpdatesLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        func update(_ button: NSPopUpButton, aboutLabel: String, sourceCodeLabel: String,
                    checkForUpdatesLabel: String) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            // Pull-down buttons reserve their first menu item for the static button contents.
            // Keep that item separate so both user actions remain visible in the menu.
            let buttonItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            buttonItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            menu.addItem(buttonItem)

            let about = NSMenuItem(title: aboutLabel, action: #selector(showAbout), keyEquivalent: "")
            about.target = self
            about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: aboutLabel)
            menu.addItem(about)

            let source = NSMenuItem(title: sourceCodeLabel, action: #selector(openSourceCode), keyEquivalent: "")
            source.target = self
            source.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                                   accessibilityDescription: sourceCodeLabel)
            menu.addItem(source)

            let updates = NSMenuItem(title: checkForUpdatesLabel,
                                     action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            updates.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                     accessibilityDescription: updates.title)
            menu.addItem(updates)

            button.menu = menu
        }

        @objc private func showAbout() { SettingsFooterBar.showAbout() }
        @objc private func openSourceCode() { SettingsFooterBar.openSourceCode() }
        @objc private func checkForUpdates() { AppUpdater.shared.checkForUpdates() }
    }
}

/// Translucent, blurring material behind the floating footer bar.
private struct FooterMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        // Blurs the scrolling content behind it (same-window blending), always active. Of the
        // macOS 11 materials, .popover lets the most content show through in both light and dark
        // (.headerView/.titlebar are near-opaque in light mode; .sidebar/.windowBackground do not
        // blur within a window at all).
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Keeps the window's vertical scrollers clear of the floating footer (scroller inset only; the
/// grouped Form ignores content insets, so its trailing space is a footer inside the Form).
struct BottomScrollInset: NSViewRepresentable {
    let inset: CGFloat

    func makeNSView(context: Context) -> InsetProbeView {
        let v = InsetProbeView()
        v.inset = inset
        return v
    }

    func updateNSView(_ view: InsetProbeView, context: Context) {
        view.inset = inset
        view.applySoon()
    }

    final class InsetProbeView: NSView {
        var inset: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySoon()
        }

        override func layout() {
            super.layout()
            applySoon()
        }

        func applySoon() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let root = window?.contentView else { return }
            for scroll in Self.scrollViews(in: root) where scroll.frame.height > 200 {
                guard scroll.scrollerInsets.bottom != inset else { continue }
                scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
            }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { scrollViews(in: $0) }
        }
    }
}
