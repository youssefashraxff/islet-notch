import AppKit

/// Replaces low-resolution posters with the full cover from Apple's public music catalog.
///
/// Browsers only give macOS a ~120 px poster. Looking one up sends the title, artist and album to Apple, so it
/// is limited to tracks that have all three (ordinary web videos have no album) and can be switched off.
/// No account, cookies or identifiers are sent.
@MainActor
final class ArtworkUpscaler {
    /// Posters at least this wide are left alone.
    private static let goodEnough = 500
    /// The poster is ~350 px on a Retina display; this leaves headroom without 3 MB downloads.
    private static let targetSize = 1200

    private var covers: [String: [NSImage]] = [:] // by artist + album
    private var misses = Set<String>()            // by track + poster
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0", "Accept-Language": "en"]
        return URLSession(configuration: config)
    }()

    func needsUpscale(_ info: NowPlayingInfo, poster: NSImage) -> Bool {
        poster.pixelWidth < Self.goodEnough && !info.title.isEmpty && !info.artist.isEmpty && !info.album.isEmpty
    }

    /// Already downloaded this session.
    func cached(_ info: NowPlayingInfo, poster: NSImage) -> NSImage? {
        guard let known = covers[albumKey(info)], let print = Fingerprint(poster) else { return nil }
        return known.first { Fingerprint($0)?.matches(print) ?? false }
    }

    /// The full cover, or nil if the catalog has none that looks like `poster`.
    func fetch(_ info: NowPlayingInfo, poster: NSImage, posterData: Data) async -> NSImage? {
        let missKey = "\(info.trackID)|\(posterData.hashValue)"
        guard !misses.contains(missKey), let target = Fingerprint(poster) else { return nil }
        do {
            for (term, entity) in [("\(info.title) \(info.artist)", "song"), ("\(info.album) \(info.artist)", "album")] {
                for url in try await candidates(term: term, entity: entity, info: info) {
                    guard let thumb = try await image(url, size: 200),
                          let print = Fingerprint(thumb), print.matches(target),
                          let full = try await image(url, size: Self.targetSize) else { continue }
                    if covers.count > 30 { covers.removeAll() }
                    covers[albumKey(info), default: []].append(full)
                    return full
                }
            }
            misses.insert(missKey)
        } catch {
            // Offline or cancelled: not remembered as a miss, so the next play tries again.
        }
        return nil
    }

    private func albumKey(_ info: NowPlayingInfo) -> String { "\(info.artist)|\(info.album)" }

    // MARK: Catalog

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            var artistName: String?
            var collectionName: String?
            var trackName: String?
            var artworkUrl100: String?
        }
        var results: [Item]
    }

    /// Cover URLs by the same artist, likeliest first.
    private func candidates(term: String, entity: String, info: NowPlayingInfo) async throws -> [URL] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [.init(name: "term", value: term), .init(name: "media", value: "music"),
                                 .init(name: "entity", value: entity), .init(name: "limit", value: "25")]
        let (data, _) = try await session.data(from: components.url!)
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw URLError(.badServerResponse) // rate limited: an HTML page or empty body
        }

        func score(_ item: SearchResponse.Item) -> Int {
            (Self.overlaps(item.collectionName, info.album) ? 2 : 0) + (Self.overlaps(item.trackName, info.title) ? 1 : 0)
        }
        var seen = Set<URL>()
        return response.results
            .filter { Self.overlaps($0.artistName, info.artist) || score($0) == 3 }
            .enumerated()
            .sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }
            .compactMap { $0.element.artworkUrl100.flatMap(URL.init(string:)) }
            .filter { $0.scheme == "https" && ($0.host ?? "").hasSuffix(".mzstatic.com") && seen.insert($0).inserted }
            .prefix(6)
            .map { $0 }
    }

    private func image(_ url: URL, size: Int) async throws -> NSImage? {
        let sized = url.deletingLastPathComponent().appendingPathComponent("\(size)x\(size)bb.jpg")
        let (data, response) = try await session.data(from: sized)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

    /// Ignores case, accents and punctuation; either may contain the other ("SOS" / "SOS (Deluxe)").
    private static func overlaps(_ a: String?, _ b: String) -> Bool {
        func simplify(_ s: String) -> String {
            String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        }
        let x = simplify(a ?? ""), y = simplify(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }
}

// MARK: - Visual comparison

/// A tiny thumbnail, for telling whether two images are the same cover at different resolutions.
private struct Fingerprint {
    private static let side = 16
    private let values: [Double]

    init?(_ image: NSImage) {
        let side = Self.side
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        values = (0..<side * side * 4).filter { $0 % 4 != 3 }.map { Double(bytes[$0]) / 255 }
    }

    /// Mean difference per channel, 0 (identical) ... 1.
    func distance(to other: Fingerprint) -> Double {
        zip(values, other.values).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(values.count)
    }

    func matches(_ other: Fingerprint) -> Bool { distance(to: other) < 0.06 }
}

extension NSImage {
    var pixelWidth: Int { representations.map(\.pixelsWide).max() ?? 0 }
}
