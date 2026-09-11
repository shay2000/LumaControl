//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AppKit
import os.log

class MenuHandler: NSMenu, NSMenuDelegate {
  var combinedSliderHandler: [Command: SliderHandler] = [:]

  var lastMenuRelevantDisplayId: CGDirectDisplayID = 0

  func clearMenu() {
    var items: [NSMenuItem] = []
    for i in 0 ..< self.items.count {
      items.append(self.items[i])
    }
    for item in items {
      self.removeItem(item)
    }
    self.combinedSliderHandler.removeAll()
  }

  func menuWillOpen(_: NSMenu) {
    self.updateMenuRelevantDisplay()
    app.keyboardShortcuts.disengage()
  }

  func closeMenu() {
    self.cancelTrackingWithoutAnimation()
  }

  func updateMenus(dontClose: Bool = false) {
    os_log("Menu update initiated", type: .info)
    if !dontClose {
      self.cancelTrackingWithoutAnimation()
    }
    let menuIconPref = prefs.integer(forKey: PrefKey.menuIcon.rawValue)
    var showIcon = false
    if menuIconPref == MenuIcon.show.rawValue {
      showIcon = true
    } else if menuIconPref == MenuIcon.externalOnly.rawValue {
      let externalDisplays = DisplayManager.shared.displays.filter {
        CGDisplayIsBuiltin($0.identifier) == 0
      }
      if externalDisplays.count > 0 {
        showIcon = true
      }
    }
    app.updateStatusItemVisibility(showIcon)
    self.clearMenu()
    let currentDisplay = DisplayManager.shared.getCurrentDisplay()
    var displays: [Display] = []
    if !prefs.bool(forKey: PrefKey.hideAppleFromMenu.rawValue) {
      displays.append(contentsOf: DisplayManager.shared.getAppleDisplays())
    }
    displays.append(contentsOf: DisplayManager.shared.getOtherDisplays())
    // Sort the list built above, not the manager's full list. Sorting the full list used
    // to silently discard the hideAppleFromMenu filter applied two lines earlier.
    displays = DisplayManager.shared.sortDisplaysByFriendlyName(displays)
    var relevant = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.relevant.rawValue
    let combine = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue
    let numOfDisplays = displays.filter { !$0.isDummy }.count
    // "Relevant display only" needs a display under the pointer. When there is not one —
    // a stale mouse location, or a reconfiguration in flight — fall back to showing every
    // display rather than force-unwrapping nil and trapping.
    var relevantDisplayID: CGDirectDisplayID?
    if relevant {
      if let currentDisplay = currentDisplay {
        relevantDisplayID = DisplayManager.resolveEffectiveDisplayID(currentDisplay.identifier)
      } else {
        os_log("No display under the pointer for relevant-display mode, showing all displays.", type: .info)
        relevant = false
      }
    }
    if numOfDisplays != 0 {
      let asSubMenu: Bool = (displays.count > 3 && !relevant && !combine && app.macOS10()) ? true : false
      var iterator = 0
      for display in displays where (!relevant || DisplayManager.resolveEffectiveDisplayID(display.identifier) == relevantDisplayID) && !display.isDummy {
        iterator += 1
        if !relevant, !combine, iterator != 1, app.macOS10() {
          self.insertItem(NSMenuItem.separator(), at: 0)
        }
        self.updateDisplayMenu(display: display, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
      }
      if combine {
        self.addCombinedDisplayMenuBlock()
      }
    }
    self.addDefaultMenuOptions()
  }

  func addSliderItem(monitorSubMenu: NSMenu, sliderHandler: SliderHandler) {
    let item = NSMenuItem()
    item.view = sliderHandler.view
    monitorSubMenu.insertItem(item, at: 0)
    if app.macOS10() {
      let sliderHeaderItem = NSMenuItem()
      let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 12)]
      sliderHeaderItem.attributedTitle = NSAttributedString(string: sliderHandler.title, attributes: attrs)
      monitorSubMenu.insertItem(sliderHeaderItem, at: 0)
    }
  }

  func setupMenuSliderHandler(command: Command, display: Display, title: String) -> SliderHandler {
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue, let combinedHandler = self.combinedSliderHandler[command] {
      combinedHandler.addDisplay(display)
      display.sliderHandler[command] = combinedHandler
      return combinedHandler
    } else {
      let sliderHandler = SliderHandler(display: display, command: command, title: title)
      if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue {
        self.combinedSliderHandler[command] = sliderHandler
      }
      display.sliderHandler[command] = sliderHandler
      return sliderHandler
    }
  }

  func addDisplayMenuBlock(addedSliderHandlers: [SliderHandler], blockName: String, monitorSubMenu: NSMenu, numOfDisplays: Int, asSubMenu: Bool) {
    if numOfDisplays > 1, prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.relevant.rawValue, !DEBUG_MACOS10, #available(macOS 11.0, *) {
      class BlockView: NSView {
        override func draw(_: NSRect) {
          // The card is inset symmetrically from the item view, so the row views placed
          // below can never straddle its border.
          let blockRect = self.bounds.insetBy(dx: MenuMetrics.outerMargin, dy: MenuMetrics.outerMargin)
          let radius: CGFloat = 10
          for i in 1 ... 5 {
            let blockPath = NSBezierPath(roundedRect: blockRect.insetBy(dx: CGFloat(i) * -1, dy: CGFloat(i) * -1), xRadius: radius + CGFloat(i) * 0.5, yRadius: radius + CGFloat(i) * 0.5)
            NSColor.black.withAlphaComponent(0.1 / CGFloat(i)).setStroke()
            blockPath.stroke()
          }
          let blockPath = NSBezierPath(roundedRect: blockRect, xRadius: radius, yRadius: radius)
          let isDarkAppearance = [NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark].contains(effectiveAppearance.name)
          if #available(macOS 26.0, *) {
            // Liquid Glass: the menu itself supplies the glassy background, so keep the
            // block to a subtle border instead of an opaque card on top of the glass.
            NSColor.systemGray.withAlphaComponent(0.3).setStroke()
            blockPath.stroke()
          } else if isDarkAppearance {
            NSColor.systemGray.withAlphaComponent(0.3).setStroke()
            blockPath.stroke()
          } else {
            NSColor.white.withAlphaComponent(0.5).setFill()
            blockPath.fill()
          }
        }
      }

      let showPercent = prefs.bool(forKey: PrefKey.enableSliderPercent.rawValue)
      let rowWidth = MenuMetrics.rowWidth(showPercent: showPercent)
      let rowHeight = MenuMetrics.rowHeight
      let itemWidth = MenuMetrics.itemWidth(showPercent: showPercent)
      let contentX = MenuMetrics.outerMargin + MenuMetrics.cardPadding

      var blockNameView: NSTextField?
      var labelHeight: CGFloat = 0
      if blockName != "" {
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor, .font: NSFont.boldSystemFont(ofSize: 12)]
        blockNameView = NSTextField(labelWithAttributedString: NSAttributedString(string: blockName, attributes: attrs))
        // The label shares the icons' left edge, so it starts one icon gutter in and stops
        // at the content column's trailing edge.
        blockNameView?.frame.size.width = rowWidth - MenuMetrics.iconGutter
        blockNameView?.alphaValue = 0.5
        // Measure the label instead of assuming a fixed 21 pt: a longer localised display
        // name or a larger accessibility text size would otherwise collide with it.
        labelHeight = blockNameView?.fittingSize.height ?? 0
      }

      let rowCount = CGFloat(addedSliderHandlers.count)
      let cardHeight = MenuMetrics.cardPadding * 2
        + (labelHeight > 0 ? labelHeight + MenuMetrics.labelGap : 0)
        + rowCount * rowHeight
      let itemView = BlockView(frame: NSRect(x: 0, y: 0,
                                             width: itemWidth,
                                             height: cardHeight + MenuMetrics.outerMargin * 2))

      // Lay the card's content out downwards from its top edge, so the padding above the
      // label and below the last slider come out equal by construction rather than by
      // hand-tuned offsets.
      var cursor = itemView.frame.height - MenuMetrics.outerMargin - MenuMetrics.cardPadding
      if let blockNameView = blockNameView, labelHeight > 0 {
        cursor -= labelHeight
        blockNameView.setFrameOrigin(NSPoint(x: contentX + MenuMetrics.iconGutter, y: cursor))
        itemView.addSubview(blockNameView)
        cursor -= MenuMetrics.labelGap
      }
      for addedSliderHandler in addedSliderHandlers {
        cursor -= rowHeight
        addedSliderHandler.view!.frame = NSRect(x: contentX, y: cursor, width: rowWidth, height: rowHeight)
        itemView.addSubview(addedSliderHandler.view!)
      }

      let item = NSMenuItem()
      item.view = itemView
      if addedSliderHandlers.count != 0 {
        monitorSubMenu.insertItem(item, at: 0)
      }
    } else {
      for addedSliderHandler in addedSliderHandlers {
        self.addSliderItem(monitorSubMenu: monitorSubMenu, sliderHandler: addedSliderHandler)
      }
    }
    self.appendMenuHeader(friendlyName: blockName, monitorSubMenu: monitorSubMenu, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
  }

  func addCombinedDisplayMenuBlock() {
    if let sliderHandler = self.combinedSliderHandler[.audioSpeakerVolume] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.contrast] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.brightness] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
  }

  func updateDisplayMenu(display: Display, asSubMenu: Bool, numOfDisplays: Int) {
    os_log("Addig menu items for display %{public}@", type: .info, "\(display.identifier)")
    let monitorSubMenu: NSMenu = asSubMenu ? NSMenu() : self
    var addedSliderHandlers: [SliderHandler] = []
    display.sliderHandler[.audioSpeakerVolume] = nil
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume), !prefs.bool(forKey: PrefKey.hideVolume.rawValue) {
      let title = NSLocalizedString("Volume", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .audioSpeakerVolume, display: display, title: title))
    }
    display.sliderHandler[.contrast] = nil
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .contrast), prefs.bool(forKey: PrefKey.showContrast.rawValue) {
      let title = NSLocalizedString("Contrast", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .contrast, display: display, title: title))
    }
    display.sliderHandler[.brightness] = nil
    if !display.readPrefAsBool(key: .unavailableDDC, for: .brightness), !prefs.bool(forKey: PrefKey.hideBrightness.rawValue) {
      let title = NSLocalizedString("Brightness", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .brightness, display: display, title: title))
    }
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.combine.rawValue {
      // Only offered on panels that actually have a range above SDR white to unlock. On
      // anything else the item would do nothing but explain itself.
      if let appleDisplay = display as? AppleDisplay, appleDisplay.isXDRCapable, !appleDisplay.isVirtual, !appleDisplay.isDummy {
        if appleDisplay.readPrefAsBool(key: .xdrEnabled) {
          let disableItem = NSMenuItem(title: NSLocalizedString("Disable XDR Extended Brightness", comment: "Shown in menu"), action: #selector(MenuHandler.xdrDisableBrightness(_:)), keyEquivalent: "")
          disableItem.representedObject = appleDisplay
          disableItem.target = self
          monitorSubMenu.insertItem(disableItem, at: 0)
          let resetItem = NSMenuItem(title: NSLocalizedString("Reset to Standard Brightness", comment: "Shown in menu"), action: #selector(MenuHandler.xdrResetBrightness(_:)), keyEquivalent: "")
          resetItem.representedObject = appleDisplay
          resetItem.target = self
          monitorSubMenu.insertItem(resetItem, at: 0)
        } else {
          // Offered even before the panel has been probed, so there is always a
          // discoverable way in. Previously the only route was dragging the brightness
          // slider to 100%, which keyboard-only users could never do, and the menu items
          // only appeared once XDR was already on.
          let enableItem = NSMenuItem(title: NSLocalizedString("Enable XDR Extended Brightness…", comment: "Shown in menu"), action: #selector(MenuHandler.xdrEnableBrightness(_:)), keyEquivalent: "")
          enableItem.representedObject = appleDisplay
          enableItem.target = self
          monitorSubMenu.insertItem(enableItem, at: 0)
        }
      }
      self.addDisplayMenuBlock(addedSliderHandlers: addedSliderHandlers, blockName: display.readPrefAsString(key: .friendlyName) != "" ? display.readPrefAsString(key: .friendlyName) : display.name, monitorSubMenu: monitorSubMenu, numOfDisplays: numOfDisplays, asSubMenu: asSubMenu)
    }
    if addedSliderHandlers.count > 0, prefs.integer(forKey: PrefKey.menuIcon.rawValue) == MenuIcon.sliderOnly.rawValue {
      app.updateStatusItemVisibility(true)
    }
  }

  private func appendMenuHeader(friendlyName: String, monitorSubMenu: NSMenu, asSubMenu: Bool, numOfDisplays: Int) {
    let monitorMenuItem = NSMenuItem()
    if asSubMenu {
      monitorMenuItem.title = "\(friendlyName)"
      monitorMenuItem.submenu = monitorSubMenu
      self.insertItem(monitorMenuItem, at: 0)
    } else if app.macOS10(), numOfDisplays > 1 {
      let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.boldSystemFont(ofSize: 12)]
      monitorMenuItem.attributedTitle = NSAttributedString(string: "\(friendlyName)", attributes: attrs)
      self.insertItem(monitorMenuItem, at: 0)
    }
  }

  @objc func xdrResetBrightness(_ sender: NSMenuItem) {
    guard let appleDisplay = sender.representedObject as? AppleDisplay else { return }
    appleDisplay.resetToNormalBrightness()
  }

  @objc func xdrDisableBrightness(_ sender: NSMenuItem) {
    guard let appleDisplay = sender.representedObject as? AppleDisplay else { return }
    appleDisplay.disableXDR()
  }

  @objc func xdrEnableBrightness(_ sender: NSMenuItem) {
    guard let appleDisplay = sender.representedObject as? AppleDisplay else { return }
    // Deferred: a menu item action runs while the menu is still unwinding, and this ends
    // up presenting a modal alert.
    DispatchQueue.main.async {
      if appleDisplay.canOfferXDR {
        if appleDisplay.promptToEnableXDR(force: true) {
          appleDisplay.sliderHandler[.brightness]?.updateSliderXDRRange()
        }
      } else if !appleDisplay.readPrefAsBool(key: .xdrEnabled) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Extended brightness is not available", comment: "Shown in the alert dialog")
        alert.informativeText = NSLocalizedString("This display has no brightness range above the standard maximum, so XDR extended brightness cannot be enabled on it.", comment: "Shown in the alert dialog")
        alert.alertStyle = .informational
        alert.runModal()
      }
    }
  }

  func updateMenuRelevantDisplay() {
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.relevant.rawValue {
      if let display = DisplayManager.shared.getCurrentDisplay(), display.identifier != self.lastMenuRelevantDisplayId {
        os_log("Menu must be refreshed as relevant display changed since last time.")
        self.lastMenuRelevantDisplayId = display.identifier
        self.updateMenus(dontClose: true)
      }
    }
  }

  func addDefaultMenuOptions() {
    if !DEBUG_MACOS10, #available(macOS 11.0, *), prefs.integer(forKey: PrefKey.menuItemStyle.rawValue) == MenuItemStyle.icon.rawValue {
      let iconSize = CGFloat(18)
      // Derive the width from the item views we just added rather than from `self.size`.
      // This method runs at launch, on display changes and on XDR toggles — almost always
      // while the menu is closed — and NSMenu.size is then zero or stale. The old
      // `max(130, self.size.width)` therefore produced a 130 pt view while the real
      // content is 248-274 pt wide, which put these buttons in the middle of the menu, on
      // top of the sliders (and on top of the gear button's own hit area, so reaching for
      // a slider hit the gear instead).
      let showPercent = prefs.bool(forKey: PrefKey.enableSliderPercent.rawValue)
      let contentWidth = self.items.compactMap { $0.view?.frame.width }.max() ?? 0
      let viewWidth = max(contentWidth, MenuMetrics.itemWidth(showPercent: showPercent))
      let buttonGap: CGFloat = 14

      let menuItemView = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: iconSize + 12))
      let buttonY = (menuItemView.frame.height - iconSize) / 2
      // Line the buttons up with the trailing edge of the card (or of the slider row when
      // no card is drawn). MenuMetrics.outerMargin is that inset in both cases.
      let quitX = viewWidth - MenuMetrics.outerMargin - iconSize
      let settingsX = quitX - buttonGap - iconSize

      let settingsIcon = NSButton()
      settingsIcon.bezelStyle = .regularSquare
      settingsIcon.isBordered = false
      settingsIcon.setButtonType(.momentaryChange)
      settingsIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: NSLocalizedString("Settings…", comment: "Shown in menu"))
      settingsIcon.alternateImage = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: NSLocalizedString("Settings…", comment: "Shown in menu"))
      settingsIcon.alphaValue = 0.3
      settingsIcon.frame = NSRect(x: settingsX, y: buttonY, width: iconSize, height: iconSize)
      settingsIcon.imageScaling = .scaleProportionallyUpOrDown
      settingsIcon.action = #selector(app.prefsClicked)

      let quitIcon = NSButton()
      quitIcon.bezelStyle = .regularSquare
      quitIcon.isBordered = false
      quitIcon.setButtonType(.momentaryChange)
      let symbolName = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? "multiply.square" : "xmark.circle"
      quitIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: NSLocalizedString("Quit", comment: "Shown in menu"))
      quitIcon.alternateImage = NSImage(systemSymbolName: symbolName + ".fill", accessibilityDescription: NSLocalizedString("Quit", comment: "Shown in menu"))
      quitIcon.alphaValue = 0.3
      quitIcon.frame = NSRect(x: quitX, y: buttonY, width: iconSize, height: iconSize)
      quitIcon.imageScaling = .scaleProportionallyUpOrDown
      quitIcon.action = #selector(app.quitClicked)

      menuItemView.addSubview(settingsIcon)
      menuItemView.addSubview(quitIcon)
      let item = NSMenuItem()
      item.view = menuItemView
      self.insertItem(item, at: self.items.count)
    } else if prefs.integer(forKey: PrefKey.menuItemStyle.rawValue) != MenuItemStyle.hide.rawValue {
      if app.macOS10() {
        self.insertItem(NSMenuItem.separator(), at: self.items.count)
      }
      self.insertItem(withTitle: NSLocalizedString("Settings…", comment: "Shown in menu"), action: #selector(app.prefsClicked), keyEquivalent: ",", at: self.items.count)
      self.insertItem(withTitle: NSLocalizedString("Quit", comment: "Shown in menu"), action: #selector(app.quitClicked), keyEquivalent: "q", at: self.items.count)
    }
  }
}
