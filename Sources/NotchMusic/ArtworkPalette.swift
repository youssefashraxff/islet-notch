import AppKit
import SwiftUI

/// The artwork's major colours (up to three), adjusted so text on top of them stays readable.
struct ArtworkPalette: Equatable {
    /// sRGB components, 0...1. Always three entries, most prominent first, so gradients animate cleanly
    /// between covers; single-colour artwork repeats its colour.
    let colors: [SIMD3<Double>]

    /// Vivid colours for the top of the background.
    var tints: [Color] { colors.map(Self.color) }

    /// Darker versions for the bottom of the background, same hues.
    var deepTints: [Color] { colors.map { Self.color($0 * (colorScheme == .dark ? 0.78 : 0.88)) } }

    /// The most prominent colour.
    var tint: Color { tints[0] }

    private static func color(_ c: SIMD3<Double>) -> Color { Color(.sRGB, red: c.x, green: c.y, blue: c.z) }

    /// Light artwork gets black text, dark artwork gets white text.
    let colorScheme: ColorScheme

    init(major: SIMD3<Double>) { self.init(majors: [major]) }

    /// The first colour decides light or dark; the others are pulled into the same brightness band
    /// so labels stay readable wherever they sit on the gradient.
    init(majors: [SIMD3<Double>]) {
        let primary = majors.first ?? SIMD3(repeating: 0.2)
        let scheme: ColorScheme = Self.luminance(Self.vivid(primary)) > 0.28 ? .light : .dark
        var adjusted = majors.prefix(3).map { Self.adjust($0, for: scheme) }
        while adjusted.count < 3 { adjusted.append(adjusted.first ?? Self.adjust(primary, for: scheme)) }
        colors = adjusted
        colorScheme = scheme
    }

    /// Glass mutes colour, so start a little more vivid.
    private static func vivid(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let grey = SIMD3(repeating: c.sum() / 3)
        return (grey + (c - grey) * 1.7).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
    }

    private static func adjust(_ major: SIMD3<Double>, for scheme: ColorScheme) -> SIMD3<Double> {
        var c = vivid(major)
        if scheme == .light {
            while luminance(c) < 0.34 { c += (SIMD3(repeating: 1) - c) * 0.03 } // lift towards white
            while luminance(c) > 0.78 { c *= 0.98 } // pure white would lose the panel's edges
        } else {
            while luminance(c) > 0.14 { c *= 0.97 } // deepen, keeping the hue
            // Very dark colours read as black on glass; brighten them until the hue shows. Greys stay as they are.
            let isColourful = c.max() > 0.04 && (c.max() - c.min()) / c.max() > 0.35
            while isColourful, luminance(c) < 0.06, c.max() < 0.75 { c *= 1.04 }
        }
        return c
    }

    init?(image: NSImage) {
        guard let majors = Self.majorColors(of: image), !majors.isEmpty else { return nil }
        self.init(majors: majors)
    }

    /// WCAG relative luminance.
    private static func luminance(_ c: SIMD3<Double>) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z)
    }

    // MARK: Extraction

    /// Clusters the pixels (k-means) and ranks the groups by size, favouring colourful ones and those
    /// along the edges (usually the cover's backdrop). Returns up to three clearly distinct colours that
    /// each cover a real share of the artwork. An average would turn most covers to mud.
    private static func majorColors(of image: NSImage) -> [SIMD3<Double>]? {
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
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var picked: [SIMD3<Double>] = []
        for k in centers.indices.sorted(by: { score($0) > score($1) }) {
            guard picked.count < 3 else { break }
            if !picked.isEmpty {
                guard weights[k] / total >= 0.06 else { continue } // specks of colour don't earn a place
                guard picked.allSatisfy({ distance($0, centers[k]) > 0.025 }) else { continue } // near-duplicates
            }
            picked.append(centers[k])
        }
        return picked
    }
}
