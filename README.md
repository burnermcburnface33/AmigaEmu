<!--
  Note: GitHub strips <script> tags from Markdown, so the Buy Me a Coffee
  JavaScript widget can't run in a README. The linked image button below points
  at the same page (slug: burnermcburnface33) and renders everywhere.
-->

# 🕹️ Amiga for iOS

A **Commodore Amiga** emulator for iPhone & iPad — the [vAmiga](https://github.com/dirkwhoffmann/vAmiga)
core wrapped in a native SwiftUI/UIKit shell with Metal rendering and a full set of touch controls.

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2017%2B-blue" alt="iOS 17+">
  <img src="https://img.shields.io/badge/iPhone%20%26%20iPad-portrait%20%2B%20landscape-brightgreen" alt="iPhone & iPad">
  <img src="https://img.shields.io/badge/core-vAmiga%204.3.1-orange" alt="vAmiga 4.3.1">
  <img src="https://img.shields.io/badge/build-XcodeGen-lightgrey" alt="XcodeGen">
</p>

<p align="center">
  <a href="https://www.buymeacoffee.com/burnermcburnface33" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="60" width="217">
  </a>
</p>

---

## 💻 The machine

A loaded **Amiga 2000**: Motorola **68000**, ECS Agnus + OCS Denise, PAL, and **10.5 MB RAM**
(1 MB chip + 1.5 MB slow + 8 MB Zorro-II fast) — the practical ceiling of this OCS/ECS core. It boots
**Kickstart 3.1** to Workbench, with accelerated disk access and the iconic drive-click LED. (This core
is OCS/ECS only — there's no AGA, so A1200/A4000 aren't possible.)

## ✨ Features

- **Seven touch input modes**, switchable from the toolbar:
  **Keyboard** (with a floating Esc/Ctrl/◆/Alt/arrows + F-key bar and true hardware-keyboard support) ·
  **Joystick** (analog stick + fire; translucent full-screen overlay in landscape) ·
  **D-Pad** (customizable draggable buttons — any key or joystick fire, momentary or latching) ·
  **Trackpad Mouse** (relative pointer + L/M/R; split layout in landscape) ·
  **Direct Mouse** (the screen itself is the trackpad, with floating L/R buttons for drag-and-drop) ·
  **Side Keys** (split landscape keyboard) ·
  **Custom Panel** (landscape custom-key panels on both sides + an optional inverted-T arrow pad, with
  its own saved layouts).
- **Metal rendering** with automatic crop/aspect handling, pinch-zoom, and pan.
- **Paula audio** via `AVAudioEngine`, with call/Siri interruption handling.
- **Save states** — browsable multi-slot saves with thumbnails, plus auto-save on backgrounding and a
  "Resume last session?" prompt on cold launch.
- **Disk management** — import ADF/ADZ/DMS/IMG via the Files app, a bundled-disks library, a re-insertable
  imported-disk library, and optional **iCloud Drive backup**.
- **MFi / Bluetooth game controllers**, configurable **haptics**, and adjustable **mouse sensitivity**.
- **iPhone & iPad, portrait & landscape** (layouts adapt by geometry, so they work correctly on iPad).

## 🔧 Requirements

- **macOS** with **Xcode 26** + command-line tools
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
  (the `.xcodeproj` is generated from `AmigaEmu/project.yml`)
- An **Apple Developer** account for on-device signing; **iOS 17+** device or simulator
- **A Kickstart ROM is not included.** Drop a Kickstart `.rom` into `AmigaEmu/AmigaEmu/Resources/ROMs`
  and it will be used automatically. Disk images are yours to supply.

## 🚀 Build & run

The Xcode project lives one level down in `AmigaEmu/` and is generated from `project.yml`:

```sh
cd AmigaEmu && xcodegen generate --spec project.yml && \
xcodebuild -project AmigaEmu.xcodeproj -scheme AmigaEmu \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

For a device build, open `AmigaEmu/AmigaEmu.xcodeproj` in Xcode and run, or drop the simulator flags and
sign with your team. **`build_adhoc.sh`** (in this repo root) archives and exports a signed Ad-Hoc `.ipa`
plus an OTA install manifest.

> New Swift files under `AmigaEmu/AmigaEmu/UI/` require a fresh `xcodegen generate` before they compile.

## 🧱 Architecture

A SwiftUI shell (`MainView` + toolbar + per-mode input overlays) talks to an Objective-C++
`EmulatorBridge`, which owns **one background pthread** that paces vAmiga (compute a frame, drain the
thread-safe input queue) at 50 fps PAL. The framebuffer is uploaded to a Metal renderer that auto-tunes
and then locks its crop. Input is always applied on the emulator thread; held keys/buttons release on
view teardown so nothing sticks across a mode switch or rotation. See `AmigaEmu/CLAUDE.md` for the full
change log.

## 🙏 Credits & license

Built on **[vAmiga](https://github.com/dirkwhoffmann/vAmiga)** by Dirk W. Hoffmann, released under the
**GNU General Public License** — consult the vAmiga project for its license terms before redistributing.
Amiga Kickstart ROMs and all disk images / software are **not** distributed here and remain the property
of their owners; use only what you're legally entitled to.

## 👥 Contributors

<!-- Update the repo path below (contrib.rocks + graphs link) if your Amiga repo isn't named "Amiga". -->
Maintained by **[@burnermcburnface33](https://github.com/burnermcburnface33)** — the iOS app, the
SwiftUI/UIKit shell, and the touch input system. Built on **[vAmiga](https://github.com/dirkwhoffmann/vAmiga)**
by Dirk W. Hoffmann.

<a href="https://github.com/burnermcburnface33/Amiga/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=burnermcburnface33/Amiga" alt="Contributors">
</a>

Contributions are welcome — open an issue or a pull request.

## ☕ Support

<p align="center">
  <a href="https://www.buymeacoffee.com/burnermcburnface33" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="60" width="217">
  </a>
</p>

<sub>A personal hobby project — provided as-is, with no warranty. Not affiliated with Commodore or Amiga.</sub>
