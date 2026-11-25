# NotchMusic

A Dynamic Island for the MacBook notch. Whatever is playing (Spotify, Apple Music, YouTube in any browser, podcasts, VLC…) shows up around the camera notch.

| State | When | What you see |
|---|---|---|
| Idle | Nothing playing | Blends into the hardware notch |
| Compact | Media loaded | Artwork on the left ear, equaliser bars on the right |
| Peek | Track changes | Island drops down for 3 s with title + artist |
| Expanded | Hover the notch | Full widget: large centred artwork (click to open source app), title, artist, scrubbable progress, prev / play-pause / next |

The island is Liquid Glass on macOS 26+ (a blurred material on 14 and 15), tinted with the artwork's major colour. Text turns black or white to suit that colour; without artwork it follows light/dark mode. Idle stays black to match the notch.

Browsers only give macOS a ~120 px poster, so for music (tracks with a title, artist and album) the full cover is looked up in Apple's public catalog and used if it matches the small one. That sends the title, artist and album to Apple, without an account or cookies. Turn it off with **High-Resolution Posters** in the ♪ menu.

Works on Macs without a notch too (draws a virtual one under the menu bar). Requires macOS 14+.

## Setup

```bash
xcode-select --install          # if you don't have the Command Line Tools
brew install cmake
./Scripts/setup-adapter.sh      # builds the Now Playing adapter into Vendor/
swift run                       # dev run (or: open Package.swift in Xcode)
```

Build a real app (needed for Launch at Login):

```bash
./Scripts/bundle.sh
mv build/NotchMusic.app /Applications/
```

Quit from the ♪ menu-bar icon.

## How Now Playing works

Since macOS 15.4, `mediaremoted` refuses Now Playing requests from non-Apple processes, so calling the private MediaRemote.framework directly returns nothing. NotchMusic uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), which runs the query inside `/usr/bin/perl` (Apple-signed, so entitled) and streams JSON lines. `NowPlayingService` launches `perl mediaremote-adapter.pl <framework> stream --no-diff --micros` and parses each line; controls use `send <id>` and `seek <µs>`.

This is a private-API workaround: not App Store eligible, and a future macOS update can break it.

## Files

- `NotchMusicApp.swift`: entry point, accessory app, menu-bar item, Launch at Login
- `NowPlayingService.swift`: adapter process, JSON parsing, media controls
- `ArtworkPalette.swift`: major colour of the artwork and the matching text colour
- `NotchWindow.swift`: notch geometry, state machine, click-through overlay panel, hover tracking
- `ArtworkUpscaler.swift`: full-resolution covers from Apple's catalog
- `PointerCursor.swift`: pointing-hand cursor over buttons (private API, since the app is never active)
- `NotchViews.swift`: SwiftUI: notch shape, compact / peek / expanded views, equaliser, scrubber
