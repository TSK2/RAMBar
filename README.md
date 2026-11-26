# RAMBar

**A tiny macOS menu-bar app that shows memory pressure and RAM usage at a glance — and lets you quit memory-hungry apps in one click.**

[한국어](README.ko.md) · macOS 13+ · Apple Silicon & Intel · English / 한국어 · MIT

<!-- TODO: add a short demo GIF here, e.g. ![RAMBar demo](docs/demo.gif) -->

```
● 72%      ← lives in your menu bar
```

## Why

Opening Activity Monitor every time you want to check memory gets old, and most system monitors do far more than you need.
RAMBar does one thing: **one dot + one number** in the menu bar, with details and a quick cleanup list when you click it.

## Features

- **Pressure dot** — green = normal, yellow = warning, red = critical (macOS memory pressure)
- **Usage %** — calculated the same way as Activity Monitor's *Memory Used* (App Memory + Wired + Compressed)
- **Details on click** — app memory, wired, compressed, cached files, swap
- **Running apps by memory** — top 12 apps, with child processes (Chrome / Electron helpers, etc.) added to their parent app
  - Click an app to quit it normally (same as ⌘Q — unsaved documents are still prompted)
  - Apps with **no open windows** are flagged, and you can quit them all at once
  - Apps whose windows are minimized or on another Space are treated as having windows, so they're never flagged by mistake
- **Launch at login**, no Dock icon, refreshes every 2 seconds
- **English & Korean** menu (follows your macOS language), universal binary for Apple Silicon and Intel
- **Lightweight** — a single Swift file using only Apple frameworks (AppKit, ServiceManagement); the app list is only computed while the menu is open

## Install

### Download

1. Download **[RAMBar.dmg](../../releases/latest/download/RAMBar.dmg)** from the latest [release](../../releases/latest).
2. Open it and drag **RAMBar** to **Applications**.
3. First launch: RAMBar is not notarized by Apple yet, so macOS will block it the first time.
   Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

### Build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/TSK2/RAMBar.git
cd RAMBar
./build.sh          # universal RAMBar.app
./build.sh dmg      # also creates RAMBar.dmg
open RAMBar.app
```

To keep it running, move `RAMBar.app` to `/Applications` and turn on **Launch at login** from the menu.

## Tips

- On 8 GB Macs, judge by the **dot color and swap** rather than the percentage — macOS deliberately fills free RAM with cache.
- Limitation: processes the system spawns separately (e.g. Safari web content) are not added to the app's total.

## Project structure

| File | Description |
|---|---|
| `main.swift` | The whole app (AppKit, single file) |
| `Info.plist` | Bundle info (`LSUIElement` hides the Dock icon) |
| `build.sh` | Builds a universal `RAMBar.app` (ad-hoc signed); `./build.sh dmg` also makes `RAMBar.dmg` |

## Roadmap

- Signed & notarized release
- Homebrew cask

## License

[MIT](LICENSE) © 2026 TSK2

RAMBar uses only Apple system frameworks and contains no third-party code.
macOS and Activity Monitor are trademarks of Apple Inc. This project is not affiliated with Apple.
