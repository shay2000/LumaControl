//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

class AppleDisplay: Display {
  private var displayQueue: DispatchQueue
  var isXDRCapable: Bool = false
  /// Brightness at the top of the extended range, where 1.0 is the SDR maximum.
  ///
  /// 2.0 takes the panel from its 500-nit SDR ceiling to roughly the 1000 nits it can
  /// sustain full-screen, which is the range Apple documents for this panel. It sits well
  /// inside the headroom macOS grants (~5.3 on a Liquid Retina XDR), so the ceiling is never
  /// the limiting factor.
  var xdrMaxValue: Float = 2.0
  var xdrPromptShown: Bool = false

  var isXDREnabled: Bool {
    self.isXDRCapable && self.readPrefAsBool(key: .xdrEnabled)
  }

  var effectiveBrightnessMax: Float {
    self.isXDREnabled ? self.xdrMaxValue : 1.0
  }

  /// What the panel is actually showing, taking the gamma boost into account.
  ///
  /// While a boost is applied the standard brightness is pinned at 1.0 and everything above
  /// it lives in the gamma table, so `getAppleBrightness()` alone reports 1.0 for anything
  /// from 100% to 200%. Feeding that straight back into the slider made the thumb slide back
  /// down to 100% a second after the user dragged it up, while the screen stayed bright.
  var effectiveBrightness: Float {
    let boost = Float(XDREngine.shared.appliedBoost(for: self.identifier))
    return boost > 1.005 ? boost : self.getAppleBrightness()
  }

  /// True only while the boost is actually brightening things, which is a narrower
  /// condition than XDR merely being enabled.
  var isXDRBoosting: Bool {
    XDREngine.shared.appliedBoost(for: self.identifier) > 1.005
  }

  override var brightnessMaxValue: Float { self.effectiveBrightnessMax }

  /// The built-in panel raises macOS's native brightness OSD through `OSDManager` only on
  /// systems where that overlay still behaves. On macOS 27 it leaves the OSD permanently
  /// drawn: `showImage:…:msecUntilFade:` neither honours the fade timer nor accepts a
  /// later update that should replace it, so once raised it stays up while the app is
  /// running. Everywhere else the OSD is shown, so pressing the brightness keys gives the
  /// same visual feedback macOS itself would; the menu-bar sun going yellow when a boost
  /// is active, the XDR opt-in dialog at 100 %, and the live slider in the menu are the
  /// visible feedback instead where it is not.
  override var showsBrightnessOSD: Bool {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
  }

  /// True when the panel can do extended brightness but the user has not switched it on.
  var canOfferXDR: Bool {
    self.isXDRCapable && !self.readPrefAsBool(key: .xdrEnabled)
  }

  override init(_ identifier: CGDirectDisplayID, name: String, vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?, isVirtual: Bool = false, isDummy: Bool = false) {
    self.displayQueue = DispatchQueue(label: String("displayQueue-\(identifier)"))
    super.init(identifier, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
    self.detectXDRCapability()
  }

  // Works out whether the panel has brightness above the standard maximum (1.0) to give.
  //
  // This asks macOS rather than prodding the panel, because the obvious test — write a value
  // above 1.0 and see whether it sticks — can never succeed: `DisplayServicesSetBrightness`
  // hard-clamps at 1.0. On a Liquid Retina XDR panel, writes of 1.0625 through 2.0 all read
  // back exactly 1.0. An earlier version of this method did exactly that, so it recorded
  // "not XDR" for a genuinely XDR panel and then cached that verdict in preferences forever.
  //
  // The public-API answer is `maximumPotentialExtendedDynamicRangeColorComponentValue`: the
  // panel's whole EDR range (16.0 here), not the slice macOS happens to be handing out.
  private func detectXDRCapability() {
    guard !self.isDummy, !self.isVirtual else {
      return
    }
    self.isXDRCapable = XDREngine.isCapable(self.identifier)
    if self.isXDRCapable {
      os_log("XDR capable display detected: %{public}@.", type: .info, String(self.identifier))
    }
    // A ceiling chosen earlier, if any. Clamped so a hand-edited preference cannot ask the
    // panel for more than the system will follow.
    let savedMax = self.readPrefAsFloat(key: .xdrMaxBrightness)
    if savedMax > 1.0 {
      self.xdrMaxValue = min(savedMax, 4.0)
    }
  }

  /// Switches extended brightness on. Does nothing if the panel cannot do it.
  func enableXDR() {
    guard self.isXDRCapable else {
      return
    }
    self.savePref(true, key: .xdrEnabled)
    self.savePref(true, key: .xdrWarningAcknowledged)
    self.xdrPromptShown = true
    // The slider can now reach further, but the panel itself only moves once the value
    // crosses 1.0 — so leave the hardware alone unless it is already above the SDR maximum.
    self.applyBrightnessToPanel(self.getBrightness())
    DispatchQueue.main.async {
      app.updateMenusAndKeys()
    }
  }

  /// Offers the XDR opt-in warning. Returns `true` when XDR is on as a result.
  ///
  /// `force` bypasses the once-per-session guard and any stored "don't warn again" answer,
  /// so the explicit "Enable XDR Extended Brightness" menu item always reaches the user.
  @discardableResult
  func promptToEnableXDR(force: Bool = false) -> Bool {
    guard self.canOfferXDR else {
      return self.readPrefAsBool(key: .xdrEnabled)
    }
    if !force, self.xdrPromptShown {
      return false
    }
    self.xdrPromptShown = true
    if !force, self.readPrefAsBool(key: .xdrDontWarnAgain) {
      // The stored answer is honoured silently. Ticking the box with "Enable XDR Brightness"
      // means "always do this"; ticking it with "Stay at 100%" means "stop asking and leave
      // it off". Either way XDR is never switched on behind the user's back — that box only
      // suppresses the question, it does not opt in on its own.
      if self.readPrefAsBool(key: .xdrAutoEnable) {
        self.enableXDR()
        return true
      }
      return false
    }
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Brightness is entering the XDR range", comment: "Shown in the alert dialog")
    alert.informativeText = String(format: NSLocalizedString("This display has reached 100%%, the brightest it goes in standard mode.\n\nXDR mode unlocks brightness up to %@ by keeping the panel in HDR. It uses noticeably more power, runs warmer, and the display may dim itself if it gets hot.\n\nYou can turn it off again from this display's menu.", comment: "Shown in the alert dialog"), "\(Int(self.xdrMaxValue * 100))%")
    alert.addButton(withTitle: NSLocalizedString("Enable XDR Brightness", comment: "Shown in the alert dialog"))
    alert.addButton(withTitle: NSLocalizedString("Stay at 100%", comment: "Shown in the alert dialog"))
    alert.alertStyle = .warning
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = NSLocalizedString("Don't warn me again", comment: "Shown in the alert dialog")
    let response = alert.runModal()
    // Remembering the answer is the point of the checkbox, so store the decision alongside
    // it rather than only the fact that the warning was dismissed.
    if alert.suppressionButton?.state == .on {
      let enable = response == .alertFirstButtonReturn
      self.savePref(true, key: .xdrDontWarnAgain)
      self.savePref(enable, key: .xdrAutoEnable)
      os_log("XDR warning suppressed for display %{public}@ with auto-enable %{public}@.", type: .info, String(self.identifier), String(enable))
    }
    guard response == .alertFirstButtonReturn else {
      return false
    }
    self.enableXDR()
    return true
  }

  /// Returns brightness to the standard maximum. XDR stays enabled, so the extended
  /// range remains available; use `disableXDR()` to leave it entirely.
  func resetToNormalBrightness() {
    // Allow the opt-in offer to be shown again, otherwise a user who reset here could
    // never be re-prompted without restarting the app.
    self.xdrPromptShown = false
    _ = self.setBrightness(1.0)
    if let sliderHandler = self.sliderHandler[.brightness] {
      sliderHandler.setValue(1.0, displayID: self.identifier)
    }
    DispatchQueue.main.async {
      app.updateMenusAndKeys()
    }
  }

  func disableXDR() {
    self.savePref(false, key: .xdrEnabled)
    self.xdrPromptShown = false
    // Come back inside the standard range first; that also releases the gamma table.
    _ = self.setBrightness(min(self.getBrightness(), 1.0))
    XDREngine.shared.stop()
    // Refresh the slider so its range and red XDR zone follow the new maximum. The menu
    // rebuild below recreates the handler, but the live one must not be left stale.
    self.sliderHandler[.brightness]?.updateSliderXDRRange()
    DispatchQueue.main.async {
      app.updateMenusAndKeys()
    }
  }

  /// Re-applies the stored brightness after launch or a display reconfiguration.
  ///
  /// Nothing writes to the panel on its own, so without this a session left at 150% comes
  /// back with the slider in the right place and the panel sitting at the SDR maximum.
  func resumeXDRIfNeeded() {
    guard self.isXDREnabled else {
      return
    }
    self.applyBrightnessToPanel(self.getBrightness())
  }

  /// Brings the app's record of brightness back in line with the panel after a wake that
  /// killed the XDR boost.
  ///
  /// Sleep tears the boost down, and the resume a few seconds after waking can still
  /// fail: the EDR window cannot be re-created, or macOS has withdrawn the extended
  /// range. The stored preference then keeps claiming the panel is at, say, 150% while it
  /// is really at the SDR maximum, and the slider follows the preference. Rather than
  /// leave that lie in place — with the extended range still enabled and one drag away —
  /// fall back to the standard range at whatever brightness the panel is actually
  /// showing. XDR stays enabled, so pushing past 100% starts the boost again.
  func reconcileXDRStateAfterWake() {
    guard self.isXDREnabled else {
      return
    }
    guard self.getBrightness() > 1.005, !self.isXDRBoosting else {
      return
    }
    var actual = self.getAppleBrightness()
    if !(0.001 ... 1.0).contains(actual) {
      // A failed read leaves 0 behind, and while the boost ran the SDR side was pinned at
      // the maximum, so fall back to that rather than trusting a dark-screen reading.
      actual = 1.0
    }
    os_log("XDR boost did not survive the wake on display %{public}@; snapping brightness back to %{public}@.", type: .info, String(self.identifier), String(actual))
    _ = self.setBrightness(actual)
    if let sliderHandler = self.sliderHandler[.brightness] {
      sliderHandler.setValue(actual, displayID: self.identifier)
    }
    DispatchQueue.main.async {
      app.updateMenusAndKeys()
    }
  }

  override func stepBrightness(isUp: Bool, isSmallIncrement: Bool) {
    super.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
    // Only act when the user is pushing up against the ceiling: that is when the XDR
    // offer is relevant.
    guard isUp, self.getBrightness() >= self.brightnessMaxValue - 0.001 else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.promptToEnableXDR() else {
        return
      }
      self.sliderHandler[.brightness]?.updateSliderXDRRange()
    }
  }

  func getAppleBrightness() -> Float {
    guard !self.isDummy else {
      return 1
    }
    var brightness: Float = 0
    DisplayServicesGetBrightness(self.identifier, &brightness)
    return brightness
  }

  func setAppleBrightness(value: Float) {
    guard !self.isDummy else {
      return
    }
    _ = self.displayQueue.sync {
      DisplayServicesSetBrightness(self.identifier, value)
    }
  }

  /// Splits a value across the two mechanisms: standard brightness up to 1.0, then the
  /// gamma boost for everything above it.
  private func applyBrightnessToPanel(_ value: Float) {
    if self.isXDREnabled, value > 1.0 {
      // Pin standard brightness at its maximum and let the boost do the rest. Doing it the
      // other way round would waste part of the range.
      self.setAppleBrightness(value: 1.0)
      XDREngine.shared.setBoost(Double(value), for: self.identifier)
    } else {
      // Drop the boost before moving standard brightness, so the two are never both applied
      // at once on the way down.
      XDREngine.shared.setBoost(1.0, for: self.identifier)
      self.setAppleBrightness(value: value)
    }
  }

  override func setDirectBrightness(_ to: Float, transient: Bool = false) -> Bool {
    guard !self.isDummy else {
      return false
    }
    let value = max(min(to, self.effectiveBrightnessMax), 0)
    self.applyBrightnessToPanel(value)
    if !transient {
      self.savePref(value, for: .brightness)
      self.brightnessSyncSourceValue = value
      self.smoothBrightnessTransient = value
    }
    return true
  }

  override func getBrightness() -> Float {
    guard !self.isDummy else {
      return 1
    }
    if self.prefExists(for: .brightness) {
      return self.readPrefAsFloat(for: .brightness)
    } else {
      return self.getAppleBrightness()
    }
  }

  override func refreshBrightness() -> Float {
    guard !self.smoothBrightnessRunning else {
      return 0
    }
    // Counter macOS's ambient-light auto-brightness: while we are boosting it will
    // silently overwrite the value we pinned at 1.0, which dims the panel back to a
    // fraction of the boost (0.7 * 1.06 ≈ 0.74 effective). Snap the SDR side back to
    // 1.0 so the gamma boost remains the only thing shaping how bright the screen
    // looks. Runs only while idle — during a smooth ramp `applyBrightnessToPanel` is
    // already writing 1.0 each tick, and polling while it does that would just churn.
    if self.isXDRBoosting {
      let raw = self.getAppleBrightness()
      if abs(raw - 1.0) > 0.005 {
        os_log("Re-pinning SDR brightness to 1.0 against auto-brightness drift on %{public}@.", type: .info, String(self.identifier))
        self.setAppleBrightness(value: 1.0)
      }
    }
    // Must be the effective value, not the raw one: while boosted the raw reading is pinned
    // at 1.0, and treating that as the truth drags the slider back down.
    let brightness = self.effectiveBrightness
    let oldValue = self.brightnessSyncSourceValue
    self.savePref(brightness, for: .brightness)
    if brightness != oldValue {
      os_log("Pushing slider and reporting delta for Apple display %{public}@", type: .info, String(self.identifier))
      var newValue: Float

      if abs(brightness - oldValue) < 0.01 {
        newValue = brightness
      } else if brightness > oldValue {
        newValue = oldValue + max((brightness - oldValue) / 3, 0.005)
      } else {
        newValue = oldValue + min((brightness - oldValue) / 3, -0.005)
      }
      self.brightnessSyncSourceValue = newValue
      if let sliderHandler = self.sliderHandler[.brightness] {
        sliderHandler.setValue(newValue, displayID: self.identifier)
      }
      return newValue - oldValue
    }
    return 0
  }
}
