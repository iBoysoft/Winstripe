import AppKit
import SwiftUI

/// Native round "?" help button placed after a permission name in Settings. Clicking it shows a
/// transient popover, anchored to the button, explaining what Winstripe uses that permission for.
struct PermissionHelpButton: NSViewRepresentable {
    let title: String
    let body: String
    let identifier: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.bezelStyle = .helpButton
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        apply(to: button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        apply(to: button, coordinator: context.coordinator)
    }

    private func apply(to button: NSButton, coordinator: Coordinator) {
        coordinator.title = title
        coordinator.body = body
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var title = ""
        var body = ""
        private var popover: NSPopover?

        @objc func toggle(_ sender: NSButton) {
            if let popover, popover.isShown {
                popover.performClose(sender)
                return
            }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            popover.contentViewController = PermissionHelpContentController(title: title, body: body)
            self.popover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
        }
    }
}

/// Popover content: a bold title, short wrapped body paragraphs, then a distinct final paragraph
/// stating what happens when the permission is not granted. Max width 300 pt; follows light/dark.
/// The unauthorized line uses the primary label color (not secondary) so it stays readable in dark mode.
final class PermissionHelpContentController: NSViewController {
    static let maximumWidth: CGFloat = 300
    private static let inset: CGFloat = 14
    private let helpTitle: String
    private let body: String

    init(title: String, body: String) {
        helpTitle = title
        self.body = body
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let textWidth = Self.maximumWidth - 2 * Self.inset
        let titleLabel = NSTextField(wrappingLabelWithString: helpTitle)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .labelColor
        titleLabel.preferredMaxLayoutWidth = textWidth

        let paragraphs = body.components(separatedBy: "\n").filter { !$0.isEmpty }
        precondition(!paragraphs.isEmpty, "permission help body must include the unauthorized consequence")
        let reasons = paragraphs.dropLast()
        let unauthorized = paragraphs.last!

        var views: [NSView] = [titleLabel]
        for paragraph in reasons {
            let label = NSTextField(wrappingLabelWithString: paragraph)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            label.textColor = .labelColor
            label.preferredMaxLayoutWidth = textWidth
            views.append(label)
        }

        // Thin rule before the unauthorized consequence so it reads as its own block.
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        let unauthorizedLabel = NSTextField(wrappingLabelWithString: unauthorized)
        unauthorizedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        unauthorizedLabel.textColor = .labelColor
        unauthorizedLabel.preferredMaxLayoutWidth = textWidth

        let stack = NSStackView(views: views + [rule, unauthorizedLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(8, after: titleLabel)
        if let lastReason = views.last, lastReason !== titleLabel {
            stack.setCustomSpacing(10, after: lastReason)
        }
        stack.setCustomSpacing(8, after: rule)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 13, right: Self.inset)
        for label in views + [unauthorizedLabel] {
            label.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        }
        view = stack
        preferredContentSize = stack.fittingSize
    }
}
