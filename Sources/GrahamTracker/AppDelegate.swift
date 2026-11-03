import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = TrackerStore()
    private let navigation = AppNavigation()
    private lazy var notionSync = NotionSync(store: store)
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var animationTimer: Timer?
    private var animationFrame = 0

    private var trackingAnimation: TrackingAnimation {
        get { UserDefaults.standard.string(forKey: "trackingAnimation").flatMap(TrackingAnimation.init) ?? .munch }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trackingAnimation") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        store.onTick = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        installMainMenu()
        enableLaunchAtLoginOnFirstRun()
        notionSync.sync()
        if UserDefaults.standard.bool(forKey: "openWindowOnLaunch") { openMainWindow() }
        if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") { openSettings() }
        if let error = store.loadError {
            let alert = NSAlert()
            alert.messageText = "GrahamTracker couldn't load your sessions"
            alert.informativeText = error
            NSApp.activate()
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop(reason: .quit)
    }

    // MARK: - Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let today = Calendar.current.dateInterval(of: .day, for: Date())!
        let text = formatHMS(store.trackedTime(in: today))
        // Plain title (no explicit color) so the system draws it like other menu bar items.
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.title = " " + text
        syncAnimationTimer()
        updateStatusImage()
    }

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        if store.isRunning {
            let frames = trackingAnimation.frames
            button.image = frames[animationFrame % frames.count]
        } else {
            button.image = MenuBarIcon.stopped
        }
    }

    /// Frame-swap animation; the timer only exists while tracking with an animation selected.
    private func syncAnimationTimer() {
        let animation = trackingAnimation
        let shouldAnimate = store.isRunning && animation != .none
        if shouldAnimate, animationTimer?.timeInterval != animation.frameInterval {
            animationTimer?.invalidate()
            let timer = Timer(timeInterval: animation.frameInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.animationFrame += 1
                    self.updateStatusImage()
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !shouldAnimate, animationTimer != nil {
            animationTimer?.invalidate()
            animationTimer = nil
            animationFrame = 0
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.option) == true
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            statusItem.menu = buildMenu()
            sender.performClick(nil)
        } else {
            store.toggle()
            updateStatusItem()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left-click toggles instead of opening the menu. Deferred because the
        // clicked item's action is sent after this returns, and the status item holds the only reference to the menu.
        Task { @MainActor [weak self] in self?.statusItem.menu = nil }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let today = Calendar.current.dateInterval(of: .day, for: Date())!
        menu.addItem(disabledItem("Today: \(formatHMS(store.trackedTime(in: today)))"))
        menu.addItem(disabledItem(statusLine()))
        menu.addItem(.separator())

        if store.isRunning {
            menu.addItem(item("Change Current Session Start…", #selector(editCurrentSessionStart)))
        }
        menu.addItem(item(store.isRunning ? "Stop Tracking" : "Start Tracking", #selector(toggleTracking)))
        menu.addItem(item("Sessions & Charts…", #selector(openMainWindow), key: "l"))
        menu.addItem(.separator())

        let animationMenu = NSMenu()
        for animation in TrackingAnimation.allCases {
            let animationItem = item(animation.rawValue, #selector(selectTrackingAnimation(_:)))
            animationItem.representedObject = animation.rawValue
            animationItem.state = animation == trackingAnimation ? .on : .off
            animationMenu.addItem(animationItem)
        }
        let animationParent = NSMenuItem(title: "Tracking Animation", action: nil, keyEquivalent: "")
        animationParent.submenu = animationMenu
        menu.addItem(animationParent)

        let loginItem = item("Launch at Login", #selector(toggleLaunchAtLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(item("Open Data Folder", #selector(openDataFolder)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())

        if notionSync.settings.enabled {
            menu.addItem(disabledItem("Notion: \(notionSync.statusDescription)"))
            if notionSync.isReady {
                menu.addItem(item("Sync to Notion Now", #selector(syncNotionNow)))
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Quit GrahamTracker", #selector(quit), key: "q"))
        return menu
    }

    private func statusLine() -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if let start = store.activeStart {
            return "Running since \(start.formatted(time))"
        }
        if let auto = store.lastAutoStop {
            let why: String
            switch auto.reason {
            case .idle: why = "idle 5 min"
            case .sleep: why = "Mac slept"
            case .recovered: why = "app wasn't running"
            case .manual, .quit: why = ""
            }
            return "Auto-stopped at \(auto.date.formatted(time)) (\(why))"
        }
        return "Stopped"
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleTracking() {
        store.toggle()
        updateStatusItem()
    }

    @objc private func editCurrentSessionStart() {
        navigation.requestFocusActiveStart()
        openMainWindow()
    }

    @objc private func openMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(store: store, navigation: navigation))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "GrahamTracker"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 560))
            window.center()
            window.setFrameAutosaveName("MainWindow")
            self.window = window
        }
        NSApp.activate()
        // activate() is cooperative and may be declined right after a menu closes; still bring the window up.
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(sync: notionSync))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "GrahamTracker Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func syncNotionNow() {
        notionSync.sync()
    }

    @objc private func selectTrackingAnimation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let animation = TrackingAnimation(rawValue: raw) else { return }
        trackingAnimation = animation
        animationFrame = 0
        updateStatusItem()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(store.dataDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasSuffix(".app") else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Accessory apps have no visible menu bar, but this keeps standard shortcuts (⌘W, ⌘C, ⌘V, ⌘Z…) working in the window.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(withTitle: "Quit GrahamTracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenuItem(appMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenuItem(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(submenuItem(windowMenu))

        NSApp.mainMenu = mainMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
