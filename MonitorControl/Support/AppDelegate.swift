//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AVFoundation
import Cocoa
import Foundation
import MediaKeyTap
import os.log
import ServiceManagement
import Settings
import SimplyCoreAudio
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
  let statusItem: NSStatusItem = {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.behavior = .removalAllowed
    return item
  }()
  var mediaKeyTap = MediaKeyTapManager()
  var keyboardShortcuts = KeyboardShortcutsManager()
  let coreAudio = SimplyCoreAudio()
  var accessibilityObserver: NSObjectProtocol!
  var statusItemObserver: NSObjectProtocol!
  var statusItemVisibilityChangedByUser = true
  var reconfigureID: Int = 0 // dispatched reconfigure command ID
  var sleepID: Int = 0 // sleep event ID
  var safeMode = false
  var jobRunning = false
  var startupActionWriteCounter: Int = 0
  var audioPlayer: AVAudioPlayer?
  let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: UpdaterDelegate(), userDriverDelegate: nil)

  var settingsPaneStyle: Settings.Style {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return Settings.Style.toolbarItems
    } else {
      return Settings.Style.segmentedControl
    }
  }

  /// The storyboard-backed preference panes, in display order.
  ///
  /// Panes that fail to load are skipped and logged rather than force-unwrapped. A
  /// storyboard scene whose `customModule` does not match the app's product module
  /// resolves to nil at runtime, and force-unwrapping that used to trap the whole app
  /// the first time the settings window was needed (menu gear button, app reopen).
  private var settingsPanes: [SettingsPane] {
    let candidates: [(identifier: String, pane: SettingsPane?)] = [
      ("MainPrefsVC", mainPrefsVc),
      ("MenuslidersPrefsVC", menuslidersPrefsVc),
      ("KeyboardPrefsVC", keyboardPrefsVc),
      ("DisplaysPrefsVC", displaysPrefsVc),
      ("AboutPrefsVC", aboutPrefsVc),
    ]
    var panes: [SettingsPane] = []
    for candidate in candidates {
      if let pane = candidate.pane {
        panes.append(pane)
      } else {
        os_log("Preference pane %{public}@ could not be loaded from the storyboard.", type: .error, candidate.identifier)
      }
    }
    return panes
  }

  lazy var settingsWindowController: SettingsWindowController = .init(
    panes: self.settingsPanes,
    style: self.settingsPaneStyle,
    animated: true
  )

  func applicationDidFinishLaunching(_: Notification) {
    app = self
    // The unit-test bundle is injected into the app, so the app delegate runs during
    // `xcodebuild test`. Bail out before anything touches the UI: onboarding, the
    // accessibility prompt and the "incompatible previous version" alert are all modal
    // and hang the test runner forever on a headless CI machine. The suite only covers
    // display/brightness logic, which needs none of this setup.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil {
      return
    }
    self.subscribeEventListeners()
    self.showSafeModeAlertIfNeeded()
    if !prefs.bool(forKey: PrefKey.appAlreadyLaunched.rawValue) {
      self.showOnboardingWindow()
    } else {
      self.checkPermissions()
    }
    self.setPrefsBuildNumber()
    self.setDefaultPrefs()
    self.setMenu()
    CGDisplayRegisterReconfigurationCallback({ _, _, _ in app.displayReconfigured() }, nil)
    self.configure(firstrun: true)
    DisplayManager.shared.createGammaActivityEnforcer()
    // Only start Sparkle when a feed URL is configured, so debug/unsigned builds stay quiet.
    if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
      self.updaterController.startUpdater()
    }
  }

  @objc func quitClicked(_: AnyObject) {
    os_log("Quit clicked", type: .info)
    menu.closeMenu()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NSApplication.shared.terminate(self)
    }
  }

  @objc func prefsClicked(_: AnyObject) {
    os_log("Settings clicked", type: .info)
    guard !self.settingsPanes.isEmpty else {
      self.showSettingsUnavailableAlert()
      return
    }
    self.settingsWindowController.show()
  }

  private func showSettingsUnavailableAlert() {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Settings could not be opened", comment: "Shown in the alert dialog")
    alert.informativeText = NSLocalizedString("The app's preference panes failed to load from its interface file. Reinstalling or rebuilding the app should resolve this.", comment: "Shown in the alert dialog")
    alert.alertStyle = .warning
    alert.runModal()
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    app.prefsClicked(self)
    return true
  }

  func applicationWillTerminate(_: Notification) {
    os_log("Goodbye!", type: .info)
    // Hand the gamma table back before anything else. CoreGraphics restores it if we die
    // without warning, but quitting is not an emergency and the ramp should go now.
    XDREngine.shared.stop()
    DisplayManager.shared.resetSwBrightnessForAllDisplays(noPrefSave: true)
    self.updateStatusItemVisibility(true)
  }

  private func setPrefsBuildNumber() {
    let currentBuildNumber = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    let previousBuildNumber: Int = (Int(prefs.string(forKey: PrefKey.buildNumber.rawValue) ?? "0") ?? 0)
    if self.safeMode || ((previousBuildNumber < MIN_PREVIOUS_BUILD_NUMBER) && previousBuildNumber > 0) || (previousBuildNumber > currentBuildNumber), let bundleID = Bundle.main.bundleIdentifier {
      if !self.safeMode {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Incompatible previous version", comment: "Shown in the alert dialog")
        alert.informativeText = NSLocalizedString("Settings for an incompatible previous app version detected. Default settings are reloaded.", comment: "Shown in the alert dialog")
        alert.runModal()
      }
      prefs.removePersistentDomain(forName: bundleID)
    }
    prefs.set(currentBuildNumber, forKey: PrefKey.buildNumber.rawValue)
  }

  func setDefaultPrefs() {
    if !prefs.bool(forKey: PrefKey.appAlreadyLaunched.rawValue) {
      // Only settings that are not false, 0 or "" by default are set here. Assumes pre-wiped database.
      prefs.set(true, forKey: PrefKey.appAlreadyLaunched.rawValue)
      // This fork ships its own Sparkle feed, so check for updates automatically by default.
      prefs.set(true, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
    }
    // Point the hardware volume keys at the display that is actually producing sound.
    //
    // The key is absent on a fresh install, and a missing integer reads back as 0 — which is
    // `MultiKeyboardVolume.mouse`. That made the out-of-the-box behaviour "control whichever
    // display the pointer happens to be over", so with the pointer on a display that has no
    // DDC volume (or on the built-in panel, which is not DDC at all) the hardware keys did
    // nothing whatsoever. macOS's own volume keys follow the *default audio output device*,
    // so follow that too until the user chooses otherwise in Settings.
    //
    // Written once rather than resolved on every read, so the Settings popup shows the
    // routing that is actually in effect. A value the user has set is never overwritten.
    if prefs.object(forKey: PrefKey.multiKeyboardVolume.rawValue) == nil {
      prefs.set(MultiKeyboardVolume.audioDeviceNameMatching.rawValue, forKey: PrefKey.multiKeyboardVolume.rawValue)
    }
    // Move the volume keys in 1% steps instead of snapping to the OSD's 16 chiclets.
    //
    // The coarse path in `OtherDisplay.calcNewValue` rounds to the nearest OSD chiclet, and
    // the OSD has 16 of them, so a single press jumps 1/16 of the range — 6.25%, which reads
    // as a step of 6 on a 0-100 display. That is far too coarse to land on a level you want.
    // Passing `isSmallIncrement` moves 1% at a time and draws the OSD with 100 chiclets to
    // match. Option+Shift still flips back to the coarse step for a quick sweep.
    //
    // This is the same setting as the "Use fine OSD scale for volume" checkbox in
    // Settings > Keyboard; defaulting it on just means the keys feel smooth out of the box.
    // A choice the user has already made is never overwritten.
    if prefs.object(forKey: PrefKey.useFineScaleVolume.rawValue) == nil {
      prefs.set(true, forKey: PrefKey.useFineScaleVolume.rawValue)
    }
  }

  @objc   func displayReconfigured() {
    DisplayManager.shared.resetSwBrightnessForAllDisplays(noPrefSave: true)
    // The gamma table belongs to a specific display configuration. Hold onto it across a
    // reconfiguration and it will be applied to a display that is no longer the one we
    // measured.
    XDREngine.shared.stop()
    CGDisplayRestoreColorSyncSettings()
    self.reconfigureID += 1
    self.updateMediaKeyTap()
    os_log("Bumping reconfigureID to %{public}@", type: .info, String(self.reconfigureID))
    _ = DisplayManager.shared.destroyAllShades()
    if self.sleepID == 0 {
      let dispatchedReconfigureID = self.reconfigureID
      os_log("Display to be reconfigured with reconfigureID %{public}@", type: .info, String(dispatchedReconfigureID))
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.configure(dispatchedReconfigureID: dispatchedReconfigureID)
      }
    }
  }

  func configure(dispatchedReconfigureID: Int = 0, firstrun: Bool = false) {
    guard self.sleepID == 0, dispatchedReconfigureID == self.reconfigureID else {
      return
    }
    os_log("Request for configuration with reconfigreID %{public}@", type: .info, String(dispatchedReconfigureID))
    self.reconfigureID = 0
    DisplayManager.shared.gammaInterferenceCounter = 0
    DisplayManager.shared.configureDisplays()
    DisplayManager.shared.addDisplayCounterSuffixes()
    DisplayManager.shared.updateArm64AVServices()
    if firstrun && prefs.integer(forKey: PrefKey.startupAction.rawValue) != StartupAction.write.rawValue {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(prefsOnly: true)
    }
    DisplayManager.shared.setupOtherDisplays(firstrun: firstrun)
    self.updateMenusAndKeys()
    if !firstrun || prefs.integer(forKey: PrefKey.startupAction.rawValue) == StartupAction.write.rawValue {
      if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
        DisplayManager.shared.restoreSwBrightnessForAllDisplays(async: !prefs.bool(forKey: PrefKey.disableSmoothBrightness.rawValue))
      }
    }
    self.resumeXDRForAllDisplays()
    displaysPrefsVc?.loadDisplayList()
    self.job(start: true)
  }

  func updateMenusAndKeys() {
    menu.updateMenus()
    self.keyboardShortcuts.updateRegistrations()
    self.updateMediaKeyTap()
    self.updateStatusIcon()
  }

  func checkPermissions(firstAsk: Bool = false) {
    let permissionsRequired: Bool = [KeyboardVolume.media.rawValue, KeyboardVolume.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardVolume.rawValue)) || [KeyboardBrightness.media.rawValue, KeyboardBrightness.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardBrightness.rawValue))
    // Gate on the real capability, not `readPrivileges`. That call keeps reporting "trusted"
    // after the app is re-signed, so it would decide there is nothing to do in precisely the
    // situation this exists to catch — a grant that survived a rebuild and no longer matches.
    if permissionsRequired, !MediaKeyTapManager.canInstallEventTap() {
      MediaKeyTapManager.acquirePrivileges(firstAsk: firstAsk)
    }
  }

  private func subscribeEventListeners() {
    NotificationCenter.default.addObserver(self, selector: #selector(self.audioDeviceChanged), name: Notification.Name.defaultOutputDeviceChanged, object: nil) // subscribe Audio output detector (SimplyCoreAudio)
    DistributedNotificationCenter.default.addObserver(self, selector: #selector(self.displayReconfigured), name: NSNotification.Name(rawValue: kColorSyncDisplayDeviceProfilesNotification.takeRetainedValue() as String), object: nil) // ColorSync change
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepNotification), name: NSWorkspace.screensDidSleepNotification, object: nil) // sleep and wake listeners
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeNotification), name: NSWorkspace.screensDidWakeNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepNotification), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeNotification), name: NSWorkspace.didWakeNotification, object: nil)
    _ = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(rawValue: NSNotification.Name.accessibilityApi.rawValue), object: nil, queue: nil) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updateMediaKeyTap() } } // listen for accessibility status changes
    self.statusItemObserver = statusItem.observe(\.isVisible, options: [.old, .new]) { _, _ in self.statusItemVisibilityChanged() }
  }

  @objc private func sleepNotification() {
    self.sleepID += 1
    os_log("Sleeping with sleep %{public}@", type: .info, String(self.sleepID))
    // A boosted gamma table must not survive sleep: the panel comes back in SDR mode and
    // would otherwise be left with a ramp written for a backlight that is no longer raised.
    XDREngine.shared.stop()
    self.updateMediaKeyTap()
  }

  @objc private func wakeNotification() {
    if self.sleepID != 0 {
      os_log("Waking up from sleep %{public}@", type: .info, String(self.sleepID))
      let dispatchedSleepID = self.sleepID
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { // Some displays take time to recover...
        self.soberNow(dispatchedSleepID: dispatchedSleepID)
      }
    }
  }

  private func soberNow(dispatchedSleepID: Int) {
    if self.sleepID == dispatchedSleepID {
      os_log("Sober from sleep %{public}@", type: .info, String(self.sleepID))
      self.sleepID = 0
      if self.reconfigureID != 0 {
        let dispatchedReconfigureID = self.reconfigureID
        os_log("Displays need reconfig after sober with reconfigureID %{public}@", type: .info, String(dispatchedReconfigureID))
        self.configure(dispatchedReconfigureID: dispatchedReconfigureID)
      } else if Arm64DDC.isArm64 {
        os_log("Displays don't need reconfig after sober but might need AVServices update", type: .info)
        DisplayManager.shared.updateArm64AVServices()
        self.job(start: true)
      }
      self.startupActionWriteRepeatAfterSober()
      self.updateMediaKeyTap()
      // The boost was dropped on the way to sleep. A wake that also reconfigured the
      // displays picks it up through `configure()`, but a plain sleep/wake never gets there,
      // so the panel would be left at its SDR maximum with the slider still reading 150%.
      self.resumeXDRForAllDisplays()
    }
  }

  /// Re-applies the XDR boost wherever it is meant to be on.
  ///
  /// Nothing writes the boost on its own — it only exists as long as a value above 1.0 has
  /// been pushed through — so it has to be re-sent after launch and after a wake.
  private func resumeXDRForAllDisplays() {
    for display in DisplayManager.shared.displays {
      (display as? AppleDisplay)?.resumeXDRIfNeeded()
    }
  }

  private func startupActionWriteRepeatAfterSober(dispatchedCounter: Int = 0) {
    let counter = dispatchedCounter == 0 ? 10 : dispatchedCounter
    self.startupActionWriteCounter = dispatchedCounter == 0 ? counter : self.startupActionWriteCounter
    guard prefs.integer(forKey: PrefKey.startupAction.rawValue) == StartupAction.write.rawValue, self.startupActionWriteCounter == counter else {
      return
    }
    os_log("Sober write action repeat for DDC - %{public}@", type: .info, String(counter))
    DisplayManager.shared.restoreOtherDisplays()
    self.startupActionWriteCounter = counter - 1
    if counter > 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.startupActionWriteRepeatAfterSober(dispatchedCounter: counter - 1)
      }
    }
  }

  private func job(start: Bool = false) {
    guard !(self.jobRunning && start) else {
      return
    }
    if self.sleepID == 0, self.reconfigureID == 0 {
      if !self.jobRunning {
        os_log("MonitorControl job started.", type: .info)
        self.jobRunning = true
      }
      var refreshedSomething = false
      for display in DisplayManager.shared.displays {
        let delta = display.refreshBrightness()
        if delta != 0 {
          refreshedSomething = true
          if prefs.bool(forKey: PrefKey.enableBrightnessSync.rawValue) {
            for targetDisplay in DisplayManager.shared.displays where targetDisplay != display {
              os_log("Updating delta from display %{public}@ to display %{public}@", type: .info, String(display.identifier), String(targetDisplay.identifier))
              let newValue = max(0, min(targetDisplay.brightnessMaxValue, targetDisplay.getBrightness() + delta))
              _ = targetDisplay.setBrightness(newValue)
              if let slider = targetDisplay.sliderHandler[.brightness] {
                slider.setValue(newValue, displayID: targetDisplay.identifier)
              }
            }
          }
        }
      }
      let nextRefresh = refreshedSomething ? 0.1 : 1.0
      DispatchQueue.main.asyncAfter(deadline: .now() + nextRefresh) {
        self.job()
      }
    } else {
      self.jobRunning = false
      os_log("MonitorControl job died because of sleep or reconfiguration.", type: .info)
    }
  }

  func handleListenForChanged() {
    self.checkPermissions()
    self.updateMediaKeyTap()
  }

  func settingsReset() {
    os_log("Resetting all settings.")
    if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(async: false)
    }
    if let bundleID = Bundle.main.bundleIdentifier {
      prefs.removePersistentDomain(forName: bundleID)
    }
    app.updateStatusItemVisibility(true)
    self.setDefaultPrefs()
    self.checkPermissions()
    self.updateMediaKeyTap()
    self.configure(firstrun: true)
  }

  @objc func audioDeviceChanged() {
    if let defaultDevice = self.coreAudio.defaultOutputDevice {
      os_log("Default output device changed to “%{public}@”.", type: .info, defaultDevice.name)
      os_log("Can device set its own volume? %{public}@", type: .info, defaultDevice.canSetVirtualMainVolume(scope: .output).description)
    }
    self.updateMediaKeyTap()
  }

  func updateMediaKeyTap() {
    MediaKeyTap.useAlternateBrightnessKeys = !prefs.bool(forKey: PrefKey.disableAltBrightnessKeys.rawValue)
    self.mediaKeyTap.updateMediaKeyTap()
  }

  func setStartAtLogin(enabled: Bool) {
    let identifier = "\(Bundle.main.bundleIdentifier!)Helper" as CFString
    SMLoginItemSetEnabled(identifier, enabled)
  }

  func getSystemSettings() -> [String: AnyObject]? {
    var propertyListFormat = PropertyListSerialization.PropertyListFormat.xml
    let plistPath = NSString(string: "~/Library/Preferences/.GlobalPreferences.plist").expandingTildeInPath
    guard let plistXML = FileManager.default.contents(atPath: plistPath) else {
      return nil
    }
    do {
      return try PropertyListSerialization.propertyList(from: plistXML, options: .mutableContainersAndLeaves, format: &propertyListFormat) as? [String: AnyObject]
    } catch {
      os_log("Error reading system prefs plist: %{public}@", type: .info, error.localizedDescription)
      return nil
    }
  }

  func macOS10() -> Bool {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return false
    } else {
      return true
    }
  }

  func playVolumeChangedSound() {
    guard let settings = app.getSystemSettings(), let hasSoundEnabled = settings["com.apple.sound.beep.feedback"] as? Int, hasSoundEnabled == 1 else {
      return
    }
    do {
      self.audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"))
      self.audioPlayer?.volume = 1
      self.audioPlayer?.play()
    } catch {
      os_log("%{public}@", type: .error, error.localizedDescription)
    }
  }

  private func setMenu() {
    menu = MenuHandler()
    menu.delegate = menu
    self.statusItem.menu = menu
    // The boost ramps in over a couple of seconds as macOS raises the backlight, so the
    // icon cannot be driven from the places that rebuild the menu — it has to follow the
    // engine. Without this the icon would lag the screen by seconds at both ends.
    XDREngine.shared.onBoostActiveChanged = { [weak self] in
      self?.updateStatusIcon()
    }
    self.updateStatusIcon()
  }

  /// Turns the menu bar icon yellow while a boost is actually brightening a display.
  ///
  /// Deliberately tied to the boost rather than to the setting: XDR can be enabled while
  /// sitting at 80%, and reporting that as "on" would be a lie. The boost is also invisible
  /// to everything else — it lives in the gamma table, not in any brightness value the
  /// system reports — so the icon is the only signal there is.
  func updateStatusIcon() {
    let boosting = DisplayManager.shared.displays.contains { ($0 as? AppleDisplay)?.isXDRBoosting == true }
    self.statusItem.button?.image = Self.statusIcon(xdrActive: boosting)
  }

  private static func statusIcon(xdrActive: Bool) -> NSImage? {
    guard let base = NSImage(named: "status") else {
      return nil
    }
    guard xdrActive else {
      return base
    }
    // "status" is a template asset, so it draws as a black silhouette. Flooding that
    // silhouette with yellow and clearing the template flag leaves a yellow icon — the
    // template flag has to go, or the status bar would strip the colour straight back out.
    let tinted = NSImage(size: base.size)
    tinted.lockFocus()
    let rect = NSRect(origin: .zero, size: base.size)
    base.draw(in: rect, from: NSRect(origin: .zero, size: base.size), operation: .sourceOver, fraction: 1.0)
    NSColor.systemYellow.setFill()
    rect.fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.isTemplate = false
    return tinted
  }

  private func showSafeModeAlertIfNeeded() {
    if NSEvent.modifierFlags.contains(NSEvent.ModifierFlags.shift) {
      self.safeMode = true
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Safe Mode Activated", comment: "Shown in the alert dialog")
      alert.informativeText = NSLocalizedString("Shift was pressed during launch. MonitorControl started in safe mode. Default settings are reloaded, DDC read is blocked.", comment: "Shown in the alert dialog")
      alert.runModal()
    }
  }

  private func showOnboardingWindow() {
    onboardingVc?.showWindow(self)
    onboardingVc?.window?.center()
    NSApp.activate(ignoringOtherApps: true)
  }
  
  private func statusItemVisibilityChanged() {
    if !self.statusItem.isVisible, self.statusItemVisibilityChangedByUser {
      prefs.set(MenuIcon.hide.rawValue, forKey: PrefKey.menuIcon.rawValue)
    }
  }
  
  func updateStatusItemVisibility(_ visible: Bool) {
    statusItemVisibilityChangedByUser = false
    statusItem.isVisible = visible
    statusItemVisibilityChangedByUser = true
  }
}
