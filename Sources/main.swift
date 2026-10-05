// main.swift — starts Deskmate: the floating widget, the menu-bar icon, the Settings window
// and the two keyboard shortcuts.
import AppKit
import Carbon
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: KeyPanel!
    var host: NSHostingView<WidgetRoot>!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var news: NewsService!
    var calendar: CalendarService!
    var reminders: ReminderCenter!
    var bag = Set<AnyCancellable>()
    var hotkeys: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        let store = Store.shared
        news = NewsService()
        calendar = CalendarService()
        reminders = ReminderCenter(calendar: calendar)
        UIState.shared.openSettings = { [weak self] in self?.showSettings() }

        // The floating widget.
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false            // DragArea moves it, so text fields and buttons keep working
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = NSHostingView(rootView: WidgetRoot(news: news, calendar: calendar))
        panel.contentView = host
        applyLook(store.settings, firstTime: true)
        panel.orderFrontRegardless()

        store.$settings.removeDuplicates().sink { [weak self] s in
            DispatchQueue.main.async { self?.applyLook(s, firstTime: false); self?.registerHotkeys(s.general.hotkeys) }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .deskmateMoved).sink { [weak self] _ in self?.savePosition() }.store(in: &bag)

        // Menu-bar icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Deskmate")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Widget  ⌃⌥D", action: #selector(toggleWidget), keyEquivalent: "")
        menu.addItem(withTitle: "Open Vault  ⌃⌥V", action: #selector(openVault), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh News", action: #selector(refreshNews), keyEquivalent: "")
        menu.addItem(withTitle: "Show a Test Reminder", action: #selector(testReminder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Deskmate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        registerHotkeys(store.settings.general.hotkeys)
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--connect") { calendar.requestAccess() }   // same as clicking Connect Calendar
        if CommandLine.arguments.contains("--hourmap") {                               // open straight on the Hour Map
            store.settings.general.expanded = true; store.settings.general.tab = "time"; UIState.shared.timeMode = 1
        }
    }

    // MARK: Look and position

    var currentSize: CGSize {
        let s = Store.shared.settings
        return s.general.expanded ? CGSize(width: s.look.panelWidth, height: s.look.panelHeight) : badgeSize(s.look)
    }

    func applyLook(_ s: Settings, firstTime: Bool) {
        let size = currentSize
        // Keep the top-left corner fixed when the size changes.
        var topLeft: NSPoint
        if firstTime, let x = s.general.originX, let top = s.general.originTop { topLeft = NSPoint(x: x, y: top) }
        else if firstTime, let scr = NSScreen.main?.visibleFrame { topLeft = NSPoint(x: scr.maxX - size.width - 24, y: scr.maxY - 24) }
        else { topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }
        // Never let the widget land off-screen (e.g. after unplugging a monitor).
        if let scr = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main)?.visibleFrame {
            topLeft.x = min(max(topLeft.x, scr.minX), scr.maxX - min(size.width, scr.width))
            topLeft.y = min(max(topLeft.y, scr.minY + min(size.height, scr.height)), scr.maxY)
        }
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.alphaValue = CGFloat(s.look.opacity)
        panel.level = s.look.alwaysOnTop ? .floating : .normal
        switch s.look.mode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func savePosition() {
        Store.shared.settings.general.originX = panel.frame.minX
        Store.shared.settings.general.originTop = panel.frame.maxY
    }

    // MARK: Actions

    @objc func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func openVault() {
        Store.shared.settings.general.expanded = true
        Store.shared.settings.general.tab = "vault"
        panel.orderFrontRegardless()
    }

    @objc func refreshNews() { news.refresh() }
    @objc func testReminder() { reminders.showTest() }
    @objc func openSettings() { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: 592),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Deskmate Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(calendar: calendar, reminders: reminders, news: news))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Keyboard shortcuts (Carbon hot keys: no Accessibility permission needed)

    func registerHotkeys(_ on: Bool) {
        if on == !hotkeys.isEmpty { return }
        for h in hotkeys { if let h { UnregisterEventHotKey(h) } }
        hotkeys = []
        guard on else { return }
        if hotkeyHandlerInstalled == false {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async {
                    guard let d = NSApp.delegate as? AppDelegate else { return }
                    if id.id == 1 { d.toggleWidget() } else if id.id == 2 { d.openVault() }
                }
                return noErr
            }, 1, &spec, nil, nil)
            hotkeyHandlerInstalled = true
        }
        let mods = UInt32(controlKey | optionKey)
        for (n, key) in [(UInt32(1), UInt32(kVK_ANSI_D)), (UInt32(2), UInt32(kVK_ANSI_V))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x444B4D54), id: n), GetApplicationEventTarget(), 0, &ref)
            hotkeys.append(ref)
        }
    }
    var hotkeyHandlerInstalled = false
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu-bar app: no Dock icon
app.run()
