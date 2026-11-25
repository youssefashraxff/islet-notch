import AppKit
import Combine
import SwiftUI

/// Snapshot of what macOS reports in Control Center's "Now Playing".
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var appBundleID: String
    var isPlaying: Bool
    var duration: Double      // seconds, 0 if unknown (live streams)
    var elapsed: Double       // seconds, as of `timestamp`
    var timestamp: Date
    var playbackRate: Double

    var trackID: String { "\(title)|\(artist)|\(album)" }

    /// Extrapolates the playhead so the progress bar moves smoothly between updates.
    func currentElapsed(at date: Date = Date()) -> Double {
        var value = elapsed
        if isPlaying {
            value += date.timeIntervalSince(timestamp) * (playbackRate > 0 ? playbackRate : 1)
        }
        value = max(0, value)
        return duration > 0 ? min(value, duration) : value
    }
}

/// MediaRemote command IDs understood by mediaremote-adapter's `send` command.
enum MediaCommand: Int {
    case play = 0, pause = 1, togglePlayPause = 2, stop = 3, next = 4, previous = 5
}

/// Paths to the bundled mediaremote-adapter (Perl script + framework).
struct AdapterPaths {
    let script: URL
    let framework: URL

    static func locate() -> AdapterPaths? {
        let fm = FileManager.default
        var candidates: [AdapterPaths] = []

        // 1. Inside the bundled .app (Scripts/bundle.sh puts them here)
        if let res = Bundle.main.resourceURL, let fw = Bundle.main.privateFrameworksURL {
            candidates.append(AdapterPaths(
                script: res.appendingPathComponent("mediaremote-adapter.pl"),
                framework: fw.appendingPathComponent("MediaRemoteAdapter.framework")))
        }

        // 2. Development: Vendor/MediaRemoteAdapter next to Package.swift
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NOTCHMUSIC_ADAPTER_DIR"] {
            dirs.append(URL(fileURLWithPath: env))
        }
        dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Vendor/MediaRemoteAdapter"))
        if var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            for _ in 0..<5 { // .build/<triple>/debug/NotchMusic -> project root
                dirs.append(dir.appendingPathComponent("Vendor/MediaRemoteAdapter"))
                dir.deleteLastPathComponent()
            }
        }
        candidates += dirs.map {
            AdapterPaths(script: $0.appendingPathComponent("mediaremote-adapter.pl"),
                         framework: $0.appendingPathComponent("MediaRemoteAdapter.framework"))
        }

        return candidates.first { fm.fileExists(atPath: $0.script.path) && fm.fileExists(atPath: $0.framework.path) }
    }
}

/// Reads system-wide Now Playing info.
///
/// Since macOS 15.4, `mediaremoted` only answers entitled (Apple-signed) clients, so a normal app
/// can't call MediaRemote.framework directly. mediaremote-adapter works around this by running
/// the query inside `/usr/bin/perl` (an Apple binary) and streaming JSON lines back to us.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: ArtworkPalette?
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var errorMessage: String?

    /// Fires when a different track starts (used for the Dynamic-Island "peek").
    let trackChanged = PassthroughSubject<Void, Never>()

    private let adapter = AdapterPaths.locate()
    private let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private var process: Process?
    private var buffer = Data()
    private var lastArtworkData: Data?
    private let upscaler = ArtworkUpscaler()
    private var upscaleTask: Task<Void, Never>?
    private var lastBundleID: String?
    private var isStopping = false

    // MARK: Lifecycle

    func start() {
        guard process == nil else { return }
        guard let adapter else {
            errorMessage = "Adapter not found. Run Scripts/setup-adapter.sh"
            return
        }
        isStopping = false

        let p = Process()
        p.executableURL = perl
        p.arguments = [adapter.script.path, adapter.framework.path,
                       "stream", "--no-diff", "--micros", "--debounce=60"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { // FIFO, keeps lines in order
                MainActor.assumeIsolated { self?.consume(chunk) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleTermination(status: status) }
            }
        }

        do {
            try p.run()
            process = p
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't launch adapter: \(error.localizedDescription)"
        }
    }

    func stop() {
        isStopping = true
        process?.terminate()
        process = nil
    }

    private func handleTermination(status: Int32) {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        guard !isStopping else { return }
        if status == 0 {
            // Clean exit we didn't ask for: restart shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
        } else {
            // The adapter docs advise against re-running after a fatal error.
            errorMessage = "Now Playing adapter stopped (code \(status))."
        }
    }

    // MARK: Parsing

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return }
        apply(payload)
    }

    private func apply(_ payload: [String: Any]) {
        guard let title = payload["title"] as? String, !title.isEmpty else {
            upscaleTask?.cancel()
            info = nil
            artwork = nil
            lastArtworkData = nil
            palette = nil
            return
        }

        func number(_ key: String) -> Double { (payload[key] as? NSNumber)?.doubleValue ?? 0 }

        let playing = (payload["playing"] as? Bool) ?? false
        let bundleID = (payload["parentApplicationBundleIdentifier"] as? String)
            ?? (payload["bundleIdentifier"] as? String) ?? ""
        let timestamp = (payload["timestampEpochMicros"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1_000_000) } ?? Date()

        let new = NowPlayingInfo(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            appBundleID: bundleID,
            isPlaying: playing,
            duration: number("durationMicros") / 1_000_000,
            elapsed: number("elapsedTimeMicros") / 1_000_000,
            timestamp: timestamp,
            playbackRate: (payload["playbackRate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0)
        )

        let isNewTrack = info?.trackID != new.trackID
        info = new
        updateAppIcon(for: bundleID)

        if let b64 = payload["artworkData"] as? String,
           let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            if data != lastArtworkData, let image = NSImage(data: data) {
                lastArtworkData = data
                artwork = image
                palette = ArtworkPalette(image: image)
                upscaleArtwork()
            } else if isNewTrack {
                upscaleArtwork() // same cover, but this title may be in the catalog when the last one wasn't
            }
        } else if isNewTrack {
            upscaleTask?.cancel()
            artwork = nil
            lastArtworkData = nil
            palette = nil
        }

        if isNewTrack { trackChanged.send() }
    }

    // MARK: High-resolution artwork

    private static let highResKey = "highResolutionPosters"

    var highResPosters: Bool {
        get { UserDefaults.standard.object(forKey: Self.highResKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.highResKey)
            if newValue {
                upscaleArtwork()
            } else {
                upscaleTask?.cancel()
                artwork = lastArtworkData.flatMap(NSImage.init(data:))
            }
        }
    }

    /// Shows the poster we were given straight away, then swaps in the full cover once it's downloaded.
    private func upscaleArtwork() {
        upscaleTask?.cancel()
        guard highResPosters, let info, let poster = artwork, let data = lastArtworkData,
              upscaler.needsUpscale(info, poster: poster) else { return }
        if let cover = upscaler.cached(info, poster: poster) {
            artwork = cover
            return
        }
        upscaleTask = Task { [weak self, upscaler] in
            let cover = await upscaler.fetch(info, poster: poster, posterData: data)
            guard let self, let cover, !Task.isCancelled, self.lastArtworkData == data else { return }
            self.artwork = cover
        }
    }

    private func updateAppIcon(for bundleID: String) {
        guard bundleID != lastBundleID else { return }
        lastBundleID = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            appIcon = nil
        }
    }

    // MARK: Controls

    func send(_ command: MediaCommand) {
        runOneShot(["send", String(command.rawValue)])
    }

    func togglePlayPause() {
        if var current = info { // optimistic update so the UI reacts instantly
            current.elapsed = current.currentElapsed()
            current.timestamp = Date()
            current.isPlaying.toggle()
            info = current
        }
        send(.togglePlayPause)
    }

    func seek(toFraction fraction: Double) {
        guard var current = info, current.duration > 0 else { return }
        let seconds = max(0, min(1, fraction)) * current.duration
        current.elapsed = seconds
        current.timestamp = Date()
        info = current
        runOneShot(["seek", String(max(1, Int(seconds * 1_000_000)))])
    }

    func openSourceApp() {
        guard let id = info?.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func runOneShot(_ args: [String]) {
        guard let adapter else { return }
        let p = Process()
        p.executableURL = perl
        p.arguments = [adapter.script.path, adapter.framework.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
