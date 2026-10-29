<div align="center">

# LoadTube

**A native macOS downloader for video and music — no ads, no account inside the app, no browser.**

[![macOS](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](#build-from-source)
[![Version](https://img.shields.io/badge/version-1.3.1-2F81F7)](#changelog)
[![Personal use](https://img.shields.io/badge/license-personal%20use-lightgrey)](#license--credits)

**English** · [Русский](README.ru.md)

</div>

---

LoadTube is a small SwiftUI app that puts a friendly face on `yt-dlp` and `ffmpeg`:

- paste a link, pick a quality, press **Download**;
- the file lands in your Downloads folder, tagged and ready to play;
- Spotify, Tidal, Instagram and TikTok get dedicated handling instead of generic “it might work”.

It is built for personal use on macOS 14+ and runs entirely on your Mac.

## Contents

- [What you get](#what-you-get)
- [Supported sources](#supported-sources)
- [Quality presets](#quality-presets)
- [Install](#install)
- [Build from source](#build-from-source)
- [Usage](#usage)
- [Instagram & TikTok](#instagram--tiktok)
- [Spotify](#spotify)
- [Tidal](#tidal)
- [Updates](#updates)
- [Interface language](#interface-language)
- [How it works](#how-it-works)
- [Project structure](#project-structure)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [License & credits](#license--credits)
- [Changelog](#changelog)

## What you get

| | Feature | Details |
|---|---|---|
| 🎚️ | **Four quality presets** | Maximum (up to 8K/60/HDR), 4K MP4, 1080p MP4, MP3 |
| ⚡ | **Parallel queue** | Two downloads at a time, the rest wait their turn |
| 📋 | **Paste & drop** | Paste from the clipboard or drag a link straight into the window |
| 📁 | **Playlists** | YouTube playlists and Instagram carousels go into a numbered folder |
| 🔔 | **Notifications** | A notification when a download finishes, plus “Show in Finder” and “Open file” |
| 🌗 | **Themes** | Dark, light or system appearance |
| 🌍 | **Two languages** | Russian and English, switchable on the fly |
| 📦 | **Zero setup** | On first launch the app downloads portable `yt-dlp` and `ffmpeg` (~120 MB) — no Homebrew required |
| 🔄 | **Soft updates** | Once a day it checks GitHub Releases and offers a new version; nothing is installed without your consent |

## Supported sources

| Source | What works | Notes |
|---|---|---|
| **YouTube** | Videos, playlists, Shorts, music | Best available video + audio, up to 8K/60/HDR |
| **Spotify** | Single track links (`open.spotify.com/track/…`, `spotify.link/…`) | Resolved to the best audio on YouTube, with cover art and ID3 tags |
| **Tidal** | Tracks, albums, playlists, artists, mixes, videos | Native client, FLAC, cover art, tags, folder structure |
| **Instagram** | Reels and video posts | **No username watermark**, sound, up to 1080p |
| **TikTok** | Videos | **No watermark**, sound, up to 1080p |
| **Everything else** | Any site `yt-dlp` supports | SoundCloud, Bandcamp, VK, and many more |

## Quality presets

| Preset | What it produces | QuickTime |
|---|---|---|
| **Maximum** | Best video + best audio in original codecs (YouTube may serve AV1/VP9/Opus) | May not open; use the MP4 presets |
| **4K MP4** | Up to 4K in MP4; AV1/VP9 is transcoded to HEVC (H.265) via VideoToolbox | ✅ |
| **1080p MP4** | Full HD in MP4, always H.264 + AAC | ✅ |
| **MP3** | Audio only, best available quality, with cover art and ID3 tags | ✅ |

> Instagram and TikTok only show **Maximum** and **MP3**. Both platforms cap out at 1080p, so “Maximum” already means the best available quality.

## Install

### From the DMG

1. Open `LoadTube.dmg`.
2. Drag **LoadTube** into **Applications**.
3. Launch it. If macOS says the developer cannot be verified: right-click **LoadTube** → **Open** → **Open**. The app is signed ad-hoc, without a Developer ID or notarization.
4. On first launch press **Install automatically** — the app downloads `yt-dlp` and `ffmpeg` (~120 MB) by itself. No Homebrew needed.

The ready-to-share installer is `dist/LoadTube.dmg`; it also contains a short “First launch” note.

### Requirements

- macOS 14 (Sonoma) or newer.
- Internet access for the first launch and for downloads.
- **Homebrew is optional** and is supported as a fallback installation method.
- **Tidal** needs your own account. Lossless (FLAC) requires HiFi or Max; on a Free plan Tidal may only serve previews. Tidal needs no Python — everything runs inside LoadTube.
- To build from source: Xcode Command Line Tools / Swift 5.9+.

## Build from source

```bash
make app       # build build/LoadTube.app (universal: arm64 + x86_64)
make run       # build and launch
make install   # build and install into /Applications
make dmg       # build dist/LoadTube.dmg for distribution
make clean     # remove build artifacts
```

Install right away:

```bash
make install
```

Build a DMG to share:

```bash
make dmg
open dist/LoadTube.dmg
```

## Usage

1. Launch **LoadTube**.
2. Paste a video, playlist or track link (or drag it into the window).
3. Choose a quality and press **Download** (or Enter).
4. Done: the file is in the chosen folder and a notification appears.

On first launch, if `yt-dlp` and `ffmpeg` are missing, the app shows an install screen and downloads portable builds into `~/Library/Application Support/LoadTube/bin`. If Homebrew is available, you can install through it instead.

## Instagram & TikTok

LoadTube understands:

- `instagram.com/reel/...`, `instagram.com/reels/...`, `instagram.com/p/...`
- `tiktok.com/@user/video/...`, and short `vm.tiktok.com/...` / `vt.tiktok.com/...` links

Both sources offer only **Maximum** and **MP3** presets — 4K/1080p chips are hidden because the platforms cap at 1080p.

- **Instagram** — video is taken from the original stream without the username watermark; audio is muxed in automatically.
- **TikTok** — the app deliberately excludes the service format `download`, where TikTok bakes in the watermark. The remaining playback streams are clean, contain sound and go up to 1080p.

After downloading, the file is checked for QuickTime compatibility: HEVC is retagged `hvc1` (no re-encoding), unsupported audio is converted to AAC, extra tracks are dropped. If the file is already compatible, nothing runs.

### Browser cookies

Instagram limits anonymous access, and TikTok may require a sign-in for private or sensitive videos. Open **Settings → Instagram and TikTok → Browser cookies** and choose the browser where you are signed in to `instagram.com` and `tiktok.com`.

| Browser | What macOS may ask |
|---|---|
| **Safari** | **Full Disk Access** for LoadTube (System Settings → Privacy & Security). Use **Check access** in Settings. |
| **Chrome / Edge / Brave** | One-time Keychain access request — allow it. |
| **Firefox** | Nothing extra. |

If the selected browser is unavailable, the app tries another installed browser automatically; if none works, it downloads without cookies and shows a warning. Cookies are used **only** for Instagram and TikTok.

## Spotify

Spotify serves music only through DRM, so its audio cannot be downloaded directly. LoadTube:

1. Reads the title, artist and cover art from Spotify's public metadata.
2. Finds the track on YouTube (`ytsearch1`).
3. Downloads the best available audio and converts it to MP3 VBR.
4. Renames the file to `Artist - Title` and writes the cover art and ID3 tags.

> This is **not** the original 320 kbps Spotify stream. Quality is limited by the source (usually Opus 128–160 kbps on YouTube), so the MP3 is the best available — not “studio” Spotify.

Only individual tracks are supported. Spotify albums and playlists are not downloaded yet; the app shows a clear message.

## Tidal

LoadTube understands:

- `tidal.com/browse/track/...`
- `tidal.com/browse/album/...`
- `tidal.com/browse/playlist/...`
- `tidal.com/browse/artist/...`
- `tidal.com/browse/mix/...`
- `tidal.com/browse/video/...`

On first use the app shows a sign-in code. Enter it on the Tidal website — your password is entered only there. After confirmation the download starts automatically, and the session is kept between launches.

Quality is chosen automatically: Max (FLAC 24-bit), HiFi (FLAC), High (AAC 320) or Normal. If your plan does not support Max, the app downloads the best available quality and shows a warning.

A text query in the input field opens Tidal search. You can pick a track, album, playlist, artist or video, and load your own playlists.

An album or playlist is shown as a single row with overall progress; the track list expands. Already downloaded files are skipped. For an artist you can choose specific albums.

Default file layout:

```text
Artist/Album (Year)/01 - Track.flac
Playlist/01 - Artist - Track.flac
```

`cover.jpg` is saved next to the file; tags and cover art are embedded. Settings can enable `.lrc`, a flat folder layout and video downloads.

## Updates

LoadTube checks for updates through GitHub Releases:

- automatically — at most once a day, without blocking the UI;
- manually — gear icon → **Check for updates**, or the app menu **LoadTube → Check for Updates…**.

If a newer version exists, an optional window with release notes appears. You can choose **Later**, **Skip this version** or **Download update**. The DMG is downloaded to `~/Downloads`, verified with `hdiutil` and opened; you then drag the app into Applications yourself.

Automatic checks can be disabled in Settings. The app never installs updates silently and never overwrites itself.

## Interface language

The interface defaults to Russian. In Settings (gear icon) you can pick **Russian**, **English** or **System** — the switch applies immediately, without a restart, and is remembered between launches.

## How it works

- `yt-dlp` downloads video and audio separately, then `ffmpeg` merges them (or converts audio to MP3). For Instagram this is DASH video + audio; for TikTok it is a ready MP4 with sound.
- For TikTok the `download` format (with the baked-in watermark) is excluded; clean playback streams are used. For Instagram and TikTok browser cookies can be passed via `--cookies-from-browser` to download private content and avoid anonymous rate limits.
- Instagram/TikTok files are normalized for QuickTime after download — retagging, audio conversion or transcoding only when necessary.
- Tools are looked up first in `~/Library/Application Support/LoadTube/bin`, then in the system (Homebrew). On first launch portable builds are downloaded from GitHub (yt-dlp and ffmpeg-static).
- Progress is parsed from `--progress-template` in real time.
- The final path comes from `--print-to-file after_move:filepath`.
- Spotify metadata is read from oEmbed and the embed page JSON; the search uses `ytsearch1:`; cover art and tags are written by `ffmpeg`.
- Tidal uses a native client: device-code OAuth, metadata API, `playbackinfo`, then a BTS file or DASH segments. Encrypted FLAC is decrypted with AES-128-CTR, after which `ffmpeg` writes tags and cover art. Python and `tidal-dl` are not bundled.
- The app is not sandboxed because it launches `yt-dlp`/`ffmpeg` child processes. That is fine for personal use.

## Project structure

```text
loadtube/
├── Package.swift                     # Swift Package (executable)
├── Makefile                          # .app/DMG build, icon, install
├── README.md                         # English README (main)
├── README.ru.md                      # Russian README
├── Resources/
│   ├── Info.plist                    # app metadata
│   └── README-DMG.txt                # note inside the DMG
├── Scripts/make_icon.swift           # 1024×1024 icon generation
└── Sources/LoadTube/
    ├── LoadTubeApp.swift             # entry point, theme, shared styles
    ├── Localization.swift            # Russian/English UI
    ├── Models.swift                  # quality presets, states, themes, cookies
    ├── DownloadTask.swift            # single download model
    ├── DownloadManager.swift         # queue, yt-dlp, progress parsing
    ├── MusicResolver.swift           # Spotify links → track on YouTube
    ├── Tidal/                        # native Tidal client
    │   ├── TidalConfig.swift         # URLs, client keys, quality
    │   ├── TidalAuth.swift           # device-code sign-in, token refresh
    │   ├── TidalAPI.swift            # metadata, search, playbackinfo
    │   ├── TidalBackend.swift        # download, decryption, tags
    │   ├── TidalCrypto.swift         # AES for Tidal streams
    │   ├── TidalManifest.swift       # BTS and DASH
    │   ├── TidalPaths.swift          # file and folder names
    │   └── TidalService.swift        # account state for the UI
    ├── TidalLoginView.swift          # device-code sign-in
    ├── TidalSearchView.swift         # Tidal search
    ├── TidalArtistSheet.swift        # artist album picker
    ├── DownloadGroupRow.swift        # album/playlist as one row
    ├── UpdateManager.swift           # soft GitHub Releases updates
    ├── UpdateView.swift              # update window
    ├── UpdateFileDownloader.swift    # DMG download with progress
    ├── DependencyManager.swift       # yt-dlp + ffmpeg lookup/install
    ├── ProcessRunner.swift           # child process runner
    ├── Notifier.swift                # notifications and sound
    ├── MainView.swift                # main window
    ├── DownloadRow.swift             # download row
    ├── InstallView.swift             # first-run install screen
    └── SettingsView.swift            # settings
```

## Troubleshooting

| Problem | Fix |
|---|---|
| **YouTube broke and downloads stopped working** | Update yt-dlp. Portable build: delete `~/Library/Application Support/LoadTube/bin` and reinstall the tools on next launch. Homebrew: `brew upgrade yt-dlp`. |
| **Instagram says access is limited** | Instagram rate-limits anonymous users. Sign in to instagram.com in a browser and select it in **Settings → Instagram and TikTok → Browser cookies**. Safari needs Full Disk Access; Chrome may ask for Keychain access. |
| **TikTok was downloaded with a watermark** | This should not happen — the app excludes the `download` format. Make sure yt-dlp is up to date; if it persists, send the video link. |
| **TikTok downloaded at 720p despite a 1080p video** | TikTok does not serve 1080p for every video; the app takes the highest resolution available without a watermark. |
| **TikTok/Instagram ask to sign in** | Sign in on the site in the selected browser and retry; cookies are read at download time. |
| **QuickTime says the file contains incompatible media** | The app normalizes Instagram/TikTok files automatically. Update to 1.3.1+; if it still happens, send the link. |
| **macOS won't launch the app** | Right-click `LoadTube.app` → **Open**. If it is still blocked: `xattr -dr com.apple.quarantine /Applications/LoadTube.app`. The app is ad-hoc signed; notarization requires an Apple Developer ID. |
| **“Maximum” file does not open in QuickTime** | That preset keeps original codecs (AV1/VP9/Opus). Use **4K MP4** or **1080p MP4** for QuickTime. |
| **“4K MP4” takes a long time** | Normal: AV1/VP9 is transcoded to HEVC in hardware; time depends on length and resolution. |
| **Spotify track is not found** | Make sure it is a single-track link, not an album/playlist; try another link or check the network. |
| **Spotify downloaded the wrong track** | Search is by title and artist on YouTube; rare or cover versions may resolve differently. |
| **Tidal says “preview only”** | A Free Tidal plan serves only part of a track. HiFi or Max is required. |
| **Tidal sign-in by code fails** | Make sure the code was entered on the Tidal website and has not expired (5 minutes). If the session expired, press **Sign in** in Settings. |
| **Tidal track is unavailable in my region** | That is a Tidal restriction, not the app. Try another link or account. |
| **Need another interface language** | Gear icon → **Language**. |
| **Age-restricted video won't download** | Account cookies are required. Not supported in the app yet; use `yt-dlp --cookies-from-browser chrome <link>` manually. |
| **No notifications** | Allow them in **System Settings → Notifications → LoadTube**. |

## Privacy

- No telemetry and no analytics.
- No account inside the app (except Tidal's own OAuth sign-in, which happens on Tidal's website).
- Browser cookies, when enabled, are read locally by `yt-dlp` and sent only to the corresponding site.
- Downloads go directly from the source site to your Mac.

## License & credits

Personal use. Download only content you have the rights to.

Tidal logic is inspired by [Tidal-Media-Downloader](https://github.com/yaronzz/Tidal-Media-Downloader) (Apache-2.0).  
Downloading is powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org).

## Changelog

### 1.3.1

- **QuickTime compatibility fix** for Instagram/TikTok: HEVC `hev1` → `hvc1` without re-encoding, non-AAC audio → AAC, unsupported codecs → HEVC, extra tracks removed, `+faststart`.

### 1.3.0

- **Instagram Reels** — no watermark, with sound, up to 1080p.
- **TikTok** — no watermark, with sound, up to 1080p; the watermarked `download` format is excluded.
- **Browser cookies** for Instagram/TikTok (Safari, Chrome, Firefox, Edge, Brave) with automatic fallback.
- Separate presets for short-video sources: **Maximum** and **MP3**.
