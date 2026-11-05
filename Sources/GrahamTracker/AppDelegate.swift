import AppKit
import ServiceManagement
import SwiftUI

/// Calls the deprecated activate(ignoringOtherApps:) without a deprecation warning.
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivation {}

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
    private var isShowingDayEndPrompt = false

    private var trackingAnimation: TrackingAnimation {
        get { UserDefaults.standard.string(forKey: "trackingAnimation").flatMap(TrackingAnimation.init) ?? .munch }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trackingAnimation") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: Self.resumeAfterRelaunchKey)
        store.onDayBoundary = { [weak self] in
            // Don't present from inside the sleep/timer callback; let that run loop turn finish first.
            DispatchQueue.main.async { self?.promptForDayEndIfNeeded() }
        }
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
        if store.pendingDayEnd != nil {
            // After the launch window orders front, so the prompt stays on top.
            DispatchQueue.main.async { [weak self] in self?.promptForDayEndIfNeeded() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: Self.resumeAfterRelaunchKey) {
            UserDefaults.standard.removeObject(forKey: Self.resumeAfterRelaunchKey)
            store.saveForRelaunch()
        } else if store.pendingDayEnd == nil {
            store.stop(reason: .quit)
        }
    }

    /// Set by `make install` just before quitting, so updating doesn't end a running session.
    private static let resumeAfterRelaunchKey = "resumeAfterRelaunch"

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
        if isActivelyTracking {
            let frames = trackingAnimation.frames
            button.image = frames[animationFrame % frames.count]
        } else {
            button.image = MenuBarIcon.stopped
        }
    }

    /// A session waiting for a stop time isn't still ticking.
    private var isActivelyTracking: Bool { store.isRunning && store.pendingDayEnd == nil }

    /// Frame-swap animation; the timer only exists while tracking with an animation selected.
    private func syncAnimationTimer() {
        let animation = trackingAnimation
        let shouldAnimate = isActivelyTracking && animation != .none
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
        } else if store.pendingDayEnd != nil {
            promptForDayEndIfNeeded()
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

        if store.pendingDayEnd != nil {
            menu.addItem(item("Set Stop Time…", #selector(showDayEndPrompt), symbol: "clock"))
        } else {
            if store.isRunning {
                menu.addItem(item("Change Current Session Start…", #selector(editCurrentSessionStart), symbol: "clock.arrow.circlepath"))
            }
            menu.addItem(store.isRunning
                ? item("Stop Tracking", #selector(toggleTracking), symbol: "stop.fill")
                : item("Start Tracking", #selector(toggleTracking), symbol: "play.fill"))
        }
        menu.addItem(item("Sessions & Charts…", #selector(openMainWindow), key: "l", symbol: "chart.bar.xaxis"))
        menu.addItem(.separator())

        let autoCompleteMenu = NSMenu()
        for mode in AutoCompleteMode.allCases {
            let modeItem = item(mode.title, #selector(selectAutoComplete(_:)))
            modeItem.representedObject = mode.rawValue
            modeItem.state = mode == AutoCompleteMode.current ? .on : .off
            autoCompleteMenu.addItem(modeItem)
        }
        let autoCompleteParent = NSMenuItem(title: "Auto Complete", action: nil, keyEquivalent: "")
        autoCompleteParent.submenu = autoCompleteMenu
        menu.addItem(autoCompleteParent)

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
        if store.pendingDayEnd != nil {
            return "Set the time you stopped"
        }
        if let start = store.activeStart {
            return "Running since \(start.formatted(time))"
        }
        if let auto = store.lastAutoStop {
            let why: String
            switch auto.reason {
            case .idle: why = "idle 5 min"
            case .sleep: why = "Mac slept"
            case .recovered: why = "app wasn't running"
            case .dayEnd: why = "woke the next day"
            case .manual, .quit: why = ""
            }
            return "Auto-stopped at \(auto.date.formatted(time)) (\(why))"
        }
        return "Stopped"
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
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
        present(window)
    }

    private func present(_ window: NSWindow?) {
        // Menu actions fire while the status menu is still dismissing, and macOS often declines
        // activation then. Wait for it to finish, and use the activation that can take focus from
        // the front app, since the cooperative NSApp.activate() is regularly refused for menu bar apps.
        DispatchQueue.main.async {
            (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(sync: notionSync, dataDirectory: store.dataDirectory))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "GrahamTracker Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    @objc private func syncNotionNow() {
        notionSync.sync()
    }

    @objc private func selectAutoComplete(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AutoCompleteMode(rawValue: raw) else { return }
        AutoCompleteMode.current = mode
    }

    @objc private func showDayEndPrompt() {
        promptForDayEndIfNeeded()
    }

    /// Asks what time yesterday's session ended. Shown on wake, and again if it was dismissed.
    private func promptForDayEndIfNeeded() {
        guard let suggested = store.pendingDayEnd, let start = store.activeStart else { return }
        if isShowingDayEndPrompt {
            (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
            return
        }
        isShowingDayEndPrompt = true
        defer { isShowingDayEndPrompt = false }
        updateStatusItem()

        let alert = NSAlert()
        alert.messageText = "What time did you stop working \(Self.dayPhrase(for: suggested))?"
        alert.informativeText = "Tracking was still on overnight. The time below is the last moment it was running — change it if that's not when you stopped."
        alert.addButton(withTitle: "Stop at This Time")

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: suggested)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!.addingTimeInterval(-1)
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinuteSecond
        picker.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        picker.minDate = max(start, dayStart)
        picker.maxDate = dayEnd
        picker.dateValue = min(max(suggested, picker.minDate ?? suggested), dayEnd)
        alert.accessoryView = picker
        alert.window.level = .floating

        (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.resolvePendingDayEnd(at: picker.dateValue)
        updateStatusItem()
    }

    private static func dayPhrase(for date: Date) -> String {
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return "on \(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))"
    }

    @objc private func selectTrackingAnimation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let animation = TrackingAnimation(rawValue: raw) else { return }
        trackingAnimation = animation
        animationFrame = 0
        updateStatusItem()
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
