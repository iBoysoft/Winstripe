import AppKit
import ApplicationServices
import CoreGraphics

struct ActiveDisplayFocusedWindow {
    enum CoordinateSpace {
        case cocoa
        case cgTopLeft
    }

    let pid: pid_t
    let frame: NSRect
    let coordinateSpace: CoordinateSpace
}

@MainActor
final class ActiveDisplayScheduledWork {
    private let cancelAction: @MainActor () -> Void
    private var cancelled = false

    init(cancel: @escaping @MainActor () -> Void = {}) { cancelAction = cancel }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        cancelAction()
    }
}

/// Follows the display containing the frontmost app's focused window. All inputs are injectable
/// so display selection and debounce behavior can be exercised without real desktop windows.
@MainActor
final class ActiveDisplayTracker {
    typealias ScreenProvider = @MainActor () -> [ScreenInfo]
    typealias FocusedWindowProvider = @MainActor () -> ActiveDisplayFocusedWindow?
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping () -> Void) -> ActiveDisplayScheduledWork
    typealias Retarget = @MainActor (CGDirectDisplayID) -> Void

    private let screens: ScreenProvider
    private let focusedWindow: FocusedWindowProvider
    private let mouseLocation: @MainActor () -> NSPoint
    private let mainScreenID: @MainActor () -> CGDirectDisplayID?
    private let isBarMenuOpen: @MainActor () -> Bool
    private let scheduler: Scheduler
    private let retarget: Retarget
    private let ignoredPID: pid_t
    private let debounce: TimeInterval
    private var pending: ActiveDisplayScheduledWork?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var axPID: pid_t?
    private var axWindow: AXUIElement?
    private var started = false

    init(screens: @escaping ScreenProvider,
         focusedWindow: @escaping FocusedWindowProvider,
         mouseLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
         mainScreenID: @escaping @MainActor () -> CGDirectDisplayID? = {
             NSScreen.main.flatMap(DisplayGeometry.displayID(of:))
         },
         isBarMenuOpen: @escaping @MainActor () -> Bool = { false },
         scheduler: @escaping Scheduler = ActiveDisplayTracker.mainScheduler,
         debounce: TimeInterval = 0.2,
         ignoredPID: pid_t = getpid(),
         retarget: @escaping Retarget) {
        self.screens = screens
        self.focusedWindow = focusedWindow
        self.mouseLocation = mouseLocation
        self.mainScreenID = mainScreenID
        self.isBarMenuOpen = isBarMenuOpen
        self.scheduler = scheduler
        self.debounce = debounce
        self.ignoredPID = ignoredPID
        self.retarget = retarget
    }

    func start() {
        if started {
            event()
            return
        }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.event() }
            })
        }
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.event() }
            })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: .winstripeDisplaysReconfigured, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.event() }
            })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.event() }
            })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: .winstripeAXWindowChanged, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.event() }
            })
        refreshAXObserver()
        event()
    }

    func stop() {
        guard started else { return }
        started = false
        pending?.cancel()
        pending = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        tearDownAXObserver()
    }

    /// Called by the bar manager when a transient bar UI closes. A blocked resolution is retried.
    func transientUIChanged() { event() }

    func event() {
        guard started else { return }
        refreshAXObserver()
        pending?.cancel()
        pending = scheduler(debounce) { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.resolve()
        }
    }

    func resolveNowForTesting() { resolve() }

    private func resolve() {
        guard started else { return }
        if isBarMenuOpen() {
            return
        }
        let list = screens()
        let focused = focusedWindow()
        let mouse = mouseLocation()
        let main = mainScreenID()
        guard let id = Self.resolveDisplayID(screens: list, focusedWindow: focused,
                                             mouseLocation: mouse, mainScreenID: main,
                                             ignoredPID: ignoredPID) else { return }
        retarget(id)
    }

    static func resolveDisplayID(screens: [ScreenInfo], focusedWindow: ActiveDisplayFocusedWindow?,
                                 mouseLocation: NSPoint, mainScreenID: CGDirectDisplayID?,
                                 ignoredPID: pid_t) -> CGDirectDisplayID? {
        guard !screens.isEmpty else { return nil }
        let primaryHeight = screens[0].frame.maxY
        if let focusedWindow, focusedWindow.pid != ignoredPID, !focusedWindow.frame.isEmpty {
            let focusedFrame: NSRect
            switch focusedWindow.coordinateSpace {
            case .cocoa:
                focusedFrame = focusedWindow.frame
            case .cgTopLeft:
                focusedFrame = NSRect(x: focusedWindow.frame.minX,
                                      y: primaryHeight - focusedWindow.frame.maxY,
                                      width: focusedWindow.frame.width,
                                      height: focusedWindow.frame.height)
            }
            var selectedID: CGDirectDisplayID?
            var selectedArea: CGFloat = 0
            for screen in screens {
                let intersection = focusedFrame.intersection(screen.frame)
                let area = max(0, intersection.width) * max(0, intersection.height)
                if area > selectedArea {
                    selectedArea = area
                    selectedID = screen.id
                }
            }
            if let selectedID, selectedArea > 0 { return selectedID }
        }
        if let screen = screens.first(where: { $0.frame.contains(mouseLocation) }) { return screen.id }
        if let mainScreenID, screens.contains(where: { $0.id == mainScreenID }) { return mainScreenID }
        return screens.first?.id
    }

    private func refreshAXObserver() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ignoredPID else {
            tearDownAXObserver()
            return
        }
        let pid = app.processIdentifier
        if axPID != pid {
            tearDownAXObserver()
            var observer: AXObserver?
            guard AXObserverCreate(pid, Self.axCallback, &observer) == .success, let observer else { return }
            let element = AXUIElementCreateApplication(pid)
            AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            axObserver = observer
            axPID = pid
        }
        guard let observer = axObserver else { return }
        var value: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        if let old = axWindow { AXObserverRemoveNotification(observer, old, kAXMovedNotification as CFString) }
        AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, nil)
        axWindow = window
    }

    private func tearDownAXObserver() {
        if let observer = axObserver {
            if let window = axWindow { AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        axPID = nil
        axWindow = nil
    }

    private static let axCallback: AXObserverCallback = { _, _, _, _ in
        Task { @MainActor in
            NotificationCenter.default.post(name: .winstripeAXWindowChanged, object: nil)
        }
    }

    private static func mainScheduler(delay: TimeInterval, action: @escaping () -> Void) -> ActiveDisplayScheduledWork {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return ActiveDisplayScheduledWork { work.cancel() }
    }
}

@MainActor
enum ActiveDisplayWindowResolver {
    static func focusedWindow(ignoredPID: pid_t = getpid()) -> ActiveDisplayFocusedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ignoredPID else { return nil }
        if AXIsProcessTrusted(), let frame = axFocusedFrame(pid: app.processIdentifier) {
            return ActiveDisplayFocusedWindow(pid: app.processIdentifier, frame: frame, coordinateSpace: .cgTopLeft)
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for entry in info {
            guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == app.processIdentifier,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            guard rect.width > 0, rect.height > 0 else { continue }
            return ActiveDisplayFocusedWindow(pid: app.processIdentifier, frame: rect, coordinateSpace: .cgTopLeft)
        }
        return nil
    }

    private static func axFocusedFrame(pid: pid_t) -> NSRect? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return NSRect(origin: point, size: dimensions)
    }
}

@MainActor
final class ActiveDisplayFakeScheduler {
    private final class Entry {
        let action: () -> Void
        var cancelled = false
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    private var entries: [Entry] = []

    func schedule(delay: TimeInterval, action: @escaping () -> Void) -> ActiveDisplayScheduledWork {
        _ = delay
        let entry = Entry(action)
        entries.append(entry)
        return ActiveDisplayScheduledWork { entry.cancelled = true }
    }

    func runAll() {
        while !entries.isEmpty {
            let pending = entries
            entries.removeAll()
            for entry in pending where !entry.cancelled { entry.action() }
        }
    }
}
