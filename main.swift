// bettertab — Cmd+Tab replacement that cycles through *windows*, not apps.
//
// Order: all windows of the current app first (in their own MRU order),
// then the next app's windows, and so on. Includes minimized windows and
// windows on other Spaces.
//
// Single file, no dependencies. Build: ./build.sh
// MIT License. github.com/hamet/bettertab

import AppKit
import ApplicationServices

// MARK: - Private AX SPI: maps an AX window element to its CGWindowID.
// Present since 10.x in HIServices; used by AltTab and similar tools.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Keycodes
private let kcTab: Int64 = 48
private let kcEscape: Int64 = 53
private let kcUp: Int64 = 126
private let kcDown: Int64 = 125
private let kcLeft: Int64 = 123
private let kcRight: Int64 = 124

// MARK: - Config (~/Library/Application Support/bettertab.json)

struct Config {
    var modifier: CGEventFlags = .maskCommand
    var includeMinimized = true
    var maxVisibleRows = 14
    var width: CGFloat = 380
    var position = "right"          // right | left | center
    var edgeMargin: CGFloat = 16

    var nsModifier: NSEvent.ModifierFlags {
        switch modifier {
        case .maskAlternate: return .option
        case .maskControl:   return .control
        default:             return .command
        }
    }

    static let path = NSHomeDirectory() + "/Library/Application Support/bettertab.json"

    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let j = obj as? [String: Any] else { return c }
        if let m = (j["modifier"] as? String)?.lowercased() {
            switch m {
            case "option", "alt":    c.modifier = .maskAlternate
            case "control", "ctrl":  c.modifier = .maskControl
            default:                 c.modifier = .maskCommand
            }
        }
        if let b = j["includeMinimized"] as? Bool { c.includeMinimized = b }
        if let n = j["maxVisibleRows"] as? Int { c.maxVisibleRows = max(4, min(40, n)) }
        if let w = j["width"] as? Double { c.width = CGFloat(max(240, min(1200, w))) }
        if let p = (j["position"] as? String)?.lowercased(),
           ["right", "left", "center"].contains(p) { c.position = p }
        if let m = j["edgeMargin"] as? Double { c.edgeMargin = CGFloat(max(0, min(200, m))) }
        return c
    }
}

let config = Config.load()

// MARK: - Model

struct WinItem {
    let uid: String
    let pid: pid_t
    let ax: AXUIElement
    let appName: String
    let title: String
    let icon: NSImage?
    let minimized: Bool
}

// MARK: - AX helpers

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return false }
    return (v as? Bool) ?? false
}

func axWindowUID(_ el: AXUIElement, pid: pid_t, fallback: String) -> String {
    var wid = CGWindowID(0)
    if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 { return "\(pid)#\(wid)" }
    return "\(pid)~\(fallback)"
}

// MARK: - MRU

final class MRU {
    static let shared = MRU()
    private(set) var apps: [pid_t] = []
    private(set) var windows: [String] = []

    func touchApp(_ pid: pid_t) {
        apps.removeAll { $0 == pid }
        apps.insert(pid, at: 0)
        if apps.count > 64 { apps.removeLast() }
    }

    func touchWindow(_ uid: String) {
        windows.removeAll { $0 == uid }
        windows.insert(uid, at: 0)
        if windows.count > 512 { windows.removeLast() }
    }

    var appRank: [pid_t: Int] {
        var d = [pid_t: Int]()
        for (i, p) in apps.enumerated() { d[p] = i }
        return d
    }

    var winRank: [String: Int] {
        var d = [String: Int]()
        for (i, w) in windows.enumerated() { d[w] = i }
        return d
    }

    /// Record the currently focused window of an app (used on activation).
    func touchFocusedWindow(of pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &v) == .success,
              let raw = v, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        let win = raw as! AXUIElement
        touchWindow(axWindowUID(win, pid: pid, fallback: axString(win, kAXTitleAttribute) ?? ""))
    }
}

// MARK: - Window store

final class WindowStore {
    static let shared = WindowStore()

    private var items: [WinItem] = []
    private let queue = DispatchQueue(label: "com.hamet.bettertab.scan")
    private var coalescing = false
    private var lastRefresh = Date.distantPast

    /// Rescan at most once per `minInterval` seconds — used for the pre-warm on
    /// modifier-down, which would otherwise fire on every Cmd press while typing.
    func refreshThrottled(minInterval: TimeInterval = 1.0) {
        guard Date().timeIntervalSince(lastRefresh) > minInterval else { return }
        refresh()
    }

    /// Debounced rescan.
    func invalidate() {
        if coalescing { return }
        coalescing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.coalescing = false
            self?.refresh()
        }
    }

    func refresh() {
        lastRefresh = Date()
        let apps: [(pid: pid_t, name: String, icon: NSImage?)] =
            NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String, NSImage?)? in
                guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
                let pid = app.processIdentifier
                guard pid != getpid() else { return nil }
                return (pid, app.localizedName ?? "", app.icon)
            }
        queue.async {
            let scanned = WindowStore.scan(apps)
            DispatchQueue.main.async {
                self.items = scanned
                Controller.shared.listDidUpdate()
            }
        }
    }

    private static func isListable(_ w: AXUIElement) -> Bool {
        guard axString(w, kAXRoleAttribute) == kAXWindowRole else { return false }
        if let sub = axString(w, kAXSubroleAttribute) { return sub == kAXStandardWindowSubrole }
        return true
    }

    private static func scan(_ apps: [(pid: pid_t, name: String, icon: NSImage?)]) -> [WinItem] {
        var out: [WinItem] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { continue }
            for (idx, w) in windows.enumerated() {
                guard isListable(w) else { continue }
                let minimized = axBool(w, kAXMinimizedAttribute)
                if minimized && !config.includeMinimized { continue }
                var title = axString(w, kAXTitleAttribute) ?? ""
                if title.isEmpty, let doc = axString(w, kAXDocumentAttribute) {
                    title = (doc as NSString).lastPathComponent.removingPercentEncoding ?? ""
                }
                if title.isEmpty { title = app.name }
                let uid = axWindowUID(w, pid: app.pid, fallback: "\(idx)~\(title)")
                out.append(WinItem(uid: uid, pid: app.pid, ax: w, appName: app.name,
                                   title: title, icon: app.icon, minimized: minimized))
            }
        }
        return out
    }

    /// Flat list: apps in MRU order, windows inside each app in their own MRU order,
    /// minimized windows last within their app.
    func ordered() -> [WinItem] {
        var byApp: [pid_t: [WinItem]] = [:]
        for it in items { byApp[it.pid, default: []].append(it) }
        let aRank = MRU.shared.appRank
        let wRank = MRU.shared.winRank
        let pids = byApp.keys.sorted { a, b in
            let ra = aRank[a] ?? Int.max, rb = aRank[b] ?? Int.max
            return ra != rb ? ra < rb : a < b
        }
        var out: [WinItem] = []
        for pid in pids {
            let ws = byApp[pid]!.sorted { a, b in
                if a.minimized != b.minimized { return !a.minimized }
                let ra = wRank[a.uid] ?? Int.max, rb = wRank[b.uid] ?? Int.max
                if ra != rb { return ra < rb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            out.append(contentsOf: ws)
        }
        return out
    }

    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Watching apps for MRU + invalidation

private func axNotificationCallback(_ observer: AXObserver,
                                    _ element: AXUIElement,
                                    _ notification: CFString,
                                    _ refcon: UnsafeMutableRawPointer?) {
    let note = notification as String
    if note == kAXFocusedWindowChangedNotification || note == kAXMainWindowChangedNotification {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid != 0 {
            MRU.shared.touchWindow(axWindowUID(element, pid: pid,
                                               fallback: axString(element, kAXTitleAttribute) ?? ""))
        }
    }
    WindowStore.shared.invalidate()
}

final class AppWatcher {
    static let shared = AppWatcher()
    private var observers: [pid_t: AXObserver] = [:]

    private let notes = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification
    ]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MRU.shared.touchApp(app.processIdentifier)
            MRU.shared.touchFocusedWindow(of: app.processIdentifier)
            WindowStore.shared.invalidate()
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.attach(app)
            WindowStore.shared.invalidate()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.detach(app.processIdentifier)
            WindowStore.shared.invalidate()
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            MRU.shared.touchApp(front.processIdentifier)
            MRU.shared.touchFocusedWindow(of: front.processIdentifier)
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var obsRef: AXObserver?
        guard AXObserverCreate(pid, axNotificationCallback, &obsRef) == .success,
              let observer = obsRef else { return }
        let axApp = AXUIElementCreateApplication(pid)
        for note in notes {
            AXObserverAddNotification(observer, axApp, note as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

// MARK: - UI

final class ListView: NSView {
    var items: [WinItem] = []
    var selected = 0
    var scrollTop = 0
    /// uid of the window that currently has the focus (where we started from)
    var currentUID: String?
    /// mirror the row layout when the panel is docked to the right edge
    var rightAligned = true

    let rowH: CGFloat = 30
    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func index(at point: NSPoint) -> Int? {
        let row = Int(point.y / rowH) + scrollTop
        return (row >= 0 && row < items.count) ? row : nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), i != selected else { return }
        Controller.shared.select(i)
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        Controller.shared.select(i)
        Controller.shared.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = min(items.count, config.maxVisibleRows)
        guard visible > 0 else { return }

        let iconSize: CGFloat = 20
        let pad: CGFloat = 14
        let markerLane: CGFloat = 16     // reserved for the "current focus" dot

        for row in 0..<visible {
            let i = scrollTop + row
            guard i < items.count else { break }
            let item = items[i]
            let y = CGFloat(row) * rowH
            let isSel = (i == selected)
            let isCurrent = (item.uid == currentUID)

            if isSel {
                let r = NSRect(x: 6, y: y + 1, width: bounds.width - 12, height: rowH - 2)
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            } else if isCurrent {
                // where the focus is right now — a quiet plate, not a selection
                let r = NSRect(x: 6, y: y + 1, width: bounds.width - 12, height: rowH - 2)
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }

            // icon: right edge when docked right, left edge otherwise
            let iconX = rightAligned ? bounds.width - pad - iconSize : pad
            if let icon = item.icon {
                icon.draw(in: NSRect(x: iconX, y: y + (rowH - iconSize) / 2,
                                     width: iconSize, height: iconSize),
                          from: .zero, operation: .sourceOver, fraction: item.minimized ? 0.55 : 1.0)
            }

            // focus dot on the far side from the icon
            if isCurrent {
                let d: CGFloat = 6
                let dx = rightAligned ? pad - 4 : bounds.width - pad - d + 4
                (isSel ? NSColor.white : NSColor.controlAccentColor).setFill()
                NSBezierPath(ovalIn: NSRect(x: dx, y: y + (rowH - d) / 2, width: d, height: d)).fill()
            }

            let para = NSMutableParagraphStyle()
            para.alignment = rightAligned ? .right : .left
            // keep the app name (next to its icon) readable, cut the long title instead
            para.lineBreakMode = rightAligned ? .byTruncatingHead : .byTruncatingTail

            let nameColor: NSColor = isSel ? .white : .labelColor
            let titleColor: NSColor = isSel ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: nameColor, .paragraphStyle: para]
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: titleColor, .paragraphStyle: para]

            let title = item.title + (item.minimized ? "  ·  min" : "")
            let line = NSMutableAttributedString()
            if rightAligned {
                line.append(NSAttributedString(string: title + "  ", attributes: titleAttrs))
                line.append(NSAttributedString(string: item.appName, attributes: nameAttrs))
            } else {
                line.append(NSAttributedString(string: item.appName + "  ", attributes: nameAttrs))
                line.append(NSAttributedString(string: title, attributes: titleAttrs))
            }

            let textX = rightAligned ? markerLane + 4 : pad + iconSize + 10
            let textW = bounds.width - textX - (rightAligned ? (pad + iconSize + 10) : markerLane + 4)
            line.draw(in: NSRect(x: textX, y: y + (rowH - 17) / 2, width: max(40, textW), height: 17))
        }
    }
}

final class SwitcherPanel: NSPanel {
    let listView = ListView()
    private let effect = NSVisualEffectView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: config.width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect
        effect.addSubview(listView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reload(items: [WinItem], selected: Int, currentUID: String?) {
        listView.items = items
        listView.selected = selected
        listView.currentUID = currentUID
        listView.rightAligned = (config.position == "right")

        let visible = max(1, min(items.count, config.maxVisibleRows))
        // keep selection inside the visible window
        var top = listView.scrollTop
        if selected < top { top = selected }
        if selected >= top + visible { top = selected - visible + 1 }
        top = max(0, min(top, max(0, items.count - visible)))
        listView.scrollTop = top

        let h = CGFloat(visible) * listView.rowH + 16
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame          // respects menu bar and Dock
        let x: CGFloat
        switch config.position {
        case "left":   x = vf.minX + config.edgeMargin
        case "center": x = vf.midX - config.width / 2
        default:       x = vf.maxX - config.width - config.edgeMargin
        }
        let frame = NSRect(x: x.rounded(),
                           y: (vf.midY - h / 2).rounded(),
                           width: config.width, height: h)
        setFrame(frame, display: false)
        listView.frame = NSRect(x: 0, y: 8, width: config.width, height: h - 16)
        listView.needsDisplay = true
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
        listView.scrollTop = 0
    }
}

// MARK: - Controller

final class Controller {
    static let shared = Controller()

    var tap: CFMachPort?
    private(set) var isOpen = false
    private var list: [WinItem] = []
    private var selected = 0
    private var currentUID: String?
    private lazy var panel = SwitcherPanel()
    private var guardTimer: Timer?

    // MARK: switching

    /// Returns true if the event was handled (and must be swallowed).
    @discardableResult
    func step(forward: Bool) -> Bool {
        if !isOpen {
            list = WindowStore.shared.ordered()
            guard !list.isEmpty else { return false }   // no data / no permission -> let macOS handle it
            currentUID = list[0].uid                   // MRU head == the window in focus now
            if list.count == 1 { return true }
            selected = forward ? 1 : list.count - 1
            open()
        } else {
            guard list.count > 1 else { return true }
            selected = (selected + (forward ? 1 : -1) + list.count) % list.count
        }
        panel.reload(items: list, selected: selected, currentUID: currentUID)
        return true
    }

    func select(_ i: Int) {
        guard isOpen, i >= 0, i < list.count else { return }
        selected = i
        panel.reload(items: list, selected: selected, currentUID: currentUID)
    }

    private func open() {
        isOpen = true
        panel.reload(items: list, selected: selected, currentUID: currentUID)
        panel.show()
        guardTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.isOpen else { return }
            if !NSEvent.modifierFlags.contains(config.nsModifier) { self.commit() }
        }
        RunLoop.main.add(t, forMode: .common)
        guardTimer = t
    }

    private func close() {
        isOpen = false
        guardTimer?.invalidate()
        guardTimer = nil
        panel.hide()
    }

    func cancel() {
        guard isOpen else { return }
        close()
    }

    func commit() {
        guard isOpen else { return }
        let item = (selected >= 0 && selected < list.count) ? list[selected] : nil
        close()
        guard let item = item else { return }
        MRU.shared.touchWindow(item.uid)
        MRU.shared.touchApp(item.pid)
        activate(item)
    }

    private func activate(_ item: WinItem) {
        if item.minimized {
            AXUIElementSetAttributeValue(item.ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let raise = AXUIElementPerformAction(item.ax, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(item.ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(item.ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        let axApp = AXUIElementCreateApplication(item.pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: item.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        if raise != .success { WindowStore.shared.invalidate() }
    }

    /// Called when a background rescan lands; refresh the open panel without
    /// losing the current selection.
    func listDidUpdate() {
        guard isOpen else { return }
        let keep = (selected >= 0 && selected < list.count) ? list[selected].uid : nil
        let fresh = WindowStore.shared.ordered()
        guard !fresh.isEmpty else { return }
        list = fresh
        selected = keep.flatMap { uid in fresh.firstIndex { $0.uid == uid } } ?? min(selected, fresh.count - 1)
        panel.reload(items: list, selected: selected, currentUID: currentUID)
    }

    // MARK: event tap

    func startTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: tapCallback,
                                          userInfo: nil) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func reenableTap() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

private func tapCallback(proxy: CGEventTapProxy,
                         type: CGEventType,
                         event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let c = Controller.shared

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        c.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let modDown = flags.contains(config.modifier)

    if type == .flagsChanged {
        if c.isOpen && !modDown {
            c.commit()
        } else if modDown && !c.isOpen {
            // pre-warm the window list while the modifier is being held
            WindowStore.shared.refreshThrottled()
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    if key == kcTab && modDown {
        if repeated { return nil }
        return c.step(forward: !flags.contains(.maskShift)) ? nil : Unmanaged.passUnretained(event)
    }

    if c.isOpen {
        switch key {
        case kcEscape:
            c.cancel()
            return nil
        case kcDown, kcRight:
            c.step(forward: true)
            return nil
        case kcUp, kcLeft:
            c.step(forward: false)
            return nil
        default:
            c.cancel()
            return Unmanaged.passUnretained(event)
        }
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var permTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWatcher.shared.start()
        WindowStore.shared.refresh()

        if ensureTrusted() {
            launchTap()
        } else {
            // keep polling until the user ticks the box in System Settings
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.permTimer = nil
                self?.launchTap()
            }
            RunLoop.main.add(t, forMode: .common)
            permTimer = t
        }
    }

    private func ensureTrusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func launchTap() {
        if !Controller.shared.startTap() {
            FileHandle.standardError.write("bettertab: failed to create the event tap\n".data(using: .utf8)!)
        }
        WindowStore.shared.refresh()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
