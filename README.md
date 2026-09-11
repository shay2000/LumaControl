<img src="MonitorControl/Assets.xcassets/AppIcon.appiconset/Icon-512.png" width="200" alt="XDRMonitorControl icon" align="left"/>

<div>
<h3>XDRMonitorControl</h3>
<p>Control your external display's brightness, volume and contrast — and push your MacBook Pro or Pro Display XDR beyond its standard maximum brightness.</p>
<p><a href="https://github.com/shay2000/XDRMonitorControl/releases">Download the latest DMG</a> · <a href="https://github.com/shay2000/XDRMonitorControl/issues">Report an issue</a></p>
</div>

<br/><br/>

<div align="center">
<a href="https://github.com/MonitorControl/MonitorControl/blob/master/License.txt"><img src="https://img.shields.io/github/license/MonitorControl/MonitorControl.svg?style=flat" alt="license"/></a>
<a href="https://github.com/MonitorControl/MonitorControl"><img src="https://img.shields.io/badge/platform-macOS-blue.svg?style=flat" alt="platform"/></a>
<img src="https://img.shields.io/badge/fork-MonitorControl-orange.svg?style=flat" alt="fork"/>

<br/>
<br/>

<a href="https://buymeacoffee.com/shay2k"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=%E2%98%95&slug=shay2k&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy Me a Coffee" height="64"></a>

<br/>
<br/>

<img src=".github/screenshot.png" width="824" alt="XDRMonitorControl showing the brightness slider pushed into the XDR extended range, with Reset to Standard Brightness and Disable XDR Extended Brightness in the menu."/>

</div>

<hr>

> [!NOTE]
> **XDRMonitorControl** is a personal fork of [MonitorControl](https://github.com/MonitorControl/MonitorControl) maintained by [@shay2000](https://github.com/shay2000). It is not affiliated with or endorsed by the upstream project — for the official app, see [MonitorControl](https://github.com/MonitorControl/MonitorControl).

> [!WARNING]
> This fork adds XDR extended brightness control, which drives your display above its standard maximum. That increases heat output and shortens battery life on laptops. Use it responsibly, and use the **Reset to Standard Brightness** or **Disable XDR Extended Brightness** menu items when you want normal behaviour back.

## What's new in this fork

- **XDR extended brightness** — on the MacBook Pro Liquid Retina XDR and the Pro Display XDR, drag the brightness slider further right once you reach 100% and keep going: 150%, 200%, and beyond. The slider's red zone is the extended range. The first time you do this, the app asks you to confirm.
- **Quick toggles for the extended range** — two shortcuts in the menu: **Reset to Standard Brightness** and **Disable XDR Extended Brightness**. Use them whenever you want normal behaviour back.
- **Sync respects the extended range** — when mirroring brightness across displays, the target's maximum (including its XDR range) is honoured.
- **Tahoe-friendly** — adopts the macOS 26 Liquid Glass appearance so it feels at home on the latest macOS.
- **Its own update feed** — Sparkle is pointed at this fork's own releases. The upstream feed is deliberately avoided: it would replace your XDR features with plain MonitorControl. Updates are cryptographically signed.

## Major features

- Control your display's brightness, volume and contrast.
- Shows native OSD for brightness and volume on supported displays.
- Supports multiple protocols: **DDC** for external displays (brightness, contrast, volume), the **native Apple protocol** for built-in and Apple displays, **Gamma-table** control for software dimming, and **shade control** for AirPlay, Sidecar, DisplayLink and other virtual screens.
- Smooth brightness transitions.
- Combine hardware and software dimming to go dimmer than your display allows on its own.
- Mirror the Ambient light sensor and Touch Bar brightness changes from your Mac to a non-Apple external display.
- Sync all your displays with a single slider or keyboard shortcut.
- Allows dimming to full black.
- Custom keyboard shortcuts and full support for the standard brightness and media keys on Apple keyboards.
- Dozens of customisation options (turn on *Show advanced settings* in the prefs for the full set).
- Simple, unobtrusive menu-bar UI that blends in with macOS.
- Completely free.

## Download

Every push builds a universal (Apple Silicon + Intel) DMG:

1. Open the [Actions tab](https://github.com/shay2000/XDRMonitorControl/actions), pick the latest successful **CI** run on `main`, and download the `XDRMonitorControl-…-universal.dmg` artifact.
2. Tagged releases (e.g. `v0.2.0`) publish the DMG on the [Releases page](https://github.com/shay2000/XDRMonitorControl/releases).

The DMG is ad-hoc signed (no Apple Developer certificate). If macOS blocks it on first launch, right-click the app and choose **Open**, or run:

```sh
xattr -d com.apple.quarantine /Applications/XDRMonitorControl.app
```

### Versioning

This fork uses its own version numbers starting at **0.1.0** (`v0.1.0`, `v0.2.0`, …). The upstream base is tracked separately — this release is based on upstream MonitorControl 4.3.4.

### Releasing a new version

Updates are delivered by Sparkle from `appcast.xml`, which CI rewrites on every tagged release:

1. Bump `CFBundleVersion` in `MonitorControl/Info.plist` (or use the **Increase Build Number** target in Xcode). Sparkle compares this number, so a release that reuses the current build number will never be offered to an installed copy.
2. Bump `MARKETING_VERSION` if this is a new user-facing version.
3. Commit, then push a tag:

   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   ```

CI builds the DMG, attaches it to the release, signs it, rewrites `appcast.xml`, and commits it back to `main`. The feed lives at `https://raw.githubusercontent.com/shay2000/XDRMonitorControl/main/appcast.xml`.

**One-time setup:** CI needs the EdDSA private key as a repository secret named `SPARKLE_PRIVATE_KEY` (Settings → Secrets and variables → Actions → New repository secret). The matching public key is already in `Info.plist` as `SUPublicEDKey`. If the secret is missing, the appcast step fails loudly rather than publishing an update the app would reject.

## How to use it

1. Download the DMG and copy **XDRMonitorControl** to your Applications folder.
2. Open the app — a small sun icon appears in the menu bar.
3. Click the icon to adjust brightness, volume or contrast per display. The standard brightness and media keys on your Apple keyboard work too.
4. On an XDR display, when you reach 100%, keep dragging the slider right for extended brightness. The first time you do this, the app asks you to confirm.
5. Open **Preferences…** for customisation: smooth transitions, dim-below-zero, sync across displays, custom keyboard shortcuts, and more (enable *Show advanced settings* for the full set).
6. Add the app to **Accessibility** in *System Settings → Privacy & Security* if you want the native Apple brightness and media keys to work — the app walks you through this on first launch.

If you have questions or want to share feedback, open a [Discussion](https://github.com/shay2000/XDRMonitorControl/discussions).

## How to build

### Required

- Xcode
- [SwiftLint](https://github.com/realm/SwiftLint)
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)
- [BartyCrouch](https://github.com/Flinesoft/BartyCrouch) (for localizations)

### Steps

```sh
git clone https://github.com/shay2000/XDRMonitorControl.git
```

Open `MonitorControl.xcodeproj` with Xcode. Dependencies download automatically on first open; if they don't, *File → Packages → Resolve Package Versions*.

### Third party dependencies

- [MediaKeyTap](https://github.com/MonitorControl/MediaKeyTap)
- [Settings](https://github.com/sindresorhus/Settings)
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio)
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- [Sparkle](https://github.com/sparkle-project/Sparkle)

## Credits

This project is a fork of [MonitorControl](https://github.com/MonitorControl/MonitorControl). All credit for the original application goes to:

- [@waydabber](https://github.com/waydabber) — maintainer, developer of [BetterDisplay](https://github.com/waydabber/BetterDisplay#readme)
- [@the0neyouseek](https://github.com/the0neyouseek) — honorary maintainer
- [@JoniVR](https://github.com/JoniVR) — honorary maintainer
- [@alin23](https://github.com/alin23) — spearheaded M1 DDC support, developer of [Lunar](https://lunar.fyi)
- [@mathew-kurian](https://github.com/mathew-kurian/) — original developer
- [@Tyilo](https://github.com/Tyilo/) — fork
- [@Bensge](https://github.com/Bensge/) — used code from [NativeDisplayBrightness](https://github.com/Bensge/NativeDisplayBrightness)
- [@nhurden](https://github.com/nhurden/) — original MediaKeyTap
- [@kfix](https://github.com/kfix/ddcctl) — ddcctl
- [@reitermarkus](https://github.com/reitermarkus) — Intel DDC support

XDR extended brightness additions by [@shay2000](https://github.com/shay2000).

If you find this fork useful, you can [buy me a coffee](https://buymeacoffee.com/shay2k).

## License

MIT — see [License.txt](License.txt). Original copyright © MonitorControl contributors. Fork additions copyright © 2026 Shay Prasad.
