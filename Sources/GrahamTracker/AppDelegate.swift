import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = TrackerStore()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?

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
        if UserDefaults.standard.bool(forKey: "openWindowOnLaunch") { openMainWindow() }

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
        let symbol = store.isRunning ? "record.circle" : "pause.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: store.isRunning ? "Tracking" : "Stopped")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = false
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
        // Detach so the next left-click toggles instead of opening the menu.
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let today = Calendar.current.dateInterval(of: .day, for: Date())!
        menu.addItem(disabledItem("Today: \(formatHMS(store.trackedTime(in: today)))"))
        menu.addItem(disabledItem(statusLine()))
        menu.addItem(.separator())

        menu.addItem(item(store.isRunning ? "Stop Tracking" : "Start Tracking", #selector(toggleTracking)))
        menu.addItem(item("Sessions & Charts…", #selector(openMainWindow), key: "l"))
        menu.addItem(.separator())

        let loginItem = item("Launch at Login", #selector(toggleLaunchAtLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(item("Open Data Folder", #selector(openDataFolder)))
        menu.addItem(.separator())
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

    @objc private func openMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(store: store))
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
        window?.makeKeyAndOrderFront(nil)
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
