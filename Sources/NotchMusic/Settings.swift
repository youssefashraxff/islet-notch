import AppKit

/// How the island's background is drawn.
enum PanelStyle: String, CaseIterable {
    /// The artwork's colours as a gradient over a blurred backdrop.
    case gradient
    /// Apple's clear Liquid Glass, tinted with the artwork's main colour.
    case liquidGlass

    var title: String {
        switch self {
        case .gradient: "Artwork Gradient"
        case .liquidGlass: "Liquid Glass"
        }
    }
}

/// User preferences shown in the ♪ menu, stored in UserDefaults.
enum IsletSettings {
    private static let defaults = UserDefaults.standard

    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// Light trackpad tap when the island expands on hover (#2).
    static var hapticFeedback: Bool {
        get { bool("hapticFeedback", default: true) }
        set { defaults.set(newValue, forKey: "hapticFeedback") }
    }

    /// Collapse to idle a few seconds after playback pauses (#3).
    static var collapseWhenPaused: Bool {
        get { bool("collapseWhenPaused", default: true) }
        set { defaults.set(newValue, forKey: "collapseWhenPaused") }
    }

    static let collapseDelay: Duration = .seconds(5)

    /// Display chosen in the Display submenu (#4); nil means automatic (built-in notched display).
    static var preferredDisplayID: CGDirectDisplayID? {
        get { (defaults.object(forKey: "preferredDisplayID") as? NSNumber)?.uint32Value }
        set {
            if let newValue { defaults.set(NSNumber(value: newValue), forKey: "preferredDisplayID") }
            else { defaults.removeObject(forKey: "preferredDisplayID") }
        }
    }

    /// Name of the chosen display, used to find it again if its ID changes after reconnecting.
    static var preferredDisplayName: String? {
        get { defaults.string(forKey: "preferredDisplayName") }
        set { defaults.set(newValue, forKey: "preferredDisplayName") }
    }

    /// Keep showing a playing music app when a browser tab or video takes over Now Playing (#5).
    static var preferMusicApps: Bool {
        get { bool("preferMusicApps", default: true) }
        set { defaults.set(newValue, forKey: "preferMusicApps") }
    }

    /// Background style chosen in the Style submenu. Read live by the island through @AppStorage.
    static let panelStyleKey = "panelStyle"

    static var panelStyle: PanelStyle {
        get { defaults.string(forKey: panelStyleKey).flatMap(PanelStyle.init(rawValue:)) ?? .gradient }
        set { defaults.set(newValue.rawValue, forKey: panelStyleKey) }
    }

    /// Bundle IDs that never take over the island (#5).
    static var ignoredApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "ignoredApps") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "ignoredApps") }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }
}

/// Display name for a bundle ID, e.g. "Spotify".
func appDisplayName(for bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}
