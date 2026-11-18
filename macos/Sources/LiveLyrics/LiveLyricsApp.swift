import AppKit
import SwiftUI

@main
struct LiveLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Where the lyrics sit. The bottom corners use the free space beside a centred Dock.
private enum Placement: String, CaseIterable {
    case corner, notch, bottomLeft, bottomRight

    static let key = "Placement"

    var title: String {
        switch self {
        case .corner: "Top right corner"
        case .notch: "Under the notch"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    /// Falls back to the old under-the-notch switch for installs that predate this setting.
    static var stored: Placement {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: key), let value = Placement(rawValue: raw) { return value }
        return defaults.bool(forKey: "ShowUnderNotch") ? .notch : .corner
    }
}

/// Owns the menu bar icon and the corner panel. The panel also opens on launch
/// and on relaunch, so the app stays reachable when macOS hides the icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = LyricsViewModel()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var notchPanel: NSPanel?
    private let notchState = NotchState()
    private var pointerMonitor: Any?
    private var placement = Placement.stored
    /// The notch and both bottom corners use the same black lyrics bar.
    private var showsInNotch: Bool { placement != .corner }
    private var activePanel: NSPanel? { showsInNotch ? notchPanel : panel }
    private var controlsShown = false
    /// How far the panel moved up to fit the controls above the Dock.
    private var controlsShift: CGFloat = 0
    private static let frameName = "LyricsPanel"
    private static let bottomMargin: CGFloat = 0
    private static let minimumSize = NSSize(width: 200, height: 80)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The Android app's themed icon, as a template so it follows the menu bar's colour.
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "LiveLyrics"
        item.button?.image = icon
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        NotificationCenter.default.addObserver(
            self, selector: #selector(placeNotchPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // Mouse moves outside the app need no permission; the bar ignores the pointer, so all moves are outside.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerOverNotch() }
        }
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        setControlsShown(false)
        model.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Collapse first so the autosaved frame is the lyrics-only size.
        setControlsShown(false)
    }

    /// Grows the panel downward by the controls' height, so the size the user
    /// picks is for the lyrics alone and the controls never squeeze them.
    private func setControlsShown(_ shown: Bool) {
        guard let panel, shown != controlsShown else { return }
        controlsShown = shown
        let height = LyricsPopoverView.controlsHeight
        var frame = panel.frame
        var minimum = Self.minimumSize
        if shown {
            minimum.height += height
            frame.origin.y -= height
            frame.size.height += height
            let bottom = panel.screen?.visibleFrame.minY ?? frame.minY
            controlsShift = max(0, bottom - frame.minY)
            frame.origin.y += controlsShift
        } else {
            frame.origin.y += height - controlsShift
            frame.size.height -= height
            controlsShift = 0
        }
        panel.contentMinSize = minimum
        panel.setFrame(frame, display: true)
    }

    /// A right click or control click opens a menu with Quit; a plain click toggles the popup.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseUp || event.modifierFlags.contains(.control),
              let statusItem
        else { return togglePanel() }
        let menu = NSMenu()
        for option in Placement.allCases {
            let item = menu.addItem(withTitle: option.title, action: #selector(placementChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == placement ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LiveLyrics", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attached only for this click, so a plain click keeps calling the action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func placementChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = Placement(rawValue: raw) else { return }
        setPlacement(option)
    }

    /// Under the notch the icon opens and closes the full popup; in the corner it shows and hides it.
    @objc private func togglePanel() {
        if showsInNotch, notchPanel?.isVisible == true {
            setNotchExpanded(!notchState.isExpanded)
        } else if activePanel?.isVisible == true {
            activePanel?.close()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel: NSPanel
        if showsInNotch {
            panel = notchPanel ?? makeNotchPanel()
            notchPanel = panel
            let hostingView = NSHostingView(rootView: NotchLyricsView(
                model: model,
                state: notchState,
                atBottom: placement.isBottom,
                onCollapse: { [weak self] in self?.setNotchExpanded(false) },
                onTogglePlacement: { [weak self] in self?.setPlacement(.corner) }
            ))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
            setNotchExpanded(false)
        } else {
            panel = self.panel ?? makePanel()
            self.panel = panel
            // A fresh view each time, so the controls start hidden like the frame.
            let hostingView = NSHostingView(rootView: LyricsPopoverView(
                model: model,
                onControlsVisibilityChange: { [weak self] shown in self?.setControlsShown(shown) },
                onTogglePlacement: { [weak self] in self?.setPlacement(.notch) }
            ))
            // The panel's size comes from the user and the controls, never from the SwiftUI content.
            hostingView.sizingOptions = []
            panel.contentView = hostingView
        }
        model.start()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func setPlacement(_ option: Placement) {
        setControlsShown(false)
        // orderOut, not close, so the lyrics keep playing through the switch.
        activePanel?.orderOut(nil)
        placement = option
        UserDefaults.standard.set(option.rawValue, forKey: Placement.key)
        showPanel()
    }

    /// The collapsed bar lets every click through to the window underneath; only
    /// the expanded popup takes the pointer.
    private func setNotchExpanded(_ expanded: Bool) {
        guard let notchPanel else { return }
        notchState.isPointerOver = false
        notchState.isExpanded = expanded
        notchPanel.ignoresMouseEvents = !expanded
        placeNotchPanel()
        if expanded { notchPanel.makeKey() }
    }

    private func updatePointerOverNotch() {
        guard showsInNotch, let notchPanel, notchPanel.isVisible, !notchState.isExpanded else { return }
        let over = notchPanel.frame.contains(NSEvent.mouseLocation)
        if over != notchState.isPointerOver { notchState.isPointerOver = over }
    }

    /// Hangs the notch panel from the bottom of the menu bar, centred on the
    /// notch, or on the main screen when no screen has one.
    @objc private func placeNotchPanel() {
        guard let notchPanel,
              let screen = (placement.isBottom ? NSScreen.main : NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main)
        else { return }
        let menuBarHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let size = notchState.isExpanded ? NotchLyricsView.expandedSize : NotchLyricsView.collapsedSize(atBottom: placement.isBottom)
        if placement.isBottom {
            // The very bottom, so the bar sits beside a centred Dock rather than above it.
            let visible = screen.visibleFrame
            notchPanel.setFrame(NSRect(
                x: placement == .bottomLeft ? visible.minX + Self.bottomMargin : visible.maxX - size.width - Self.bottomMargin,
                y: screen.frame.minY + Self.bottomMargin,
                width: size.width,
                height: size.height
            ), display: true)
            return
        }
        notchPanel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - menuBarHeight - size.height,
            width: size.width,
            height: size.height
        ), display: true)
    }

    private func makeNotchPanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: NotchLyricsView.collapsedSize(atBottom: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Clear, so the rounded bottom corners show what is behind them.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            // First launch: the title row and about three lyric lines.
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentMinSize = Self.minimumSize
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        if !panel.setFrameUsingName(Self.frameName) {
            positionInTopRightCorner(panel)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private func positionInTopRightCorner(_ panel: NSPanel) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let margin: CGFloat = 12
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - margin,
            y: visible.maxY - panel.frame.height - margin
        ))
    }
}

/// A borderless panel can't become key by default, which the popup's buttons need.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
