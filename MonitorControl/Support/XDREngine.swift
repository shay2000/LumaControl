//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Metal
import QuartzCore
import os.log

/// Drives a display past its SDR brightness ceiling.
///
/// `DisplayServicesSetBrightness()` hard-clamps at 1.0. Measured on the built-in Liquid
/// Retina XDR panel: writes of 1.0625, 1.125, 1.25, 1.375, 1.5, 1.75 and 2.0 all read back
/// exactly 1.0. Extended brightness therefore cannot be reached through any brightness
/// setter, and there is no private API that does it either — the HDR variants do not exist,
/// and `DisplayServicesSetLinearBrightness` / `CoreDisplay_Display_SetUserBrightness` take
/// different arguments and crash if called on a guess.
///
/// What does work is the route macOS itself uses for HDR: it raises the backlight above SDR
/// white only while extended-dynamic-range content is on screen, and then leaves the extra
/// range to be addressed by the display pipeline. Two stages:
///
///   1. **EDR activation.** A 2x2 borderless window whose `CAMetalLayer` has
///      `wantsExtendedDynamicRangeContent = true` and is cleared to a component value above
///      1.0. macOS raises the backlight as soon as EDR content is visible anywhere, no matter
///      how little of it there is. Measured headroom went from 1.2 to 5.33 in about 2 s.
///   2. **Gamma scaling.** The display's gamma table is read once, multiplied by the boost
///      factor and written back with `CGSetDisplayTransferByTable`. Gamma is applied at the
///      very end of the pipeline, so it lifts everything uniformly — hardware video planes,
///      Space transitions and the cursor included.
///
/// Only public APIs are used. Two consequences worth knowing: the backlight runs in HDR mode
/// for as long as a boost is applied, which costs power and runs warmer, and the gamma table
/// is ours while we hold it, which conflicts with anything else that writes gamma (f.lux,
/// Gamma Control). Night Shift and True Tone are unaffected.
///
/// The boost a caller asks for is an *ideal*: it is clamped to the headroom macOS currently
/// reports and re-applied five times a second, so it ramps up smoothly as the backlight
/// climbs instead of snapping, and backs off if macOS withdraws headroom.
final class XDREngine {
  static let shared = XDREngine()

  private let tableSize: UInt32 = 256

  /// Component value the EDR layer is cleared to. A higher value asks macOS for more
  /// headroom; 4.0 yielded 5.33 on a Liquid Retina XDR panel, comfortably covering the 2.0
  /// ceiling the app offers.
  private let edrClearValue: Double = 4.0

  /// Anything at or below this counts as "not boosted", absorbing the rounding in both the
  /// requested value and the headroom clamp.
  private let boostThreshold: Double = 1.005

  private var activeDisplay: CGDirectDisplayID?
  private var originalRed = [CGGammaValue](repeating: 0, count: 256)
  private var originalGreen = [CGGammaValue](repeating: 0, count: 256)
  private var originalBlue = [CGGammaValue](repeating: 0, count: 256)
  private var hasOriginalTable = false

  private var window: NSWindow?
  private var metalLayer: CAMetalLayer?
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var redrawTimer: Timer?

  private var requestedBoost: Double = 1.0
  private var appliedBoost: Double = 1.0

  private init() {}

  // MARK: - Capability

  static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    }
  }

  /// Whether the panel has any range above SDR white to unlock at all.
  ///
  /// This asks the system rather than prodding the panel, so it is free of side effects and
  /// can be called at launch. A MacBook Air, an iMac or a Studio Display answers no.
  static func isCapable(_ displayID: CGDirectDisplayID) -> Bool {
    guard let screen = Self.screen(for: displayID) else {
      return false
    }
    if #available(macOS 15.0, *) {
      return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }
    return screen.maximumExtendedDynamicRangeColorComponentValue > 1.0
  }

  /// How much range macOS is granting right now: ~1.2 while in SDR mode, several times that
  /// once EDR content is on screen.
  static func headroom(for displayID: CGDirectDisplayID) -> CGFloat {
    Self.screen(for: displayID)?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
  }

  // MARK: - Control

  /// Requests a boost, where 1.0 means "no boost, ordinary SDR".
  ///
  /// Safe to call repeatedly with the same value; the gamma table is only rewritten when the
  /// target actually moves.
  func setBoost(_ boost: Double, for displayID: CGDirectDisplayID) {
    let wanted = max(boost, 1.0)
    guard wanted > 1.005 else {
      // Only tear down a session belonging to this display; another display's boost is none
      // of our business.
      if self.activeDisplay == nil || self.activeDisplay == displayID {
        self.stop()
      }
      return
    }
    if let active = self.activeDisplay, active != displayID {
      self.stop()
    }
    self.requestedBoost = wanted
    self.activeDisplay = displayID
    self.start()
    self.applyBoost()
  }

  private func notifyIfBoostCrossed(wasActive: Bool) {
    guard self.isActive != wasActive else {
      return
    }
    DispatchQueue.main.async { self.onBoostActiveChanged?() }
  }

  /// Called on the main thread whenever a display crosses between "boosted" and "not
  /// boosted". The menu bar icon follows the boost rather than the setting, and the boost
  /// turns over asynchronously — it ramps in as the backlight rises — so it cannot be
  /// polled from the places that rebuild the menu.
  var onBoostActiveChanged: (() -> Void)?

  /// The boost currently written to this display's gamma table, 1.0 when there is none.
  func appliedBoost(for displayID: CGDirectDisplayID) -> Double {
    self.activeDisplay == displayID ? self.appliedBoost : 1.0
  }

  /// True while a boost is actually being applied to any display.
  var isActive: Bool {
    self.appliedBoost > self.boostThreshold
  }

  /// Restores the gamma table and drops the EDR window. Called on disable, on quit, on
  /// display reconfiguration and on sleep.
  func stop() {
    // `setBoost(1.0, …)` is the "no boost" case, and `AppleDisplay` sends it on *every*
    // write below 1.0 — which during a smooth brightness ramp is many times a second. Without
    // this guard each of those would restore the gamma table, tear down the window and log a
    // line, so ordinary brightness changes below 100% would thrash CoreGraphics for nothing.
    guard self.activeDisplay != nil || self.window != nil || self.redrawTimer != nil else {
      return
    }
    let wasActive = self.isActive
    self.redrawTimer?.invalidate()
    self.redrawTimer = nil
    self.window?.orderOut(nil)
    self.window = nil
    self.metalLayer = nil
    self.metalDevice = nil
    self.commandQueue = nil
    if let displayID = self.activeDisplay, self.hasOriginalTable {
      CGSetDisplayTransferByTable(displayID, self.tableSize, self.originalRed, self.originalGreen, self.originalBlue)
      os_log("Restored the original gamma table for display %{public}@.", type: .info, String(displayID))
    }
    self.activeDisplay = nil
    self.hasOriginalTable = false
    self.requestedBoost = 1.0
    self.appliedBoost = 1.0
    self.notifyIfBoostCrossed(wasActive: wasActive)
  }

  // MARK: - Internals

  private func start() {
    guard self.window == nil, let displayID = self.activeDisplay, let screen = Self.screen(for: displayID) else {
      return
    }
    if !self.hasOriginalTable {
      self.captureGammaTable(for: displayID)
      guard self.hasOriginalTable else {
        return
      }
    }
    self.createEDRWindow(on: screen)
    guard self.window != nil else {
      return
    }
    if self.redrawTimer == nil {
      // `.common` matters: the default mode stops firing while a menu is tracking, which is
      // exactly when the user is dragging the brightness slider. Without it the EDR content
      // goes stale and macOS drops the backlight back down mid-drag.
      let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
        self?.drawEDRContent()
        self?.applyBoost()
      }
      timer.tolerance = 0.08
      RunLoop.main.add(timer, forMode: .common)
      self.redrawTimer = timer
    }
    os_log("XDR boost session started for display %{public}@.", type: .info, String(displayID))
  }

  private func applyBoost() {
    guard let displayID = self.activeDisplay, self.hasOriginalTable else {
      return
    }
    let target = min(self.requestedBoost, Double(Self.headroom(for: displayID)))
    guard abs(target - self.appliedBoost) > 0.003 else {
      return
    }
    let wasActive = self.isActive
    var red = [CGGammaValue](repeating: 0, count: Int(self.tableSize))
    var green = [CGGammaValue](repeating: 0, count: Int(self.tableSize))
    var blue = [CGGammaValue](repeating: 0, count: Int(self.tableSize))
    for index in 0 ..< Int(self.tableSize) {
      red[index] = CGGammaValue(min(Double(self.originalRed[index]) * target, 64.0))
      green[index] = CGGammaValue(min(Double(self.originalGreen[index]) * target, 64.0))
      blue[index] = CGGammaValue(min(Double(self.originalBlue[index]) * target, 64.0))
    }
    let result = CGSetDisplayTransferByTable(displayID, self.tableSize, red, green, blue)
    guard result == .success else {
      os_log("Could not write the gamma table for display %{public}@ (error %{public}@).", type: .error, String(displayID), String(result.rawValue))
      return
    }
    self.appliedBoost = target
    self.notifyIfBoostCrossed(wasActive: wasActive)
    os_log("XDR boost for display %{public}@ now %{public}@.", type: .info, String(displayID), String(format: "%.3f", target))
  }

  /// Reads the table we will scale from, exactly once per session.
  ///
  /// Reading it again mid-session would read back our own boosted copy and compound, so the
  /// original is kept and every write is derived from it.
  private func captureGammaTable(for displayID: CGDirectDisplayID) {
    var red = [CGGammaValue](repeating: 0, count: Int(self.tableSize))
    var green = [CGGammaValue](repeating: 0, count: Int(self.tableSize))
    var blue = [CGGammaValue](repeating: 0, count: Int(self.tableSize))
    var sampleCount: UInt32 = 0
    let result = CGGetDisplayTransferByTable(displayID, self.tableSize, &red, &green, &blue, &sampleCount)
    guard result == .success, sampleCount > 0 else {
      os_log("Could not read the gamma table for display %{public}@; XDR boost skipped.", type: .error, String(displayID))
      self.hasOriginalTable = false
      return
    }
    self.originalRed = red
    self.originalGreen = green
    self.originalBlue = blue
    self.hasOriginalTable = true
  }

  private func createEDRWindow(on screen: NSScreen) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      os_log("No Metal device available, so XDR brightness cannot be applied.", type: .error)
      return
    }
    self.metalDevice = device
    self.commandQueue = queue

    let rect = NSRect(x: screen.frame.origin.x, y: screen.frame.origin.y, width: 2, height: 2)
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .normal
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .rgba16Float
    layer.wantsExtendedDynamicRangeContent = true
    layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    layer.framebufferOnly = false
    layer.isOpaque = false

    let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
    view.wantsLayer = true
    view.layer = layer
    window.contentView = view
    window.orderFrontRegardless()

    self.window = window
    self.metalLayer = layer
  }

  private func drawEDRContent() {
    guard let layer = self.metalLayer, let queue = self.commandQueue, let drawable = layer.nextDrawable() else {
      return
    }
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: self.edrClearValue, green: self.edrClearValue, blue: self.edrClearValue, alpha: 1.0)
    guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }
    encoder.endEncoding()
    buffer.present(drawable)
    buffer.commit()
  }
}
