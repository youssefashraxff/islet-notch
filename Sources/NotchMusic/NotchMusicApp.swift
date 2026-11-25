import AppKit
import ServiceManagement

@main
enum NotchMusicMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon, no app menu
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let nowPlaying = NowPlayingService()
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CursorKeeper.shared.enable()

        let controller = NotchWindowController(nowPlaying: nowPlaying)
        controller.show()
        notchController = controller

        setupStatusItem()
        nowPlaying.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
    }

    @objc private func screensChanged() {
        notchController?.reposition()
    }

    // MARK: Menu bar item (the only way to quit an accessory app)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NotchMusic")

        let menu = NSMenu()

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let posters = NSMenuItem(title: "High-Resolution Posters", action: #selector(toggleHighResPosters(_:)), keyEquivalent: "")
        posters.target = self
        posters.state = nowPlaying.highResPosters ? .on : .off
        posters.toolTip = "Looks up low-resolution music covers in Apple's catalog, sending the title, artist and album."
        menu.addItem(posters)

        let haptics = NSMenuItem(title: "Haptic Feedback", action: #selector(toggleHaptics(_:)), keyEquivalent: "")
        haptics.target = self
        haptics.state = IsletSettings.hapticFeedback ? .on : .off
        haptics.toolTip = "A light trackpad tap when the island expands."
        menu.addItem(haptics)

        let collapse = NSMenuItem(title: "Collapse When Paused", action: #selector(toggleCollapse(_:)), keyEquivalent: "")
        collapse.target = self
        collapse.state = IsletSettings.collapseWhenPaused ? .on : .off
        collapse.toolTip = "Tuck the island back into the notch a few seconds after playback pauses."
        menu.addItem(collapse)

        menu.addItem(.separator())
        menu.addItem(submenu(title: "Display", menu: displayMenu))
        menu.addItem(submenu(title: "Media Sources", menu: sourcesMenu))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Islet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    private let displayMenu = NSMenu(title: "Display")
    private let sourcesMenu = NSMenu(title: "Media Sources")

    private func submenu(title: String, menu: NSMenu) -> NSMenuItem {
        menu.delegate = self
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func toggleHaptics(_ sender: NSMenuItem) {
        IsletSettings.hapticFeedback.toggle()
        sender.state = IsletSettings.hapticFeedback ? .on : .off
    }

    @objc private func toggleCollapse(_ sender: NSMenuItem) {
        IsletSettings.collapseWhenPaused.toggle()
        sender.state = IsletSettings.collapseWhenPaused ? .on : .off
        notchController?.collapseSettingChanged()
    }

    // MARK: Display submenu (#4)

    private func rebuildDisplayMenu() {
        displayMenu.removeAllItems()
        let current = NotchGeometry.preferredScreen()
        let isAutomatic = IsletSettings.preferredDisplayID == nil && IsletSettings.preferredDisplayName == nil

        let auto = NSMenuItem(title: "Automatic", action: #selector(chooseDisplay(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = isAutomatic ? .on : .off
        auto.toolTip = "The built-in display with the notch, or the main display."
        displayMenu.addItem(auto)
        displayMenu.addItem(.separator())

        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let title = screen.localizedName + (screen.hasNotch ? " (Notch)" : "")
            let item = NSMenuItem(title: title, action: #selector(chooseDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: id)
            item.state = !isAutomatic && screen == current ? .on : .off
            displayMenu.addItem(item)
        }
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        if let id = (sender.representedObject as? NSNumber)?.uint32Value,
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            IsletSettings.preferredDisplayID = id
            IsletSettings.preferredDisplayName = screen.localizedName
        } else {
            IsletSettings.preferredDisplayID = nil
            IsletSettings.preferredDisplayName = nil
        }
        notchController?.reposition()
    }

    // MARK: Media Sources submenu (#5)

    private func rebuildSourcesMenu() {
        sourcesMenu.removeAllItems()

        let prefer = NSMenuItem(title: "Prefer Music Apps", action: #selector(togglePreferMusic(_:)), keyEquivalent: "")
        prefer.target = self
        prefer.state = nowPlaying.preferMusicApps ? .on : .off
        prefer.toolTip = "Keep showing Apple Music, Spotify, Anghami and other music apps while a browser tab or video also plays."
        sourcesMenu.addItem(prefer)
        sourcesMenu.addItem(.separator())

        let header = NSMenuItem(title: "Ignore", action: nil, keyEquivalent: "")
        header.isEnabled = false
        sourcesMenu.addItem(header)

        let ignored = IsletSettings.ignoredApps
        var ids = nowPlaying.recentSources
        ids += ignored.subtracting(ids).sorted()
        if ids.isEmpty {
            let none = NSMenuItem(title: "Play something to list its app", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sourcesMenu.addItem(none)
        }
        for id in ids {
            let item = NSMenuItem(title: appDisplayName(for: id), action: #selector(toggleIgnored(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = ignored.contains(id) ? .on : .off
            item.toolTip = "Never show media from \(id) in the island."
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            sourcesMenu.addItem(item)
        }
    }

    @objc private func togglePreferMusic(_ sender: NSMenuItem) {
        nowPlaying.preferMusicApps.toggle()
    }

    @objc private func toggleIgnored(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        nowPlaying.setIgnored(id, !IsletSettings.ignoredApps.contains(id))
    }

    @objc private func toggleHighResPosters(_ sender: NSMenuItem) {
        nowPlaying.highResPosters.toggle()
        sender.state = nowPlaying.highResPosters ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep() // only works from the bundled .app, not `swift run`
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === displayMenu { rebuildDisplayMenu() }
        else if menu === sourcesMenu { rebuildSourcesMenu() }
    }
}
