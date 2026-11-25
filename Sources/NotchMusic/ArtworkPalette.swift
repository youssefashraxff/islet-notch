import AppKit
import SwiftUI

/// The artwork's major colour, adjusted so text on top of it stays readable.
struct ArtworkPalette: Equatable {
    /// sRGB components, 0...1.
    let rgb: SIMD3<Double>

    /// Vivid top of the background gradient.
    var tint: Color { Self.color(rgb) }

    /// Darker bottom of the gradient, same hue.
    var deepTint: Color { Self.color(rgb * (colorScheme == .dark ? 0.6 : 0.86)) }

    private static func color(_ c: SIMD3<Double>) -> Color { Color(.sRGB, red: c.x, green: c.y, blue: c.z) }

    /// Light artwork gets black text, dark artwork gets white text.
    let colorScheme: ColorScheme

    init(major: SIMD3<Double>) {
        // Glass mutes colour, so start a little more vivid.
        let grey = SIMD3(repeating: major.sum() / 3)
        var c = (grey + (major - grey) * 1.4).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))

        if Self.luminance(c) > 0.28 {
            colorScheme = .light
            while Self.luminance(c) < 0.34 { c += (SIMD3(repeating: 1) - c) * 0.03 } // lift towards white
            while Self.luminance(c) > 0.78 { c *= 0.98 } // pure white would lose the panel's edges
        } else {
            colorScheme = .dark
            while Self.luminance(c) > 0.14 { c *= 0.97 } // deepen, keeping the hue
            // Very dark colours read as black on glass; brighten them until the hue shows. Greys stay as they are.
            let isColourful = c.max() > 0.04 && (c.max() - c.min()) / c.max() > 0.35
            while isColourful, Self.luminance(c) < 0.06, c.max() < 0.75 { c *= 1.04 }
        }
        rgb = c
    }

    init?(image: NSImage) {
        guard let major = Self.majorColor(of: image) else { return nil }
        self.init(major: major)
    }

    /// WCAG relative luminance.
    private static func luminance(_ c: SIMD3<Double>) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
    }

    // MARK: Extraction

    /// Clusters the pixels (k-means) and picks the largest group, favouring colourful ones and those
    /// along the edges (usually the cover's backdrop). An average would turn most covers to mud.
    private static func majorColor(of image: NSImage) -> SIMD3<Double>? {
        let side = 40
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var pixels: [(color: SIMD3<Double>, weight: Double)] = []
        pixels.reserveCapacity(side * side)
        let border = 3
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                guard bytes[i + 3] > 200 else { continue } // skip transparent pixels
                let isEdge = min(x, y, side - 1 - x, side - 1 - y) < border
                pixels.append((SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2])) / 255,
                               isEdge ? 2 : 1))
            }
        }
        guard let first = pixels.first else { return nil }

        func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { ((a - b) * (a - b)).sum() }
        func nearest(_ c: SIMD3<Double>, in centers: [SIMD3<Double>]) -> Int {
            centers.indices.min { distance(c, centers[$0]) < distance(c, centers[$1]) } ?? 0
        }

        // Farthest-point seeding: deterministic, so a cover always yields the same colour.
        var centers = [first.color]
        while centers.count < 6,
              let far = pixels.map({ p in (p.color, distance(p.color, centers[nearest(p.color, in: centers)])) })
                  .max(by: { $0.1 < $1.1 }), far.1 > 0.005 {
            centers.append(far.0)
        }

        var weights = [Double](repeating: 0, count: centers.count)
        for _ in 0..<8 {
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            weights = [Double](repeating: 0, count: centers.count)
            for p in pixels {
                let k = nearest(p.color, in: centers)
                sums[k] += p.color * p.weight
                weights[k] += p.weight
            }
            for k in centers.indices where weights[k] > 0 { centers[k] = sums[k] / weights[k] }
        }

        func score(_ k: Int) -> Double {
            let chroma = centers[k].max() - centers[k].min()
            return weights[k] * (0.15 + chroma)
        }
        return centers.indices.max { score($0) < score($1) }.map { centers[$0] }
    }
}
