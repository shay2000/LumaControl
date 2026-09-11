//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AudioToolbox
import Cocoa
import Foundation
import MediaKeyTap
import os.log

class MediaKeyTapManager: MediaKeyTapDelegate {
  var mediaKeyTap: MediaKeyTap?
  var keyRepeatTimers: [MediaKey: Timer] = [:]
  /// Guards the "Accessibility is missing" alert so it is shown at most once per session.
  private var didReportMissingAccessibility = false

  func handle(mediaKey: MediaKey, event: KeyEvent?, modifiers: NSEvent.ModifierFlags?) {
    let isPressed = event?.keyPressed ?? true
    let isRepeat = event?.keyRepeat ?? false
    let isControl = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.control])) ?? false
    let isCommand = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.command])) ?? false
    let isOption = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.option])) ?? false
    let isShift = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.shift])) ?? false
    if isPressed, isCommand, !isControl, mediaKey == .brightnessDown, DisplayManager.engageMirror() {
      return
    }
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    if isPressed, self.handleOpenPrefPane(mediaKey: mediaKey, event: event, modifiers: modifiers) {
      return
    }
    var isSmallIncrement = isOption && isShift
    let isContrast = isControl && isOption && isCommand
    if [.brightnessUp, .brightnessDown].contains(mediaKey), prefs.bool(forKey: PrefKey.useFineScaleBrightness.rawValue) {
      isSmallIncrement = !isSmallIncrement
    }
    if [.volumeUp, .volumeDown, .mute].contains(mediaKey), prefs.bool(forKey: PrefKey.useFineScaleVolume.rawValue) {
      isSmallIncrement = !isSmallIncrement
    }
    if isPressed, isControl, !isOption, mediaKey == .brightnessUp || mediaKey == .brightnessDown {
      self.handleDirectedBrightness(isCommandModifier: isCommand, isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
      return
    }
    let oppositeKey: MediaKey? = self.oppositeMediaKey(mediaKey: mediaKey)
    // If the opposite key to the one being held has an active timer, cancel it - we'll be going in the opposite direction
    if let oppositeKey = oppositeKey, let oppositeKeyTimer = self.keyRepeatTimers[oppositeKey], oppositeKeyTimer.isValid {
      oppositeKeyTimer.invalidate()
    } else if let mediaKeyTimer = self.keyRepeatTimers[mediaKey], mediaKeyTimer.isValid {
      // If there's already an active timer for the key being held down, let it run rather than executing it again
      if isRepeat {
        return
      }
      mediaKeyTimer.invalidate()
    }
    self.sendDisplayCommand(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed, isContrast: isContrast)
  }

  func handleDirectedBrightness(isCommandModifier: Bool, isUp: Bool, isSmallIncrement: Bool) {
    if isCommandModifier {
      for otherDisplay in DisplayManager.shared.getOtherDisplays() {
        otherDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      }
      for appleDisplay in DisplayManager.shared.getAppleDisplays() where !appleDisplay.isBuiltIn() {
        appleDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      }
      return
    } else if let internalDisplay = DisplayManager.shared.getBuiltInDisplay() as? AppleDisplay {
      internalDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      return
    }
  }

  private func sendDisplayCommand(mediaKey: MediaKey, isRepeat: Bool, isSmallIncrement: Bool, isPressed: Bool, isContrast: Bool = false) {
    self.sendDisplayCommandVolumeMute(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed)
    self.sendDisplayCommandBrightnessContrast(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed, isContrast: isContrast)
  }

  private func sendDisplayCommandVolumeMute(mediaKey: MediaKey, isRepeat: Bool, isSmallIncrement: Bool, isPressed: Bool) {
    guard [.volumeUp, .volumeDown, .mute].contains(mediaKey), app.sleepID == 0, app.reconfigureID == 0, let affectedDisplays = DisplayManager.shared.getAffectedDisplays(isBrightness: false, isVolume: true) else {
      return
    }
    var wasNotIsPressedVolumeSentAlready = false
    for display in affectedDisplays where !display.readPrefAsBool(key: .isDisabled) {
      switch mediaKey {
      case .mute:
        // The mute key should not respond to press + hold or keyup
        if !isRepeat, isPressed, let display = display as? OtherDisplay {
          display.toggleMute()
          if !wasNotIsPressedVolumeSentAlready, display.readPrefAsInt(for: .audioMuteScreenBlank) != 1, !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
            app.playVolumeChangedSound()
            wasNotIsPressedVolumeSentAlready = true
          }
        }
      case .volumeUp, .volumeDown:
        // volume only matters for other displays
        if let display = display as? OtherDisplay {
          if isPressed {
            display.stepVolume(isUp: mediaKey == .volumeUp, isSmallIncrement: isSmallIncrement)
          } else if !wasNotIsPressedVolumeSentAlready, !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
            app.playVolumeChangedSound()
            wasNotIsPressedVolumeSentAlready = true
          }
        }
      default: continue
      }
    }
  }

  private func sendDisplayCommandBrightnessContrast(mediaKey: MediaKey, isRepeat _: Bool, isSmallIncrement: Bool, isPressed: Bool, isContrast: Bool = false) {
    guard [.brightnessUp, .brightnessDown].contains(mediaKey), app.sleepID == 0, app.reconfigureID == 0, isPressed, let affectedDisplays = DisplayManager.shared.getAffectedDisplays(isBrightness: true, isVolume: false) else {
      return
    }
    for display in affectedDisplays where !display.readPrefAsBool(key: .isDisabled) {
      switch mediaKey {
      case .brightnessUp:
        if isContrast, let otherDisplay = display as? OtherDisplay {
          otherDisplay.stepContrast(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        } else {
          var isAnyDisplayInSwAfterBrightnessMode = false
          for display in affectedDisplays where ((display as? OtherDisplay)?.isSwBrightnessNotDefault() ?? false) && !((display as? OtherDisplay)?.isSw() ?? false) && prefs.bool(forKey: PrefKey.separateCombinedScale.rawValue) {
            isAnyDisplayInSwAfterBrightnessMode = true
          }
          if !(isAnyDisplayInSwAfterBrightnessMode && !(((display as? OtherDisplay)?.isSwBrightnessNotDefault() ?? false) && !((display as? OtherDisplay)?.isSw() ?? false))) {
            display.stepBrightness(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
          }
        }
      case .brightnessDown:
        if isContrast, let otherDisplay = display as? OtherDisplay {
          otherDisplay.stepContrast(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        } else {
          display.stepBrightness(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        }
      default: continue
      }
    }
  }

  private func oppositeMediaKey(mediaKey: MediaKey) -> MediaKey? {
    if mediaKey == .brightnessUp {
      return .brightnessDown
    } else if mediaKey == .brightnessDown {
      return .brightnessUp
    } else if mediaKey == .volumeUp {
      return .volumeDown
    } else if mediaKey == .volumeDown {
      return .volumeUp
    }
    return nil
  }

  func updateMediaKeyTap() {
    var keys: [MediaKey] = []
    if [KeyboardBrightness.media.rawValue, KeyboardBrightness.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardBrightness.rawValue)) {
      keys.append(contentsOf: [.brightnessUp, .brightnessDown])
    }
    if [KeyboardVolume.media.rawValue, KeyboardVolume.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardVolume.rawValue)) {
      keys.append(contentsOf: [.mute, .volumeUp, .volumeDown])
    }
    // Remove brightness keys if no external displays are connected, but only if brightness fine control is not active
    var hasExternalDisplay = false
    for display in DisplayManager.shared.getAllDisplays() where !display.isBuiltIn() {
      hasExternalDisplay = true
    }
    // Disengage brightness keys on sleep so MacBook native screen can be controlled meanwhile
    let isTransient = app.sleepID != 0 || app.reconfigureID != 0
    let disengageBrightness = !hasExternalDisplay || isTransient
    if disengageBrightness, !prefs.bool(forKey: PrefKey.useFineScaleBrightness.rawValue) {
      // Keep them anyway when the built-in panel can go past 100%. With no external display
      // attached macOS consumes the brightness keys itself, so `stepBrightness` never runs
      // and the XDR opt-in is unreachable except by opening the menu and dragging the
      // slider to 100% — which defeats the point of having the keys. Only while awake and
      // settled: during sleep and display reconfiguration the panel belongs to macOS.
      let keepForXDR = !hasExternalDisplay && !isTransient
        && DisplayManager.shared.displays.contains { ($0 as? AppleDisplay)?.isXDRCapable == true }
      if !keepForXDR {
        let keysToDelete: [MediaKey] = [.brightnessUp, .brightnessDown]
        keys.removeAll { keysToDelete.contains($0) }
      }
    }
    // Remove volume related keys if audio device is controllable
    if let defaultAudioDevice = app.coreAudio.defaultOutputDevice {
      let keysToDelete: [MediaKey] = [.volumeUp, .volumeDown, .mute]
      if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
        if DisplayManager.shared.updateAudioControlTargetDisplays(deviceName: defaultAudioDevice.name) == 0 {
          keys.removeAll { keysToDelete.contains($0) }
        }
      } else if defaultAudioDevice.canSetVirtualMainVolume(scope: .output) == true {
        keys.removeAll { keysToDelete.contains($0) }
      }
    }
    // MediaKeyTap installs a modifying `CGEventTap`, and it swallows the failure — it only
    // `print`s it, which a GUI app has nowhere to write. From the inside, an app that cannot
    // install its tap is therefore indistinguishable from a working one: the tap is simply
    // never created and no key ever arrives.
    //
    // Detect it here instead. Note this deliberately does NOT use `AXIsProcessTrusted()`:
    // that keeps returning true — and System Settings keeps listing the app as enabled —
    // after the app is re-signed, which is what every local rebuild does. Only the real
    // `tapCreate` call tells the truth.
    if keys.count > 0, !MediaKeyTapManager.canInstallEventTap() {
      os_log("Media keys are enabled but macOS refused an event tap, so these keys will be ignored.", type: .error)
      self.reportMissingAccessibility()
    }
    self.mediaKeyTap?.stop()
    // returning an empty array listens for all mediakeys in MediaKeyTap
    if keys.count > 0 {
      self.mediaKeyTap = MediaKeyTap(delegate: self, on: KeyPressMode.keyDownAndUp, for: keys, observeBuiltIn: true)
      self.mediaKeyTap?.start()
    }
  }

  /// The name of the row that holds the Accessibility app list, which Apple renamed.
  ///
  /// On macOS 27 the row — and the window it opens — is called "Device Control and Data
  /// Access", not "Accessibility". Verified by opening
  /// `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and
  /// reading the resulting System Settings window title. The URL itself is unchanged, and
  /// `Privacy_Accessibility` is still hardcoded in `SecurityPrivacyExtension`, so the deep
  /// link keeps working either way.
  private static var accessibilityPaneName: String {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
      ? NSLocalizedString("Device Control and Data Access", comment: "Name of the Accessibility row in System Settings on macOS 27 and later")
      : NSLocalizedString("Accessibility", comment: "Name of the Accessibility row in System Settings")
  }

  /// Tells the user, once per session, that the media keys cannot work because macOS refused
  /// an event tap.
  ///
  /// Deferred to the next main-queue turn: this runs from `updateMenusAndKeys()`, which is
  /// itself called from inside a menu update and from the display reconfiguration callback,
  /// and a modal alert in either place fights the menu's tracking loop.
  ///
  /// Deliberately not routed through `acquirePrivileges()`, which gates on
  /// `AXIsProcessTrusted()` and so stays silent in exactly the case that matters — a grant
  /// that survived a re-sign and still reads as enabled.
  private func reportMissingAccessibility() {
    guard !self.didReportMissingAccessibility else {
      return
    }
    self.didReportMissingAccessibility = true
    DispatchQueue.main.async {
      let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "XDRMonitorControl"
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Keyboard keys are not reaching the app", comment: "Shown in the alert dialog")
      alert.informativeText = String(format: NSLocalizedString("macOS is not letting %@ listen for the brightness and volume keys, so they cannot control your displays. The menu sliders still work.\n\nOpen System Settings > Privacy & Security, then choose \"%@\" in the list. Remove %@ from that list with the – button, then add it back with the + button.\n\nmacOS keeps showing the app as enabled after it has been rebuilt, because the permission is tied to the exact build. Removing and re-adding it records the current build.", comment: "Shown in the alert dialog"), appName, MediaKeyTapManager.accessibilityPaneName, appName)
      alert.alertStyle = .warning
      alert.addButton(withTitle: NSLocalizedString("Open Privacy & Security Settings", comment: "Shown in the alert dialog"))
      alert.addButton(withTitle: NSLocalizedString("Later", comment: "Shown in the alert dialog"))
      if alert.runModal() == .alertFirstButtonReturn,
         let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
      }
    }
  }

  /// Whether this process can actually install the media-key event tap.
  ///
  /// `MediaKeyTap` asks for a session-wide, event-modifying tap, which macOS only hands over
  /// to a process it trusts. `AXIsProcessTrusted()` is not a reliable stand-in for that test:
  /// it consults a lenient match that survives re-signing, so it keeps answering `true` — and
  /// System Settings keeps showing the app as enabled — while `tapCreate` refuses. Running
  /// the real call is the only way to tell those two apart.
  ///
  /// The probe tap is invalidated immediately. It has no run loop source, so it never sees an
  /// event; it exists only to find out whether the port is granted.
  static func canInstallEventTap() -> Bool {
    let mask = CGEventMask(1 << NX_KEYDOWN) | CGEventMask(1 << NX_SYSDEFINED)
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: eventTapProbeCallback,
      userInfo: nil
    ) else {
      return false
    }
    CFMachPortInvalidate(port)
    return true
  }

  func handleOpenPrefPane(mediaKey: MediaKey, event: KeyEvent?, modifiers: NSEvent.ModifierFlags?) -> Bool {
    guard let modifiers = modifiers else { return false }
    if !(modifiers.contains(.option) && !modifiers.contains(.shift) && !modifiers.contains(.control) && !modifiers.contains(.command)) {
      return false
    }
    if event?.keyRepeat == true {
      return false
    }
    switch mediaKey {
    case .brightnessUp, .brightnessDown:
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Displays.prefPane"))
    case .mute, .volumeUp, .volumeDown:
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
    default:
      return false
    }
    return true
  }

  static func acquirePrivileges(firstAsk: Bool = false) {
    // `readPrivileges(prompt: true)` still earns its keep: passing `true` is what raises the
    // system "would like to control this computer" prompt, and that prompt is what puts the app
    // into the list in the first place. What must **not** be trusted is its return value — see
    // `readPrivileges`. Ask for the prompt, then judge with the real capability test, or this
    // alert stays silent in exactly the case it exists for.
    _ = self.readPrivileges(prompt: true)
    if !self.canInstallEventTap(), !firstAsk {
      let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "XDRMonitorControl"
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Shortcuts not available", comment: "Shown in the alert dialog")
      alert.informativeText = String(format: NSLocalizedString("You need to enable %@ in System Settings > Privacy & Security > \"%@\" for the keyboard shortcuts to work. If it is already enabled, remove it and add the current app again.", comment: "Shown in the alert dialog"), appName, MediaKeyTapManager.accessibilityPaneName)
      alert.runModal()
    }
  }

  /// Asks macOS whether this process is trusted for Accessibility, optionally prompting.
  ///
  /// **The return value is not a reliable test.** `AXIsProcessTrustedWithOptions` consults a
  /// lenient match that survives re-signing, so it keeps answering `true` — while
  /// `CGEvent.tapCreate` refuses and System Settings keeps showing the app as enabled. Use
  /// `canInstallEventTap()` to decide anything; use this only to raise the system prompt
  /// (`prompt: true`), which is a side effect worth having on its own.
  static func readPrivileges(prompt: Bool) -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: prompt]
    let status = AXIsProcessTrustedWithOptions(options)
    os_log("Reading Accessibility privileges - Current access status %{public}@ (lenient, not authoritative)", type: .info, String(status))
    return status
  }
}

/// Pass-through callback for the event-tap capability probe in `canInstallEventTap()`.
///
/// `CGEvent.tapCreate` takes a C function pointer, so this cannot be a closure. It returns the
/// event untouched; the probe's tap is invalidated before it can ever be called.
private func eventTapProbeCallback(_: CGEventTapProxy, _: CGEventType, _ event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
  Unmanaged.passUnretained(event)
}
