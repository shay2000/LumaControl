//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import os.log

class AppleDisplay: Display {
  private var displayQueue: DispatchQueue
  var isXDRCapable: Bool = false
  var xdrMaxValue: Float = 1.5
  var xdrPromptShown: Bool = false

  var effectiveBrightnessMax: Float {
    (self.isXDRCapable && self.readPrefAsBool(key: .xdrEnabled)) ? self.xdrMaxValue : 1.0
  }

  override var brightnessMaxValue: Float { self.effectiveBrightnessMax }

  override init(_ identifier: CGDirectDisplayID, name: String, vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?, isVirtual: Bool = false, isDummy: Bool = false) {
    self.displayQueue = DispatchQueue(label: String("displayQueue-\(identifier)"))
    super.init(identifier, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber, serialNumber: serialNumber, isVirtual: isVirtual, isDummy: isDummy)
    self.detectXDRCapability()
  }

  // Probes whether the display accepts brightness values above the standard maximum (1.0),
  // which is the case on XDR panels like the MacBook Pro Liquid Retina XDR or the Pro Display XDR.
  private func detectXDRCapability() {
    guard !self.isDummy, !self.isVirtual else {
      return
    }
    // If a previous probe already found an XDR maximum, trust it — probing changes the panel
    // brightness for a moment, so it should only ever run once per display.
    let savedMax = self.readPrefAsFloat(key: .xdrMaxBrightness)
    if savedMax > 1.0 {
      self.isXDRCapable = true
      self.xdrMaxValue = savedMax
      return
    }
    // If a previous probe already determined that this display is not XDR capable, don't probe again.
    if self.readPrefAsBool(key: .xdrProbed) {
      return
    }
    var currentBrightness: Float = 0
    guard DisplayServicesGetBrightness(self.identifier, &currentBrightness) == 0 else {
      // If the current brightness can't be read we must not write anything,
      // otherwise a failed read could be "restored" as brightness 0 (black screen).
      return
    }
    DisplayServicesSetBrightness(self.identifier, 1.01)
    var readBackBrightness: Float = 0
    let readBackResult = DisplayServicesGetBrightness(self.identifier, &readBackBrightness)
    // Restore the original brightness.
    DisplayServicesSetBrightness(self.identifier, currentBrightness)
    guard readBackResult == 0 else {
      // A failed read-back is likely transient (e.g. right after wake) — don't cache it
      // as a negative result, just probe again next time.
      return
    }
    self.savePref(true, key: .xdrProbed)
    if readBackBrightness > 1.0 {
      self.isXDRCapable = true
      self.xdrMaxValue = 1.5
      self.savePref(self.xdrMaxValue, key: .xdrMaxBrightness)
      os_log("XDR capable display detected: %{public}@, max: %{public}@", type: .info, String(self.identifier), String(self.xdrMaxValue))
    }
  }

  func resetToNormalBrightness() {
    _ = self.setBrightness(1.0)
    if let sliderHandler = self.sliderHandler[.brightness] {
      sliderHandler.setValue(1.0, displayID: self.identifier)
    }
  }

  func disableXDR() {
    self.savePref(false, key: .xdrEnabled)
    self.xdrPromptShown = false
    _ = self.setBrightness(1.0)
    DispatchQueue.main.async {
      app.updateMenusAndKeys()
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

  override func setDirectBrightness(_ to: Float, transient: Bool = false) -> Bool {
    guard !self.isDummy else {
      return false
    }
    let value = max(min(to, self.effectiveBrightnessMax), 0)
    self.setAppleBrightness(value: value)
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
    let brightness = self.getAppleBrightness()
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
