enum PreviewStyle {
    case titleList, aero, flat, acrylic
}

struct ThemeCapabilities {
    private let kind: ThemeKind
    @MainActor var startButtonOverflow: Bool { Theme.make(kind).startStyle.overflow.enabled }
    @MainActor var layoutStyle: LayoutStyle { Theme.make(kind).layoutStyle }
    @MainActor var usesCompactPreviewLayout: Bool {
        layoutStyle.fixedItems.contains("win10Search") || previewStyle == .acrylic
    }
    let usesWin8StartColor: Bool
    let superbar: Bool
    let previewStyle: PreviewStyle

    init(kind: ThemeKind) {
        self.kind = kind
        usesWin8StartColor = kind == .win8
        superbar = [.win7, .win10, .win11].contains(kind)
        switch kind {
        case .win95, .win98, .winME, .win2000, .winXP: previewStyle = .titleList
        case .vista, .win7: previewStyle = .aero
        case .win8, .win10: previewStyle = .flat
        case .win11: previewStyle = .acrylic
        }
    }

    @MainActor
    init(settings: TaskbarSettings) {
        self.kind = settings.theme
        self.usesWin8StartColor = settings.theme == .win8
        self.superbar = Theme.make(settings).layoutStyle.pins == .superbar
        self.previewStyle = settings.theme.capabilities.previewStyle
    }
}

extension ThemeKind {
    var capabilities: ThemeCapabilities { ThemeCapabilities(kind: self) }
}

extension TaskbarSettings {
    @MainActor var capabilities: ThemeCapabilities { ThemeCapabilities(settings: self) }
}
