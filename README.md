<div align="center">
  <img src="MonitorControl/Assets.xcassets/AppIcon.appiconset/Icon-512.png" width="160" alt="LumaControl icon"/>
  <h1>LumaControl</h1>
  <p>Modern display control for macOS.</p>
  <p>
    <a href="https://github.com/shay2000/LumaControl/releases">Download the latest DMG</a>
    ·
    <a href="https://github.com/shay2000/LumaControl/issues">Report an issue</a>
  </p>
  <p>
    <img src="https://img.shields.io/badge/platform-macOS-blue" alt="macOS"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"/>
    <a href="https://github.com/shay2000/LumaControl/actions/workflows/ci.yml">
      <img src="https://github.com/shay2000/LumaControl/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status"/>
    </a>
  </p>
</div>

<p align="center">
  <img src=".github/screenshot.png" width="824" alt="LumaControl showing extended brightness controls and display sliders."/>
</p>

## What is LumaControl?

LumaControl is an independently maintained macOS display-control app for brightness, volume, contrast, synchronization, and extended XDR brightness.

It began as a fork of [MonitorControl](https://github.com/MonitorControl/MonitorControl) and is being developed as its own project, with a focus on current macOS releases, native-feeling UI, and new display-control ideas.

## What this project adds

- **Extended XDR brightness** beyond the standard 100% range, with confirmation and quick reset/disable controls.
- **Display-aware synchronization** that respects each display's available range.
- **Modern macOS support** with ongoing maintenance for the latest macOS and Xcode releases.
- **Universal builds** for Apple Silicon and Intel, with CI builds and unit tests.
- **Independent signed updates** through this project's Sparkle feed.

## Features

- Brightness, volume, and contrast controls from the menu bar or keyboard.
- DDC, native Apple display control, gamma dimming, and shade control.
- Native brightness and volume OSD on supported displays.
- Multiple displays, keyboard shortcuts, smooth transitions, and extensive preferences.

## Install

Download the latest universal DMG from [Releases](https://github.com/shay2000/LumaControl/releases), then copy **LumaControl** to `/Applications`.

The distributed build is currently ad-hoc signed. If macOS blocks the first launch, right-click the app and choose **Open**, or run:

```sh
xattr -d com.apple.quarantine /Applications/LumaControl.app
```

Keyboard shortcuts may require **System Settings → Privacy & Security → Accessibility** permission.

## Build

Requirements: Xcode, SwiftLint, SwiftFormat, and BartyCrouch.

```sh
git clone https://github.com/shay2000/LumaControl.git
cd LumaControl
./build/build.sh
```

Or open `MonitorControl.xcodeproj` in Xcode. Dependencies resolve through Swift Package Manager.

## Releases

Push a version tag to build and publish a universal DMG:

```sh
git tag v0.3.0
git push origin v0.3.0
```

Build numbers must increase so installed copies can receive Sparkle updates.

## Credits and license

LumaControl preserves the original MIT license and attribution for MonitorControl contributors. LumaControl changes are maintained by [Shay Prasad](https://github.com/shay2000).

See [License.txt](License.txt) for the full license.
