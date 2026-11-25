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

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchMusic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
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
