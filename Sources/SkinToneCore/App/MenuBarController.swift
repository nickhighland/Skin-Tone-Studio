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
    private weak var windowAwaitingHide: NSWindow?
    private var openMainWindow: OpenWindowAction?
    private var isRecreatingWindow = false

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
        window.isReleasedWhenClosed = false
        window.title = "Skin Tone Studio"
        window.sharingType = .readOnly
        // Reopening from the menu bar while on a different desktop would otherwise send the
        // window back to the Space it was hidden on, leaving only a Dock icon on this one.
        // (.canJoinAllSpaces must not be combined with this; AppKit raises if both are set.)
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        routeTitleBarButtonsToHide(in: window)
        primaryWindow = window
        openMainWindow = openWindow
        isRecreatingWindow = false
    }

    /// Minimizing into the Dock and then dropping to accessory mode leaves AppKit with a
    /// miniaturized window whose Dock tile no longer exists, and it can't be restored. Closing
    /// tears down the SwiftUI scene (and the camera session with it). Route both title-bar
    /// buttons straight to "hide to menu bar" instead.
    private func routeTitleBarButtonsToHide(in window: NSWindow) {
        for kind in [NSWindow.ButtonType.miniaturizeButton, .closeButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.target = self
            button.action = #selector(hideWindowFromMenu)
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
                  window === self.mainWindow else { return }
            // SwiftUI can rebuild the title bar (e.g. after full screen); keep the rerouting.
            self.routeTitleBarButtonsToHide(in: window)
            self.setWindowVisibleState()
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Fallback for minimize paths that bypass the title-bar button (Cmd-M, Window menu,
            // title-bar double-click). Restore the window first and only hide it once AppKit
            // reports the deminiaturize finished; hiding mid-animation strands the window.
            guard let self, let window = note.object as? NSWindow,
                  window === self.mainWindow else { return }
            self.windowAwaitingHide = window
            window.deminiaturize(nil)
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.windowAwaitingHide else { return }
            self.windowAwaitingHide = nil
            window.orderOut(nil)
            self.enterMenuBarMode()
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.windowAwaitingHide else { return }
            self.windowAwaitingHide = nil
            window.orderOut(nil)
            self.enterMenuBarMode()
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.mainWindow else { return }
            // Cmd-W still closes for real, and SwiftUI discards the scene's content. Forget the
            // window so the next show recreates it instead of fronting an empty shell.
            self.primaryWindow = nil
            DispatchQueue.main.async { self.enterMenuBarMode() }
        })
        notificationTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            StartupSettings.shared.refresh()
            self?.syncStartupMenuItem()
            guard let self, NSApp.activationPolicy() == .regular else { return }
            // A Dock click can activate the app without delivering applicationShouldHandleReopen
            // when the window was hidden with orderOut. Treat an active app with no visible main
            // window as a reopen request as well.
            if self.mainWindow?.isVisible != true || (self.mainWindow?.alphaValue ?? 0) < 0.01 {
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

    private var mainWindow: NSWindow? { primaryWindow }

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
        guard let window = mainWindow else { return }
        if window.isMiniaturized {
            windowAwaitingHide = window
            window.deminiaturize(nil)
            return
        }
        // A full-screen window owns its own Space; hiding it there strands that Space. Leave full
        // screen first and hide once AppKit reports the transition finished.
        if window.styleMask.contains(.fullScreen) {
            windowAwaitingHide = window
            window.toggleFullScreen(nil)
            return
        }
        window.orderOut(nil)
        enterMenuBarMode()
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

    private func showWindow(retriesRemaining: Int = 10) {
        guard let window = mainWindow else {
            // WindowGroup can finish creating its window one run-loop turn after the menu-bar
            // delegate. Retry once the scene has had a chance to materialize it.
            NSApp.setActivationPolicy(.regular)
            guard retriesRemaining > 0 else { return }
            if !isRecreatingWindow, let openMainWindow {
                isRecreatingWindow = true
                openMainWindow(id: Self.mainWindowID)
            }
            DispatchQueue.main.async { [weak self] in
                self?.showWindow(retriesRemaining: retriesRemaining - 1)
            }
            return
        }

        windowAwaitingHide = nil
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
        if mainWindow?.isVisible == true { NSApp.setActivationPolicy(.regular) }
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let openWindow else { return }
            MenuBarController.current?.register(contentWindow: window, openWindow: openWindow)
        }
    }
}
