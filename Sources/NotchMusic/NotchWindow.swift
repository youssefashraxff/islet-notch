import AppKit
import Combine
import SwiftUI

// MARK: - Geometry

struct NotchGeometry: Equatable {
    var notchSize: CGSize
    var hasNotch: Bool

    /// The display picked in the ♪ menu if it's connected; otherwise the built-in display with a notch,
    /// then the main screen.
    static func preferredScreen() -> NSScreen {
        let screens = NSScreen.screens
        if let id = IsletSettings.preferredDisplayID, let match = screens.first(where: { $0.displayID == id }) {
            return match
        }
        if let name = IsletSettings.preferredDisplayName, let match = screens.first(where: { $0.localizedName == name }) {
            return match
        }
        return automaticScreen()
    }

    static func automaticScreen() -> NSScreen {
        NSScreen.screens.first { $0.hasNotch } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func of(_ screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notchSize: CGSize(width: width, height: screen.safeAreaInsets.top), hasNotch: true)
        }
        // No notch (external display / older Mac): draw a virtual one the height of the menu bar.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(notchSize: CGSize(width: 190, height: max(menuBar, 24)), hasNotch: false)
    }
}

// MARK: - State

enum NotchState: Hashable {
    case idle      // nothing playing: looks exactly like the hardware notch
    case compact   // artwork on the left "ear", live bars on the right
    case peek      // briefly expands on track change to show the title
    case expanded  // hover: full Now Playing widget
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published var geometry: NotchGeometry

    private(set) var isHovering = false
    private var isPeeking = false
    @Published private(set) var hasMedia = false
    private var isPlaying = false
    /// Paused long enough that the island has tucked itself back into the notch.
    private var isDormant = false
    private var peekTask: Task<Void, Never>?
    private var dormantTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(nowPlaying: NowPlayingService, geometry: NotchGeometry) {
        self.geometry = geometry

        nowPlaying.$info
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] has in
                self?.hasMedia = has
                self?.recompute()
            }
            .store(in: &cancellables)

        nowPlaying.$info
            .map { $0?.isPlaying ?? false }
            .removeDuplicates()
            .sink { [weak self] playing in self?.playbackChanged(playing) }
            .store(in: &cancellables)

        nowPlaying.trackChanged
            .sink { [weak self] in self?.peek() }
            .store(in: &cancellables)
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            isPeeking = false
            peekTask?.cancel()
            if IsletSettings.hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else if !isPlaying {
            // Show the paused track again after the user looked at it, then tuck away.
            scheduleDormant()
        }
        recompute()
    }

    // MARK: Collapse after pause (Dynamic Island behaviour)

    private func playbackChanged(_ playing: Bool) {
        isPlaying = playing
        if playing {
            dormantTask?.cancel()
            isDormant = false
        } else {
            scheduleDormant()
        }
        recompute()
    }

    private func scheduleDormant() {
        dormantTask?.cancel()
        isDormant = false
        guard IsletSettings.collapseWhenPaused else { return }
        dormantTask = Task { [weak self] in
            try? await Task.sleep(for: IsletSettings.collapseDelay)
            guard !Task.isCancelled, let self, !self.isPlaying else { return }
            self.isDormant = true
            self.recompute()
        }
    }

    /// Called when the ♪ menu toggle changes.
    func collapseSettingChanged() {
        if isPlaying { return }
        if IsletSettings.collapseWhenPaused { scheduleDormant() } else { dormantTask?.cancel(); isDormant = false }
        recompute()
    }

    private func peek() {
        guard !isHovering else { return }
        isPeeking = true
        recompute()
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isPeeking = false
            self?.recompute()
        }
    }

    private func recompute() {
        let next: NotchState
        if isHovering { next = .expanded }
        else if isPeeking && hasMedia { next = .peek }
        else if hasMedia && !isDormant { next = .compact }
        else { next = .idle }
        if next != state { state = next }
    }

    // MARK: Sizes (include the outward top flares)

    /// Expanded widget, below the notch strip.
    private static let playerHeight: CGFloat = 346

    var compactSide: CGFloat { geometry.notchSize.height + 12 }

    func topRadius(for state: NotchState) -> CGFloat {
        switch state {
        case .idle: return 0
        case .compact: return 6
        case .peek: return 10
        case .expanded: return 14
        }
    }

    func bottomRadius(for state: NotchState) -> CGFloat {
        switch state {
        case .idle: return 10
        case .compact: return 12
        case .peek: return 22
        case .expanded: return 32
        }
    }

    func size(for state: NotchState) -> CGSize {
        let w = geometry.notchSize.width, h = geometry.notchSize.height
        let flare = 2 * topRadius(for: state)
        switch state {
        case .idle:     return CGSize(width: w, height: h)
        case .compact:  return CGSize(width: w + 2 * compactSide + flare, height: h)
        case .peek:     return CGSize(width: max(w + 2 * compactSide + 60, 360) + flare, height: h + 54)
        case .expanded: return CGSize(width: max(w + 190, 380) + flare, height: h + (hasMedia ? Self.playerHeight : 120))
        }
    }

    /// Fixed transparent canvas the panel occupies; the shape animates inside it, with room for the glass shadow.
    var canvasSize: CGSize {
        let e = size(for: .expanded)
        return CGSize(width: e.width + 160, height: geometry.notchSize.height + Self.playerHeight + 80)
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit flattens Liquid Glass (no rim, lensing or shadow) in non-key windows. Report the active
    // *appearance* without becoming key, so keyboard focus stays in the user's app. Private selectors:
    // if a future macOS drops them the glass just renders flat.
    @objc(_hasActiveAppearance) dynamic var hasActiveAppearance: Bool { true }
    @objc(_hasKeyAppearance) dynamic var hasKeyAppearance: Bool { true }
}

/// Lets buttons respond on the first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let model: NotchViewModel
    private var screen: NSScreen
    private var monitors: [Any] = []
    private var exitWork: DispatchWorkItem?

    init(nowPlaying: NowPlayingService) {
        screen = NotchGeometry.preferredScreen()
        model = NotchViewModel(nowPlaying: nowPlaying, geometry: .of(screen))
        panel = NotchPanel(contentRect: .zero)

        let host = FirstMouseHostingView(rootView: NotchRootView(model: model, nowPlaying: nowPlaying))
        host.sizingOptions = [] // never let SwiftUI resize the panel
        panel.contentView = host
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        installMouseMonitors()
    }

    func collapseSettingChanged() {
        model.collapseSettingChanged()
    }

    func reposition() {
        screen = NotchGeometry.preferredScreen()
        model.geometry = .of(screen)
        let size = model.canvasSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    // The panel is click-through except while the cursor is over the island itself.
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.trackMouse()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.trackMouse()
            return event
        }) { monitors.append(local) }
    }

    private func trackMouse() {
        let point = NSEvent.mouseLocation
        let inside = hotRect().contains(point)
        panel.ignoresMouseEvents = !inside

        if inside {
            exitWork?.cancel()
            exitWork = nil
            model.setHovering(true)
        } else if model.isHovering, exitWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.exitWork = nil
                    self?.model.setHovering(false)
                }
            }
            exitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    /// Screen-space rect of the island in its current (or hovered) state.
    private func hotRect() -> NSRect {
        let state: NotchState = model.isHovering ? .expanded : model.state
        let size = model.size(for: state)
        let rect = NSRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        return rect.insetBy(dx: -4, dy: -4)
    }
}
