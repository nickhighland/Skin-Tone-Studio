import AppKit
import Foundation
import SwiftUI

public extension Notification.Name {
    static let skinToneStudioCameraReset = Notification.Name("SkinToneStudio.CameraReset")
}

public final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startupMenuItem: NSMenuItem?
    private var notificationTokens: [NSObjectProtocol] = []
    private var primaryWindow: NSWindow?
    private var windowDelegateProxy: WindowDelegateProxy?
    private var openMainWindow: OpenWindowAction?
    private var isRecreatingWindow = false
    private var showWhenRegistered = false
    /// A hide that has to wait for an AppKit transition (deminiaturize or leaving full screen)
    /// to finish. Bound to the notification that completes it so an unrelated later transition
    /// can't trigger a stale hide.
    private var pendingHide: (window: NSWindow, completion: Notification.Name)?

    /// Scene id of the app's main `WindowGroup`, used to recreate the window if it was closed.
    public static let mainWindowID = "main"

    static weak var current: MenuBarController?

    public override init() {
        super.init()
        MenuBarController.current = self
    }

    /// Called by the SwiftUI content view once it is installed in its hosting window, so the
    /// controller always tracks the real app window rather than guessing from `NSApp.windows`
    /// (which also contains the status-item window and Sparkle's update windows).
    func register(contentWindow window: NSWindow, openWindow: OpenWindowAction) {
        openMainWindow = openWindow
        isRecreatingWindow = false
        if let primaryWindow, primaryWindow !== window {
            // State restoration or a racing recreate produced a second scene window. Each one
            // runs its own AppModel against the same camera, so keep the first and close this one.
            DispatchQueue.main.async { window.close() }
            return
        }

        window.isReleasedWhenClosed = false
        window.title = "Skin Tone Studio"
        window.sharingType = .readOnly
        // Reopening from the menu bar while on a different desktop would otherwise send the
        // window back to the Space it was hidden on, leaving only a Dock icon on this one.
        // (.canJoinAllSpaces must not be combined with this; AppKit raises if both are set.)
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        interceptHideRequests(in: window)
        primaryWindow = window

        if showWhenRegistered {
            showWhenRegistered = false
            showWindow()
        }
    }

    /// Called when the SwiftUI content leaves its window, i.e. the scene was torn down. The
    /// window can no longer be shown, so the next show request recreates the scene instead.
    func unregister(contentWindow window: NSWindow) {
        guard window === primaryWindow else { return }
        primaryWindow = nil
        windowDelegateProxy = nil
        if pendingHide?.window === window { pendingHide = nil }
    }

    /// Closing or minimizing into the Dock must never tear down or strand the window: minimizing
    /// and then dropping to accessory mode leaves a miniaturized window whose Dock tile no longer
    /// exists. Close requests (red button, Cmd-W, accessibility) are caught at the window-delegate
    /// level; the minimize button has no delegate veto, so it is routed to the hide action.
    /// Re-applied whenever the window becomes key or leaves full screen, in case SwiftUI replaces
    /// its delegate or rebuilds the title bar.
    private func interceptHideRequests(in window: NSWindow) {
        if window.delegate !== windowDelegateProxy || windowDelegateProxy == nil {
            let proxy = WindowDelegateProxy(wrapping: window.delegate, shouldClose: { [weak self] window in
                guard let self, window === self.primaryWindow else { return true }
                self.hide(window)
                return false
            }, didFailToExitFullScreen: { [weak self] window in
                // The window stayed in full screen; drop the hide rather than let a later,
                // unrelated full-screen exit trigger it.
                if self?.pendingHide?.window === window { self?.pendingHide = nil }
            })
            windowDelegateProxy = proxy
            window.delegate = proxy
        }
        if let button = window.standardWindowButton(.miniaturizeButton) {
            button.target = self
            button.action = #selector(hideWindowFromTitleBar(_:))
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = UpdateController.shared
        installStatusItem()
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.primaryWindow else { return }
            self.interceptHideRequests(in: window)
            self.setWindowVisibleState()
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Fallback for minimize paths that bypass the title-bar button (Window menu,
            // title-bar double-click). Restore the window first and only hide it once AppKit
            // reports the deminiaturize finished; hiding mid-animation strands the window.
            guard let self, let window = note.object as? NSWindow,
                  window === self.primaryWindow else { return }
            self.pendingHide = (window, NSWindow.didDeminiaturizeNotification)
            window.deminiaturize(nil)
        })
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didExitFullScreenNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.completePendingHide(note)
            })
        }
        notificationTokens.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Only programmatic closes get here; the delegate proxy vetoes user closes. The
            // window is kept (isReleasedWhenClosed is false) and can be shown again. If SwiftUI
            // tears the scene down as well, the registrar reports it through unregister.
            guard let self, let window = note.object as? NSWindow,
                  window === self.primaryWindow else { return }
            DispatchQueue.main.async { [weak self] in self?.enterMenuBarMode() }
        })
        notificationTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            StartupSettings.shared.refresh()
            self?.syncStartupMenuItem()
            guard let self, NSApp.activationPolicy() == .regular,
                  // Mid-hide (e.g. between minimize and deminiaturize) the window is briefly
                  // invisible; that is not a reopen request.
                  self.pendingHide == nil else { return }
            // A Dock click can activate the app without delivering applicationShouldHandleReopen
            // when the window was hidden with orderOut. Treat an active app with no visible main
            // window as a reopen request as well.
            if self.primaryWindow?.isVisible != true || (self.primaryWindow?.alphaValue ?? 0) < 0.01 {
                DispatchQueue.main.async { [weak self] in self?.showWindow() }
            }
        })
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Skin Tone Studio")
            button.image?.isTemplate = true
            button.toolTip = "Skin Tone Studio"
        }

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Skin Tone Studio", action: #selector(showWindowFromMenu), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let reset = NSMenuItem(title: "Camera Reset", action: #selector(resetCameraFromMenu), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide to Menu Bar", action: #selector(hideWindowFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let startup = NSMenuItem(title: "Start with computer", action: #selector(toggleStartupFromMenu), keyEquivalent: "")
        startup.target = self
        menu.addItem(startup)
        startupMenuItem = startup
        syncStartupMenuItem()

        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Skin Tone Studio", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func showWindowFromMenu() { showWindow() }

    @objc private func hideWindowFromMenu() {
        guard let primaryWindow else { return }
        hide(primaryWindow)
    }

    @objc private func hideWindowFromTitleBar(_ sender: NSButton) {
        guard let window = sender.window else { return }
        guard window === primaryWindow else {
            window.miniaturize(nil)
            return
        }
        hide(window)
    }

    private func hide(_ window: NSWindow) {
        if window.isMiniaturized {
            pendingHide = (window, NSWindow.didDeminiaturizeNotification)
            window.deminiaturize(nil)
            return
        }
        // A full-screen window owns its own Space; hiding it there strands that Space. Leave full
        // screen first and hide once AppKit reports the transition finished.
        if window.styleMask.contains(.fullScreen) {
            pendingHide = (window, NSWindow.didExitFullScreenNotification)
            window.toggleFullScreen(nil)
            return
        }
        pendingHide = nil
        window.orderOut(nil)
        enterMenuBarMode()
    }

    private func completePendingHide(_ note: Notification) {
        guard let pendingHide, let window = note.object as? NSWindow,
              window === pendingHide.window, note.name == pendingHide.completion else { return }
        // Leaving full screen can rebuild the title bar; restore the minimize-button routing.
        interceptHideRequests(in: window)
        hide(window)
    }

    @objc private func resetCameraFromMenu() {
        NotificationCenter.default.post(name: .skinToneStudioCameraReset, object: nil)
    }

    @objc private func toggleStartupFromMenu() {
        let settings = StartupSettings.shared
        settings.setStartsWithComputer(!settings.startsWithComputer)
        syncStartupMenuItem()

        if let message = settings.message {
            let alert = NSAlert()
            alert.messageText = "Start with computer"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            if settings.requiresApproval {
                alert.addButton(withTitle: "Open Login Items")
            }
            if alert.runModal() == .alertSecondButtonReturn {
                settings.openLoginItemsSettings()
            }
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdatesFromMenu() {
        UpdateController.shared.checkForUpdates()
    }

    private func showWindow() {
        guard let window = primaryWindow else {
            // No live window: the scene is still being created at launch, or it was torn down.
            // Ask SwiftUI for one and show it as soon as it registers. The activation policy is
            // left alone until then so a Dock icon never appears without a window.
            showWhenRegistered = true
            recreateWindowIfNeeded()
            return
        }

        pendingHide = nil
        interceptHideRequests(in: window)
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        // Activation-policy changes are asynchronous on macOS. Bringing the window forward on
        // the next turn makes reopening reliable after orderOut/deminiaturize from the menu bar.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            self.ensureWindowIsOnScreen(window)
            window.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func recreateWindowIfNeeded() {
        // Before the first registration there is no OpenWindowAction yet; the launch window will
        // register on its own and pick up showWhenRegistered.
        guard !isRecreatingWindow, let openMainWindow else { return }
        isRecreatingWindow = true
        openMainWindow(id: Self.mainWindowID)
        // If the scene never registers, allow a later show request to try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isRecreatingWindow = false
        }
    }

    private func ensureWindowIsOnScreen(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let frame = window.frame
        let hasUsableIntersection = visibleFrames.contains { visibleFrame in
            let intersection = visibleFrame.intersection(frame)
            return intersection.width >= min(160, max(1, frame.width * 0.25))
                && intersection.height >= min(120, max(1, frame.height * 0.25))
        }
        guard !hasUsableIntersection else { return }

        let visibleFrame = (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
            ?? visibleFrames[0]
        let width = min(max(frame.width, 900), visibleFrame.width * 0.9)
        let height = min(max(frame.height, 620), visibleFrame.height * 0.9)
        let centered = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(centered, display: false)
    }

    private func enterMenuBarMode() {
        NSApp.setActivationPolicy(.accessory)
    }

    private func setWindowVisibleState() {
        if primaryWindow?.isVisible == true { NSApp.setActivationPolicy(.regular) }
    }

    private func syncStartupMenuItem() {
        startupMenuItem?.state = StartupSettings.shared.startsWithComputer ? .on : .off
    }
}

/// Reports the NSWindow hosting the SwiftUI content to the menu-bar controller.
struct ContentWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = RegistrarView()
        view.openWindow = context.environment.openWindow
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RegistrarView: NSView {
        var openWindow: OpenWindowAction?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window, newWindow !== window {
                MenuBarController.current?.unregister(contentWindow: window)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let openWindow else { return }
            MenuBarController.current?.register(contentWindow: window, openWindow: openWindow)
        }
    }
}

/// Wraps the window's SwiftUI-owned delegate so close requests can be turned into "hide to menu
/// bar", while every other delegate message still reaches SwiftUI unchanged.
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    private let wrapped: NSWindowDelegate?
    private let shouldClose: (NSWindow) -> Bool
    private let didFailToExitFullScreen: (NSWindow) -> Void

    init(wrapping delegate: NSWindowDelegate?,
         shouldClose: @escaping (NSWindow) -> Bool,
         didFailToExitFullScreen: @escaping (NSWindow) -> Void) {
        wrapped = delegate
        self.shouldClose = shouldClose
        self.didFailToExitFullScreen = didFailToExitFullScreen
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return wrapped?.windowShouldClose?(sender) ?? true
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        didFailToExitFullScreen(window)
        wrapped?.windowDidFailToExitFullScreen?(window)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (wrapped?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        wrapped?.responds(to: aSelector) == true ? wrapped : super.forwardingTarget(for: aSelector)
    }
}
