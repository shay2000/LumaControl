//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

/// Shared geometry for the popout menu.
///
/// Every element derives from these values so that the slider rows, the display "card"
/// and the settings/quit row all sit on one content column. Each of those three used to
/// carry its own magic offsets (13, 12, 15, `13 + 13`, `-12`), which is how the icon
/// ended up straddling the card border and the icon, label and slider drifted onto three
/// different left edges.
enum MenuMetrics {
  /// Gap between the menu item's edge and the outside of the card.
  static let outerMargin: CGFloat = 6
  /// Gap between the card's edge and its content.
  static let cardPadding: CGFloat = 10
  /// Horizontal inset from the content edge to an icon.
  static let iconGutter: CGFloat = 6
  /// Menu items follow the 16 pt icon convention.
  static let iconSize: CGFloat = 16
  /// Gap between an icon and the control it labels.
  static let iconToControl: CGFloat = 8
  /// Height of the slider control itself.
  static let sliderHeight: CGFloat = 16
  /// Equal padding above and below the slider, so the control is centred in its row.
  static let rowPadding: CGFloat = 7
  /// Gap between the last slider and the display name label.
  static let labelGap: CGFloat = 8
  static let sliderWidth: CGFloat = 180
  static let percentWidth: CGFloat = 34
  static let percentGap: CGFloat = 6

  /// x offset of the slider inside a row view.
  static var controlInset: CGFloat { iconGutter + iconSize + iconToControl }
  /// Height of one slider row.
  static var rowHeight: CGFloat { sliderHeight + rowPadding * 2 }

  /// Width of one slider row.
  static func rowWidth(showPercent: Bool) -> CGFloat {
    controlInset + sliderWidth + (showPercent ? percentGap + percentWidth : 0) + iconGutter
  }

  /// Width of the display card: the row plus padding on both sides.
  static func cardWidth(showPercent: Bool) -> CGFloat {
    rowWidth(showPercent: showPercent) + cardPadding * 2
  }

  /// Width of a menu item view, including the margin outside the card.
  static func itemWidth(showPercent: Bool) -> CGFloat {
    cardWidth(showPercent: showPercent) + outerMargin * 2
  }
}

class SliderHandler {
  var slider: MCSlider?
  var view: NSView?
  var percentageBox: NSTextField?
  var displays: [Display] = []
  var values: [CGDirectDisplayID: Float] = [:]
  var title: String
  let command: Command
  var icon: ClickThroughImageView?

  class MCSliderCell: NSSliderCell {
    // These must be dynamic (appearance-resolving) colours. Hard-coding white here and
    // black on the icon meant one of the two was always invisible: a white knob and fill
    // vanish into a light menu, a black icon vanishes into a dark or glassy one.
    let knobFillColor = NSColor.labelColor
    let knobFillColorTracking = NSColor.labelColor.withAlphaComponent(0.8)
    let knobStrokeColor = NSColor.systemGray.withAlphaComponent(0.5)
    let knobShadowColor = NSColor(white: 0, alpha: 0.03)
    let barFillColor = NSColor.systemGray.withAlphaComponent(0.2)
    let barStrokeColor = NSColor.systemGray.withAlphaComponent(0.5)
    let barFilledFillColor = NSColor.labelColor
    // Extended (XDR/HDR) brightness ramp. Anchored to the value scale rather than to the
    // filled width, so a given brightness always reads the same colour.
    let barXDRStartColor = NSColor.systemYellow
    let barXDRMidColor = NSColor.systemOrange
    let barXDREndColor = NSColor.systemRed
    let xdrThresholdMarkerColor = NSColor.labelColor.withAlphaComponent(0.35)
    let highlightDisplayIndicatorColor = NSColor.labelColor.withAlphaComponent(0.85) // This is visible if there is more the 2 displays
    let tickMarkColor = NSColor.systemGray.withAlphaComponent(0.5)
    var isXDRSlider: Bool = false

    /// Called after the user releases the slider. Used to offer the XDR opt-in once the
    /// drag has finished, rather than while it is still tracking.
    var onTrackingEnded: (() -> Void)?

    let inset: CGFloat = 3.5
    // `barRect` insets symmetrically around the knob, so the old (-1.5, -1.5) optical
    // offset only served to push the track off-centre in its row.
    let offsetX: CGFloat = 0
    let offsetY: CGFloat = 0

    let tickMarkKnobExtraInset: CGFloat = 4
    let tickMarkKnobExtraRadiusMultiplier: CGFloat = 0.25

    var numOfTickmarks: Int = 0
    var isHighlightDisplayItems: Bool = false
    var displayHighlightItems: [CGDirectDisplayID: Float] = [:]

    var isTracking: Bool = false

    required init(coder aDecoder: NSCoder) {
      super.init(coder: aDecoder)
    }

    override init() {
      super.init()
    }

    override func barRect(flipped: Bool) -> NSRect {
      let bar = super.barRect(flipped: flipped)
      let knob = super.knobRect(flipped: flipped)
      return NSRect(x: bar.origin.x, y: knob.origin.y, width: bar.width, height: knob.height).insetBy(dx: 0, dy: self.inset).offsetBy(dx: self.offsetX, dy: self.offsetY)
    }

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
      self.isTracking = true
      return super.startTracking(at: startPoint, in: controlView)
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
      self.isTracking = false
      let result = super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
      self.onTrackingEnded?()
      return result
    }

    override func drawKnob(_ knobRect: NSRect) {
      guard !DEBUG_MACOS10, #available(macOS 11.0, *) else {
        super.drawKnob(knobRect)
        return
      }
      // This is intentionally empty as the knob is inside the bar. Please leave it like this!
    }

    override func drawBar(inside aRect: NSRect, flipped: Bool) {
      guard !DEBUG_MACOS10, #available(macOS 11.0, *) else {
        super.drawBar(inside: aRect, flipped: flipped)
        return
      }
      // Normalize raw slider values to 0-1 drawing space so XDR sliders (maxValue > 1) render correctly
      let sliderMax = Float(self.maxValue)
      var maxNorm = self.floatValue / sliderMax
      var minNorm = self.floatValue / sliderMax

      if self.isHighlightDisplayItems {
        maxNorm = max((self.displayHighlightItems.values.max() ?? 0) / sliderMax, maxNorm)
        minNorm = min((self.displayHighlightItems.values.min() ?? sliderMax) / sliderMax, minNorm)
      }

      let barRadius = aRect.height * 0.5 * (self.numOfTickmarks == 0 ? 1 : self.tickMarkKnobExtraRadiusMultiplier)
      let bar = NSBezierPath(roundedRect: aRect, xRadius: barRadius, yRadius: barRadius)
      self.barFillColor.setFill()
      bar.fill()

      let barFilledWidth = (aRect.width - aRect.height) * CGFloat(maxNorm) + aRect.height
      let barFilledRect = NSRect(x: aRect.origin.x, y: aRect.origin.y, width: barFilledWidth, height: aRect.height)
      let barFilled = NSBezierPath(roundedRect: barFilledRect, xRadius: barRadius, yRadius: barRadius)
      self.barFilledFillColor.setFill()
      barFilled.fill()

      // Extended brightness zone. Everything above the standard maximum (1.0) is drawn as a
      // yellow → orange → red ramp, so the fill itself tells the user they have left normal
      // brightness. The gradient is anchored to the value scale (1.0 → panel maximum)
      // rather than to the filled width, so a given brightness always reads the same
      // colour, and it is clipped to the filled area so it only shows once the user
      // actually pushes past the threshold.
      if self.isXDRSlider, sliderMax > 1.0 {
        let xdrThresholdNorm = 1.0 / sliderMax
        let thresholdX = aRect.origin.x + (aRect.width - aRect.height) * CGFloat(xdrThresholdNorm)
        if maxNorm > xdrThresholdNorm {
          NSGraphicsContext.saveGraphicsState()
          barFilled.addClip()
          let xdrRect = NSRect(x: thresholdX, y: aRect.origin.y - 1,
                               width: max(1, aRect.maxX - thresholdX), height: aRect.height + 2)
          if let gradient = NSGradient(colors: [self.barXDRStartColor, self.barXDRMidColor, self.barXDREndColor]) {
            gradient.draw(in: xdrRect, angle: 0)
          }
          NSGraphicsContext.restoreGraphicsState()
        }
        // Marks where standard brightness ends and extended brightness begins.
        self.xdrThresholdMarkerColor.setFill()
        NSBezierPath(rect: NSRect(x: thresholdX, y: aRect.origin.y, width: 1, height: aRect.height)).fill()
      }

      let knobMinX = aRect.origin.x + (aRect.width - aRect.height) * CGFloat(minNorm)
      let knobMaxX = aRect.origin.x + (aRect.width - aRect.height) * CGFloat(maxNorm)
      let knobRect = NSRect(x: knobMinX + (self.numOfTickmarks == 0 ? CGFloat(0) : self.tickMarkKnobExtraInset), y: aRect.origin.y, width: aRect.height + CGFloat(knobMaxX - knobMinX), height: aRect.height).insetBy(dx: self.numOfTickmarks == 0 ? CGFloat(0) : self.tickMarkKnobExtraInset, dy: 0)
      let knobRadius = knobRect.height * 0.5 * (self.numOfTickmarks == 0 ? 1 : self.tickMarkKnobExtraRadiusMultiplier)

      if self.numOfTickmarks > 0 {
        for i in 1 ... self.numOfTickmarks - 2 {
          let currentMarkLocation = CGFloat((Float(1) / Float(self.numOfTickmarks - 1)) * Float(i))
          let tickMarkBounds = NSRect(x: aRect.origin.x + aRect.height + self.tickMarkKnobExtraInset - knobRect.height + self.tickMarkKnobExtraInset * 2 + CGFloat(Float((aRect.width - self.tickMarkKnobExtraInset * 5) * currentMarkLocation)), y: aRect.origin.y + aRect.height * (1 / 3), width: 4, height: aRect.height / 3)
          let tickmark = NSBezierPath(roundedRect: tickMarkBounds, xRadius: 1, yRadius: 1)
          self.tickMarkColor.setFill()
          tickmark.fill()
        }
      }

      let knobAlpha = CGFloat(max(0, min(1, (minNorm - 0.08) * 5)))
      for i in 1 ... 3 {
        let knobShadow = NSBezierPath(roundedRect: knobRect.offsetBy(dx: CGFloat(-1 * 2 * i), dy: 0), xRadius: knobRadius, yRadius: knobRadius)
        self.knobShadowColor.withAlphaComponent(self.knobShadowColor.alphaComponent * knobAlpha).setFill()
        knobShadow.fill()
      }

      let knob = NSBezierPath(roundedRect: knobRect, xRadius: knobRadius, yRadius: knobRadius)
      (self.isTracking ? self.knobFillColorTracking : self.knobFillColor).withAlphaComponent(knobAlpha).setFill()
      knob.fill()

      if self.isHighlightDisplayItems, self.displayHighlightItems.count > 2 {
        for currentMarkLocationRaw in self.displayHighlightItems.values {
          let currentMarkLocation = currentMarkLocationRaw / sliderMax
          let highlightKnobX = aRect.origin.x + (aRect.width - aRect.height) * CGFloat(currentMarkLocation)
          let highlightKnobRect = NSRect(x: highlightKnobX + (self.numOfTickmarks == 0 ? CGFloat(0) : self.tickMarkKnobExtraInset), y: aRect.origin.y, width: aRect.height, height: aRect.height).insetBy(dx: (self.numOfTickmarks == 0 ? CGFloat(0) : self.tickMarkKnobExtraInset) + CGFloat(self.numOfTickmarks == 0 ? 6 : 3), dy: CGFloat(self.numOfTickmarks == 0 ? 6 : 6))
          let highlightKnobRadius = highlightKnobRect.height * 0.5 * (self.numOfTickmarks == 0 ? 1 : self.tickMarkKnobExtraRadiusMultiplier)
          let highlightKnob = NSBezierPath(roundedRect: highlightKnobRect, xRadius: highlightKnobRadius, yRadius: highlightKnobRadius)
          let highlightDisplayIndicatorAlpha = CGFloat(max(0, min(1, (currentMarkLocation - 0.08) * 5)))
          self.highlightDisplayIndicatorColor.withAlphaComponent(self.highlightDisplayIndicatorColor.alphaComponent * highlightDisplayIndicatorAlpha).setFill()
          highlightKnob.fill()
        }
      }

      self.knobStrokeColor.withAlphaComponent(self.knobStrokeColor.alphaComponent * knobAlpha).setStroke()
      knob.stroke()
      self.barStrokeColor.setStroke()
      bar.stroke()
    }
  }

  class MCSlider: NSSlider {
    required init?(coder: NSCoder) {
      super.init(coder: coder)
    }

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      self.cell = MCSliderCell()
    }

    func setNumOfCustomTickmarks(_ numOfCustomTickmarks: Int) {
      if let cell = self.cell as? MCSliderCell {
        cell.numOfTickmarks = numOfCustomTickmarks
      }
    }

    func setDisplayHighlightItems(_ isHighlightDisplayItems: Bool) {
      if let cell = self.cell as? MCSliderCell {
        cell.isHighlightDisplayItems = isHighlightDisplayItems
      }
    }

    func setHighlightItem(_ displayID: CGDirectDisplayID, value: Float) {
      if let cell = self.cell as? MCSliderCell {
        cell.displayHighlightItems[displayID] = value
      }
    }

    func removeHighlightItem(_ displayID: CGDirectDisplayID) {
      if let cell = self.cell as? MCSliderCell {
        if cell.displayHighlightItems[displayID] != nil {
          cell.displayHighlightItems[displayID] = nil
        }
      }
    }

    func resetHighlightItems() {
      if let cell = self.cell as? MCSliderCell {
        cell.displayHighlightItems.removeAll()
      }
    }

    //  Credits for this class go to @thompsonate - https://github.com/thompsonate/Scrollable-NSSlider
    override func scrollWheel(with event: NSEvent) {
      guard self.isEnabled else { return }
      let range = Float(self.maxValue - self.minValue)
      var delta = Float(0)
      if self.isVertical, self.sliderType == .linear {
        delta = Float(event.deltaY)
      } else if self.userInterfaceLayoutDirection == .rightToLeft {
        delta = Float(event.deltaY + event.deltaX)
      } else {
        delta = Float(event.deltaY - event.deltaX)
      }
      if event.isDirectionInvertedFromDevice {
        delta *= -1
      }
      let increment = range * delta / 100
      let value = self.floatValue + increment
      self.floatValue = value
      self.sendAction(self.action, to: self.target)
    }
  }

  class ClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
      subviews.first { subview in subview.hitTest(point) != nil
      }
    }
  }

  init(display: Display?, command: Command, title: String = "", position _: Int = 0) {
    self.command = command
    self.title = title
    let slider = SliderHandler.MCSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(SliderHandler.valueChanged))
    let showPercent = prefs.bool(forKey: PrefKey.enableSliderPercent.rawValue)
    slider.isEnabled = true
    slider.setNumOfCustomTickmarks(prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? 5 : 0)
    self.slider = slider
    // Offer the XDR opt-in when the drag ends rather than mid-drag: running a modal alert
    // from inside the slider's action fights the menu's event loop. The hop to the next
    // main-queue turn also keeps it out of AppKit's tracking teardown.
    (slider.cell as? MCSliderCell)?.onTrackingEnded = { [weak self] in
      DispatchQueue.main.async {
        self?.handleSliderTrackingEnded()
      }
    }
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      // Everything here is derived from MenuMetrics so the row is symmetric and lines up
      // with the display card and the settings/quit row. The row's origin is deliberately
      // left at (0, 0): the container positions it.
      slider.frame = NSRect(x: MenuMetrics.controlInset,
                            y: (MenuMetrics.rowHeight - MenuMetrics.sliderHeight) / 2,
                            width: MenuMetrics.sliderWidth,
                            height: MenuMetrics.sliderHeight)
      let view = NSView(frame: NSRect(x: 0, y: 0,
                                      width: MenuMetrics.rowWidth(showPercent: showPercent),
                                      height: MenuMetrics.rowHeight))
      var iconName = "circle.dashed"
      switch command {
      case .audioSpeakerVolume: iconName = "speaker.wave.2.fill"
      case .brightness: iconName = "sun.max.fill"
      case .contrast: iconName = "circle.lefthalf.fill"
      default: break
      }
      let icon = SliderHandler.ClickThroughImageView()
      icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)
      // Dynamic tint: a fixed black tint is invisible on a dark or glassy menu.
      icon.contentTintColor = NSColor.secondaryLabelColor
      // Centred in the gutter and to the left of the slider. This used to be placed with
      // `view.frame.origin.x + 6.5`, which resolved to x 18.5 and landed on top of a
      // slider starting at x 15.
      icon.frame = NSRect(x: MenuMetrics.iconGutter,
                          y: (MenuMetrics.rowHeight - MenuMetrics.iconSize) / 2,
                          width: MenuMetrics.iconSize,
                          height: MenuMetrics.iconSize)
      icon.imageAlignment = .alignCenter
      view.addSubview(slider)
      view.addSubview(icon)
      self.icon = icon
      if showPercent {
        let percentageBox = NSTextField(frame: NSRect(x: MenuMetrics.controlInset + MenuMetrics.sliderWidth + MenuMetrics.percentGap,
                                                      y: (MenuMetrics.rowHeight - 12) / 2,
                                                      width: MenuMetrics.percentWidth,
                                                      height: 12))
        self.setupPercentageBox(percentageBox)
        self.percentageBox = percentageBox
        view.addSubview(percentageBox)
      }
      self.view = view
    } else {
      slider.frame.size.width = 180
      slider.frame.origin = NSPoint(x: 15, y: 5)
      let view = NSView(frame: NSRect(x: 0, y: 0, width: slider.frame.width + 30 + (showPercent ? 38 : 0), height: slider.frame.height + 10))
      view.addSubview(slider)
      if showPercent {
        let percentageBox = NSTextField(frame: NSRect(x: 15 + slider.frame.size.width - 2, y: 18, width: 40, height: 12))
        self.setupPercentageBox(percentageBox)
        self.percentageBox = percentageBox
        view.addSubview(percentageBox)
      }
      self.view = view
    }
    slider.maxValue = 1
    if let displayToAppend = display {
      self.addDisplay(displayToAppend)
    }
  }

  // Recomputes the slider range from all displays it controls. XDR extended brightness
  // (brightnessMaxValue > 1) applies if any member display has it enabled.
  func updateSliderXDRRange() {
    guard self.command == .brightness, let slider = self.slider else {
      return
    }
    let maxRange = self.displays.map { $0.brightnessMaxValue }.max() ?? 1.0
    slider.maxValue = Double(max(maxRange, 1.0))
    if let cell = slider.cell as? MCSliderCell {
      cell.isXDRSlider = maxRange > 1.0
    }
  }

  func addDisplay(_ display: Display) {
    self.displays.append(display)
    self.updateSliderXDRRange()
    if let otherDisplay = display as? OtherDisplay {
      let value = otherDisplay.setupSliderCurrentValue(command: self.command)
      self.setValue(value, displayID: otherDisplay.identifier)
    } else if let appleDisplay = display as? AppleDisplay {
      if self.command == .brightness {
        // Effective, not raw: with a boost applied the raw reading is pinned at 1.0 and
        // would park the thumb at the 100% mark of the extended range.
        self.setValue(appleDisplay.effectiveBrightness, displayID: appleDisplay.identifier)
      }
    }
  }

  func setupPercentageBox(_ percentageBox: NSTextField) {
    percentageBox.font = NSFont.systemFont(ofSize: 12)
    percentageBox.isEditable = false
    percentageBox.isBordered = false
    percentageBox.drawsBackground = false
    percentageBox.alignment = .right
    percentageBox.alphaValue = 0.7
  }

  func valueChangedOtherDisplay(otherDisplay: OtherDisplay, value: Float) {
    // For the speaker volume slider, also set/unset the mute command when the value is changed from/to 0
    if self.command == .audioSpeakerVolume, (otherDisplay.readPrefAsInt(for: .audioMuteScreenBlank) == 1 && value > 0) || (otherDisplay.readPrefAsInt(for: .audioMuteScreenBlank) != 1 && value == 0) {
      otherDisplay.toggleMute(fromVolumeSlider: true)
    }
    if self.command == Command.brightness {
      _ = otherDisplay.setBrightness(value)
      return
    } else if !otherDisplay.isSw() {
      if self.command == Command.audioSpeakerVolume {
        if !otherDisplay.readPrefAsBool(key: .enableMuteUnmute) || value != 0 {
          otherDisplay.writeDDCValues(command: self.command, value: otherDisplay.convValueToDDC(for: self.command, from: value))
        }
      } else {
        otherDisplay.writeDDCValues(command: self.command, value: otherDisplay.convValueToDDC(for: self.command, from: value))
      }
      otherDisplay.savePref(value, for: self.command)
    }
  }

  @objc func valueChanged(slider: MCSlider) {
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    var value = slider.floatValue
    self.updateIcon()
    if prefs.bool(forKey: PrefKey.enableSliderSnap.rawValue) {
      let intPercent = Int(value * 100)
      let snapInterval = 25
      let snapThreshold = 3
      let closest = (intPercent + snapInterval / 2) / snapInterval * snapInterval
      if abs(closest - intPercent) <= snapThreshold {
        value = Float(closest) / 100
        slider.floatValue = value
      }
    }
    self.percentageBox?.stringValue = String(Int(value * 100)) + "%"
    for display in self.displays {
      slider.setHighlightItem(display.identifier, value: value)
      if self.command == .brightness, let appleDisplay = display as? AppleDisplay {
        // setBrightness clamps to the display's own maximum, so a value beyond the current
        // range is safely reduced instead of being rejected.
        _ = appleDisplay.setBrightness(value)
      } else if let otherDisplay = display as? OtherDisplay {
        self.valueChangedOtherDisplay(otherDisplay: otherDisplay, value: value)
      }
    }
    slider.setDisplayHighlightItems(false)
  }

  /// Runs once the user lets go of the slider.
  ///
  /// This is where the XDR opt-in is offered. It used to be offered from inside
  /// `valueChanged`, which meant a modal alert was presented while the slider was still
  /// tracking and the menu's event loop was unwinding.
  private func handleSliderTrackingEnded() {
    guard self.command == .brightness, let slider = self.slider else {
      return
    }
    let value = slider.floatValue
    for display in self.displays {
      guard let appleDisplay = display as? AppleDisplay else {
        continue
      }
      // Only relevant when the user actually pushed up to the ceiling.
      guard value >= appleDisplay.brightnessMaxValue - 0.001 else {
        continue
      }
      guard appleDisplay.canOfferXDR else {
        continue
      }
      if appleDisplay.promptToEnableXDR() {
        self.updateSliderXDRRange()
      } else {
        // XDR stays off for this display: bring the slider back down to its real maximum.
        let appliedValue = min(value, appleDisplay.brightnessMaxValue)
        slider.floatValue = appliedValue
        slider.setHighlightItem(display.identifier, value: appliedValue)
      }
      return
    }
  }

  func updateIcon() {
    // This looks hideous so I disable it for now. Maybe after a bit of tinkering it will look better
    /*
     if self.command == .audioSpeakerVolume {
       let value = self.slider?.floatValue ?? 0.5
       if value > 2/3 {
         self.icon?.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "")
       } else if value > 1/3 {
         self.icon?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "")
       } else if value != 0 {
         self.icon?.image = NSImage(systemSymbolName: "speaker.wave.1.fill", accessibilityDescription: "")
       } else {
         self.icon?.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "")
       }
     }
     */
  }

  func setValue(_ value: Float, displayID: CGDirectDisplayID = 0) {
    if let slider = self.slider {
      if displayID != 0 {
        self.values[displayID] = value
        slider.setHighlightItem(displayID, value: value)
      }
      var maxVal: Float = 0
      var minVal: Float = .greatestFiniteMagnitude
      var num = 0
      for key in self.values.keys {
        if let val = values[key] {
          maxVal = max(maxVal, val)
          minVal = min(minVal, val)
          num += 1
        }
      }
      let clampedValue = min(value, Float(slider.maxValue))
      slider.floatValue = clampedValue
      self.updateIcon()
      if num > 1, abs(maxVal - minVal) > 0.001 {
        slider.setDisplayHighlightItems(true)
      } else {
        slider.setDisplayHighlightItems(false)
      }
      self.percentageBox?.stringValue = "\(String(format: "%.0f%%", Double(clampedValue) * 100))"
    }
  }
}
