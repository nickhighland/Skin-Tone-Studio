import AppKit
import Foundation

public extension Notification.Name {
    static let skinToneStudioCameraReset = Notification.Name("SkinToneStudio.CameraReset")
}

public final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startupMenuItem: NSMenuItem?
    private var notificationTokens: [NSObjectProtocol] = []
    private var primaryWindow: NSWindow?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = UpdateController.shared
        installStatusItem()
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  self.isApplicationWindow(window) else { return }
            self.remember(window: window)
            self.setWindowVisibleState()
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  self.isApplicationWindow(window) else { return }
            self.remember(window: window)
            // Keep the process alive in the menu bar, but remove the miniaturized window from
            // the Dock. Doing this on the next run-loop turn avoids racing AppKit's minimize
            // animation and leaves a normal window ready to be shown again.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.orderOut(nil)
                self.enterMenuBarMode()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  self.isApplicationWindow(window) else { return }
            self.remember(window: window)
            DispatchQueue.main.async { self.enterMenuBarMode() }
        })
        notificationTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            StartupSettings.shared.refresh()
            self?.syncStartupMenuItem()
        })

        DispatchQueue.main.async { [weak self] in
            if let window = self?.mainWindow {
                self?.remember(window: window)
            }
        }
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

    private var mainWindow: NSWindow? {
        if let primaryWindow, isApplicationWindow(primaryWindow) {
            return primaryWindow
        }

        let candidate = NSApp.windows.first(where: { $0.canBecomeMain && isApplicationWindow($0) })
            ?? NSApp.windows.first(where: isApplicationWindow)
        if let candidate { remember(window: candidate) }
        return candidate
    }

    private func isApplicationWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.contentView != nil
    }

    private func remember(window: NSWindow) {
        guard isApplicationWindow(window) else { return }
        window.isReleasedWhenClosed = false
        primaryWindow = window
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
        mainWindow?.orderOut(nil)
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

    private func showWindow() {
        guard let window = mainWindow else {
            // WindowGroup can finish creating its window one run-loop turn after the menu-bar
            // delegate. Retry once the scene has had a chance to materialize it.
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async { [weak self] in self?.showWindow() }
            return
        }

        remember(window: window)
        NSApp.setActivationPolicy(.regular)
        // Activation-policy changes are asynchronous on macOS. Bringing the window forward on
        // the next turn makes reopening reliable after orderOut/deminiaturize from the menu bar.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.remember(window: window)
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
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
