import AppKit
import SwiftUI

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingService

    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(IsletSettings.panelStyleKey) private var style: PanelStyle = .gradient

    var body: some View {
        let state = model.state
        let size = model.size(for: state)
        let shape = NotchShape(topRadius: model.topRadius(for: state),
                               bottomRadius: model.bottomRadius(for: state))

        ZStack(alignment: .top) {
            GlassBackground(shape: shape, isIdle: state == .idle, palette: nowPlaying.palette, style: style)

            content(for: state)
                .padding(.horizontal, model.topRadius(for: state))
                .frame(width: size.width, height: size.height, alignment: .top)
                .id(state)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.92, anchor: .top))
                        .animation(.easeOut(duration: 0.25).delay(0.08)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: state)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.hasMedia)
        .animation(.easeInOut(duration: 0.5), value: nowPlaying.palette)
        .animation(.easeInOut(duration: 0.3), value: style)
        // Labels and glass follow the artwork's brightness rather than the system's light/dark mode.
        .environment(\.colorScheme, nowPlaying.palette?.colorScheme ?? systemScheme)
    }

    @ViewBuilder
    private func content(for state: NotchState) -> some View {
        let h = model.geometry.notchSize.height
        switch state {
        case .idle:
            Color.clear
        case .compact:
            CompactRow(nowPlaying: nowPlaying, height: h)
        case .peek:
            PeekView(nowPlaying: nowPlaying, notchHeight: h)
        case .expanded:
            ExpandedView(nowPlaying: nowPlaying, notchHeight: h)
        }
    }
}

// MARK: - Background

/// Two styles, picked in the ♪ menu:
/// - Artwork Gradient: the artwork's major colours over a blurred backdrop, finished with a soft sheen.
/// - Liquid Glass: Apple's clear glass tinted with the cover's main colour (a blurred material before macOS 26).
/// Idle is covered in black so it still disappears into the hardware notch.
struct GlassBackground: View {
    let shape: NotchShape
    let isIdle: Bool
    let palette: ArtworkPalette?
    let style: PanelStyle

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            switch style {
            case .gradient:
                material.overlay(wash).overlay(gloss.opacity(isIdle ? 0 : 1))
            case .liquidGlass:
                liquidGlass
            }
        }
        .overlay(shape.fill(Color.black).opacity(isIdle ? 1 : 0))
    }

    private var material: some View {
        shape
            .fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }

    @ViewBuilder
    private var liquidGlass: some View {
        if #available(macOS 26.0, *) {
            // Clear glass keeps the desktop sharp in the middle and lenses it at the rim. Glass's own tint
            // (not a layer on top) colours it with the cover and dims it enough for the labels.
            let glass: Glass = palette.map { .clear.tint($0.tint.opacity(reduceTransparency ? 0.9 : 0.55)) }
                ?? .regular
            Color.clear.glassEffect(glass, in: shape)
        } else {
            material
        }
    }

    /// The artwork's major colours mixed across the panel, deepening downwards; the blur shows through
    /// just enough to stay translucent.
    @ViewBuilder
    private var wash: some View {
        if let palette {
            let top = palette.tints.map { $0.opacity(reduceTransparency ? 1 : 0.84) }
            let bottom = palette.deepTints.map { $0.opacity(reduceTransparency ? 1 : 0.92) }
            Group {
                if #available(macOS 15.0, *) {
                    // Bottom row is rotated against the top so each colour bleeds diagonally into the others.
                    MeshGradient(width: 3, height: 2,
                                 points: [[0, 0], [0.5, 0], [1, 0],
                                          [0, 1], [0.5, 1], [1, 1]],
                                 colors: [top[0], top[1], top[2],
                                          bottom[2], bottom[0], bottom[1]],
                                 smoothsColors: true)
                } else {
                    LinearGradient(colors: top, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(LinearGradient(colors: [.clear, bottom[0]], startPoint: .top, endPoint: .bottom)
                            .opacity(0.6))
                }
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
    }

    /// Light pooling along the lower lip.
    private var gloss: some View {
        shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.06), location: 0),
                                          .init(color: .clear, location: 0.35),
                                          .init(color: .clear, location: 0.8),
                                          .init(color: .white.opacity(0.03), location: 1)],
                                  startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
    }
}

extension Color {
    /// Full-strength white on dark artwork, black on light artwork.
    static let label = Color(nsColor: .textColor)
}

// MARK: - Notch shape (outward top flares + rounded bottom, like the hardware notch)

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4)
        let br = max(0, min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height - tr))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Compact (artwork | notch | bars)

struct CompactRow: View {
    @ObservedObject var nowPlaying: NowPlayingService
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: nowPlaying.artwork, size: height - 10, corner: 6)
                .padding(.leading, 8)
            Spacer(minLength: 0)
            AudioBarsView(isPlaying: nowPlaying.info?.isPlaying ?? false, maxHeight: height * 0.45)
                .padding(.trailing, 10)
        }
        .frame(height: height)
    }
}

// MARK: - Peek (track change)

struct PeekView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            CompactRow(nowPlaying: nowPlaying, height: notchHeight)
            VStack(spacing: 1) {
                Text(nowPlaying.info?.title ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.label)
                Text(nowPlaying.info?.artist ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.label.opacity(0.85))
            }
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Expanded widget

struct ExpandedView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // The strip beside the physical notch: source app on the left, bars on the right.
            HStack {
                if let icon = nowPlaying.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Spacer()
                AudioBarsView(isPlaying: nowPlaying.info?.isPlaying ?? false, maxHeight: 12)
            }
            .padding(.horizontal, 16)
            .frame(height: notchHeight)

            if let info = nowPlaying.info {
                VStack(spacing: 10) {
                    Button(action: nowPlaying.openSourceApp) {
                        ArtworkView(image: nowPlaying.artwork, size: 172, corner: 18)
                            .shadow(color: .black.opacity(0.22), radius: 11, y: 4)
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.96))
                    .pointerCursor()
                    .help("Open \(info.appBundleID)")

                    VStack(spacing: 2) {
                        Text(info.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.label)
                        Text(info.artist.isEmpty ? info.album : info.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.label.opacity(0.85))
                    }
                    .lineLimit(1)

                    if info.duration > 0 {
                        ProgressSection(info: info) { fraction in
                            nowPlaying.seek(toFraction: fraction)
                        }
                    }

                    HStack(spacing: 18) {
                        ControlButton(symbol: "backward.fill", size: 20, diameter: 40) { nowPlaying.send(.previous) }
                        ControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 30, diameter: 50) {
                            nowPlaying.togglePlayPause()
                        }
                        ControlButton(symbol: "forward.fill", size: 20, diameter: 40) { nowPlaying.send(.next) }
                    }
                    .frame(height: 50)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity) // stays centred when there's no progress bar (live streams)
            } else {
                NotPlayingView(message: nowPlaying.errorMessage)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

struct NotPlayingView: View {
    let message: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: message == nil ? "music.note" : "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.label.opacity(0.5))
            Text(message == nil ? "Not Playing" : "Now Playing Unavailable")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.label.opacity(0.85))
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.label.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Progress

struct ProgressSection: View {
    let info: NowPlayingInfo
    let onSeek: (Double) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = info.currentElapsed(at: context.date)
            VStack(spacing: 4) {
                ScrubBar(progress: elapsed / info.duration, onSeek: onSeek)
                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text("-" + Self.format(info.duration - elapsed))
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.label.opacity(0.8))
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let t = Int(seconds)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct ScrubBar: View {
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var dragProgress: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let p = max(0, min(1, dragProgress ?? progress))
            let active = hovering || dragProgress != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.label.opacity(0.2))
                Capsule().fill(Color.label.opacity(active ? 1 : 0.9))
                    .frame(width: geo.size.width * p)
            }
            .frame(height: active ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragProgress = max(0, min(1, $0.location.x / geo.size.width)) }
                    .onEnded { value in
                        onSeek(max(0, min(1, value.location.x / geo.size.width)))
                        dragProgress = nil
                    }
            )
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .frame(height: 14)
    }
}

// MARK: - Building blocks

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: ArtworkScaler.scaled(image, toPixels: Int((size * displayScale).rounded()))).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Shrinks covers to the exact pixels they're shown at. Letting the GPU shrink a 1200 px cover skips pixels,
/// which looks grainy.
@MainActor
enum ArtworkScaler {
    private static var cache: [Int: (source: NSImage, result: NSImage)] = [:] // by pixel size; latest cover only

    static func scaled(_ image: NSImage, toPixels side: Int) -> NSImage {
        if let hit = cache[side], hit.source === image { return hit.result }
        guard side > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              min(cg.width, cg.height) > side,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        let scale = CGFloat(side) / CGFloat(min(cg.width, cg.height)) // aspect fill
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        context.draw(cg, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        guard let output = context.makeImage() else { return image }
        let result = NSImage(cgImage: output, size: NSSize(width: side, height: side))
        cache[side] = (image, result)
        return result
    }
}

/// Dynamic-Island-style equaliser bars.
struct AudioBarsView: View {
    let isPlaying: Bool
    var barCount = 4
    var maxHeight: CGFloat = 14

    private static let speeds: [Double] = [5.3, 7.1, 4.4, 6.2, 5.8]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 4.6, 2.3]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.label)
                        .frame(width: 3, height: barHeight(i, t))
                }
            }
            .frame(height: maxHeight)
        }
        .animation(.easeOut(duration: 0.3), value: isPlaying)
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        guard isPlaying else { return 3 }
        let s = Self.speeds[i % Self.speeds.count]
        let ph = Self.phases[i % Self.phases.count]
        let v = (sin(t * s + ph) + sin(t * s * 1.73 + ph * 2)) / 4 + 0.5 // 0...1
        return 3 + CGFloat(v) * (maxHeight - 3)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let diameter: CGFloat
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.label)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .scaleEffect(hovering ? 1.12 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
