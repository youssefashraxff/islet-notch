# Islet

**A Dynamic Island for the MacBook notch.** Whatever is playing (Anghami, Spotify, Apple Music, YouTube in any browser, podcasts, VLC…) shows up around the camera notch.

Native SwiftUI · macOS 14+ · Liquid Glass on macOS 26 · Free and open source (MIT)

<!-- Demo: drag the launch video or a screenshot into this README on GitHub to embed it here. -->

| State | When | What you see |
|---|---|---|
| Idle | Nothing playing | Blends into the hardware notch |
| Compact | Media loaded | Artwork on the left ear, equaliser bars on the right |
| Peek | Track changes | Island drops down for 3 s with title + artist |
| Expanded | Hover the notch | Full player: large artwork (click to open the source app), title, artist, scrubbable progress, prev / play-pause / next |

The island is Liquid Glass on macOS 26+ (a blurred material on 14 and 15), tinted with the artwork's major colour. Text turns black or white to suit that colour; without artwork it follows light/dark mode. Idle stays black to match the notch.

Works on Macs without a notch too (draws a virtual one under the menu bar).

## Install

Requires macOS 14+ and the Xcode Command Line Tools.

```bash
git clone https://github.com/youssefashraxff/islet-notch.git
cd islet-notch
xcode-select --install          # if you don't have the Command Line Tools
brew install cmake
./Scripts/setup-adapter.sh      # builds the Now Playing adapter into Vendor/
./Scripts/bundle.sh             # builds build/Islet.app
mv build/Islet.app /Applications/ && open /Applications/Islet.app
```

For development, `swift run` (or open `Package.swift` in Xcode). On macOS 27+ without full Xcode, prefix with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk` (Command Line Tools 27+ omits the `SwiftUIMacros` plugin; `bundle.sh` applies this fallback automatically).

Prebuilt, ad-hoc signed builds are attached to each [release](https://github.com/youssefashraxff/islet-notch/releases). They aren't notarized, so after unzipping run `xattr -dr com.apple.quarantine Islet.app` (or right-click → Open) the first time.

Islet lives in the menu bar (♪):

- **Launch at Login**
- **High-Resolution Posters**: full-size covers from Apple's catalog (see below)
- **Haptic Feedback**: a light trackpad tap when the island expands on hover
- **Collapse When Paused**: tucks the island back into the notch 5 s after playback pauses, like the iPhone. It comes back on play, on a track change, or when you hover the notch
- **Style**: **Artwork Gradient** (the cover's colours over a blur) or **Liquid Glass** (Apple's glass on its own)
- **Display**: pick which display shows the island. **Automatic** uses the built-in notched display, otherwise the main one
- **Media Sources**: **Prefer Music Apps** keeps a playing music app (Apple Music, Spotify, Anghami, Deezer, TIDAL, Podcasts…) on the island when a browser tab or video also starts playing. Under **Ignore**, tick apps that should never take over the island

### Multiple media sources

macOS only reports one Now Playing app at a time: whichever started playing last. When a browser takes over from a music app that's still playing, Islet keeps showing the music app's last track until that track would have ended, the app quits, or the app reports again. While it's held, the controls drive Apple Music and Spotify directly with AppleScript (macOS asks once for permission); for other music apps they bring the app to the front.

## How Now Playing works

Since macOS 15.4, `mediaremoted` refuses Now Playing requests from non-Apple processes, so calling the private MediaRemote.framework directly returns nothing. Islet uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), which runs the query inside `/usr/bin/perl` (Apple-signed, so entitled) and streams JSON lines. `NowPlayingService` launches `perl mediaremote-adapter.pl <framework> stream --no-diff --micros` and parses each line; controls use `send <id>` and `seek <µs>`.

This is a private-API workaround: Islet can't ship on the App Store, and a future macOS update can break it.

Browsers only give macOS a ~120 px poster, so for music (tracks with a title, artist and album) the full cover is looked up in Apple's public catalog and used if it matches the small one. That sends the title, artist and album to Apple, without an account or cookies. Turn it off with **High-Resolution Posters** in the ♪ menu.

## Files

The Swift package and executable keep the code name `NotchMusic`; the app is named Islet.

- `NotchMusicApp.swift`: entry point, accessory app, menu-bar item and submenus, Launch at Login
- `Settings.swift`: menu preferences stored in UserDefaults
- `NowPlayingService.swift`: adapter process, JSON parsing, source priority and ignored apps, media controls
- `ArtworkPalette.swift`: major colour of the artwork and the matching text colour
- `NotchWindow.swift`: display choice, notch geometry, state machine (incl. collapse after pause), click-through overlay panel, hover tracking and haptics
- `ArtworkUpscaler.swift`: full-resolution covers from Apple's catalog
- `PointerCursor.swift`: pointing-hand cursor over buttons (private API, since the app is never active)
- `NotchViews.swift`: SwiftUI: notch shape, compact / peek / expanded views, equaliser, scrubber

## Contributing

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
