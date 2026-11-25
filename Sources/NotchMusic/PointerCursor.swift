import AppKit
import SwiftUI

extension View {
    /// Shows the pointing-hand cursor while hovered.
    func pointerCursor() -> some View { modifier(PointerCursor()) }
}

private struct PointerCursor: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active: CursorKeeper.shared.begin(id)
                case .ended: CursorKeeper.shared.end(id)
                }
            }
            .onDisappear { CursorKeeper.shared.end(id) } // the island can collapse under the cursor
    }
}

/// `.pointerStyle(.link)` and cursor rects do nothing here: the panel never becomes key and the app is never
/// active, so macOS leaves the cursor to the frontmost app. This sets it by hand, and keeps checking, because
/// the app underneath can take the cursor back while the mouse is still.
@MainActor
final class CursorKeeper {
    static let shared = CursorKeeper()

    private var hovered = Set<UUID>()
    private var timer: Timer?

    /// Call at launch, before anything sets a cursor. Turns on a private window-server property that lets an
    /// inactive app change the cursor; if a future macOS drops it, the cursor just stays an arrow.
    func enable() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let allImages = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(allImages, "_CGSDefaultConnection"),
              let setProperty = dlsym(allImages, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(
            id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    func begin(_ id: UUID) {
        hovered.insert(id)
        showHand()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func end(_ id: UUID) {
        guard hovered.remove(id) != nil, hovered.isEmpty else { return }
        stop()
    }

    private func tick() {
        // Never hold the cursor once the mouse is over another app's window, even if a hover-end got lost.
        let window = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard NSApp.windows.contains(where: { $0.windowNumber == window }) else {
            hovered.removeAll()
            stop()
            return
        }
        showHand()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        force(.arrow, over: .pointingHand)
    }

    private func showHand() {
        let hand = NSCursor.pointingHand
        if let shown = NSCursor.currentSystem, shown.hotSpot == hand.hotSpot, shown.image.size == hand.image.size { return }
        force(hand, over: .arrow)
    }

    /// AppKit skips `set()` when it believes that cursor is already current, which it can't know once another
    /// app has changed it. Setting a different one first makes the second call take effect.
    private func force(_ cursor: NSCursor, over other: NSCursor) {
        other.set()
        cursor.set()
    }
}
