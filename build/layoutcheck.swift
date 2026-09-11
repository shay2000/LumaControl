// Verification: recomputes the popout layout using the new MenuMetrics values and
// asserts that the four defects found earlier are gone.
//
// Mirrors MenuMetrics in MonitorControl/Support/SliderHandler.swift and the placement
// code in MenuHandler.addDisplayMenuBlock / addDefaultMenuOptions.
//
// Build: swiftc -O -o /tmp/layoutcheck layoutcheck.swift
// Run:   /tmp/layoutcheck

import AppKit

enum M {
  static let outerMargin: CGFloat = 6
  static let cardPadding: CGFloat = 10
  static let iconGutter: CGFloat = 6
  static let iconSize: CGFloat = 16
  static let iconToControl: CGFloat = 8
  static let sliderHeight: CGFloat = 16
  static let rowPadding: CGFloat = 7
  static let labelGap: CGFloat = 8
  static let sliderWidth: CGFloat = 180
  static let percentWidth: CGFloat = 34
  static let percentGap: CGFloat = 6
  static var controlInset: CGFloat { iconGutter + iconSize + iconToControl }
  static var rowHeight: CGFloat { sliderHeight + rowPadding * 2 }
  static func rowWidth(showPercent: Bool) -> CGFloat {
    controlInset + sliderWidth + (showPercent ? percentGap + percentWidth : 0) + iconGutter
  }
  static func cardWidth(showPercent: Bool) -> CGFloat { rowWidth(showPercent: showPercent) + cardPadding * 2 }
  static func itemWidth(showPercent: Bool) -> CGFloat { cardWidth(showPercent: showPercent) + outerMargin * 2 }
}

_ = NSApplication.shared

var failures: [String] = []
func check(_ label: String, _ condition: Bool, _ detail: String) {
  print("  \(condition ? "PASS" : "FAIL")  \(label) — \(detail)")
  if !condition { failures.append(label) }
}

for showPercent in [false, true] {
  print("=== layout with showPercent = \(showPercent) ===")
  let rowWidth = M.rowWidth(showPercent: showPercent)
  let cardWidth = M.cardWidth(showPercent: showPercent)
  let itemWidth = M.itemWidth(showPercent: showPercent)
  let contentX = M.outerMargin + M.cardPadding

  // Measure the real label the way MenuHandler does.
  let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor,
                                              .font: NSFont.boldSystemFont(ofSize: 12)]
  let label = NSTextField(labelWithAttributedString: NSAttributedString(string: "LG HDR 4K", attributes: attrs))
  label.frame.size.width = rowWidth - M.iconGutter
  let labelHeight = label.fittingSize.height

  let rowCount: CGFloat = 3 // worst case: volume + contrast + brightness
  let cardHeight = M.cardPadding * 2 + (labelHeight + M.labelGap) + rowCount * M.rowHeight
  let itemHeight = cardHeight + M.outerMargin * 2

  let card = NSRect(x: M.outerMargin, y: M.outerMargin, width: cardWidth, height: cardHeight)

  var cursor = itemHeight - M.outerMargin - M.cardPadding
  cursor -= labelHeight
  let labelRect = NSRect(x: contentX + M.iconGutter, y: cursor, width: rowWidth - M.iconGutter, height: labelHeight)
  cursor -= M.labelGap

  var rowRects: [NSRect] = []
  for _ in 0 ..< Int(rowCount) {
    cursor -= M.rowHeight
    rowRects.append(NSRect(x: contentX, y: cursor, width: rowWidth, height: M.rowHeight))
  }

  let iconLocal = NSRect(x: M.iconGutter, y: (M.rowHeight - M.iconSize) / 2, width: M.iconSize, height: M.iconSize)
  let sliderLocal = NSRect(x: M.controlInset, y: (M.rowHeight - M.sliderHeight) / 2, width: M.sliderWidth, height: M.sliderHeight)

  let firstRow = rowRects[0]
  let lastRow = rowRects[rowRects.count - 1]
  let iconAbs = iconLocal.offsetBy(dx: firstRow.minX, dy: firstRow.minY)
  let sliderAbs = sliderLocal.offsetBy(dx: firstRow.minX, dy: firstRow.minY)

  print(String(format: "  item %.0f x %.0f, card %.0f x %.0f at (%.0f, %.0f), label h %.0f",
               itemWidth, itemHeight, cardWidth, cardHeight, card.minX, card.minY, labelHeight))

  // 1. every row must sit inside the card with cardPadding to spare
  let leftClearance = firstRow.minX - card.minX
  let rightClearance = card.maxX - firstRow.maxX
  check("row inside card horizontally", leftClearance >= M.cardPadding - 0.01 && rightClearance >= M.cardPadding - 0.01,
        String(format: "left %.1f, right %.1f (want >= %.1f)", leftClearance, rightClearance, M.cardPadding))

  // 2. the icon must not straddle the card border (the old defect A)
  check("icon clear of card border", iconAbs.minX > card.minX,
        String(format: "icon x %.1f → %.1f vs card edge %.1f", iconAbs.minX, iconAbs.maxX, card.minX))

  // 3. label and icon share a left edge (the old defect B)
  check("label aligns with icons", abs(labelRect.minX - iconAbs.minX) < 0.01,
        String(format: "label x %.1f, icon x %.1f", labelRect.minX, iconAbs.minX))

  // 4. slider and icon are centred in their row (the old defect D)
  check("slider centred in row", abs(sliderAbs.midY - firstRow.midY) < 0.01,
        String(format: "slider midY %.1f, row midY %.1f", sliderAbs.midY, firstRow.midY))
  check("icon centred in row", abs(iconAbs.midY - firstRow.midY) < 0.01,
        String(format: "icon midY %.1f, row midY %.1f", iconAbs.midY, firstRow.midY))

  // 5. padding above the label equals padding below the last row
  let topPad = card.maxY - labelRect.maxY
  let bottomPad = lastRow.minY - card.minY
  check("vertical padding symmetric", abs(topPad - bottomPad) < 0.01,
        String(format: "top %.1f, bottom %.1f", topPad, bottomPad))

  // 6. the settings/quit buttons must end on the card's trailing edge (the old defect C)
  let buttonSize: CGFloat = 18
  let buttonGap: CGFloat = 14
  let buttonViewWidth = max(itemWidth, M.itemWidth(showPercent: showPercent))
  let quitX = buttonViewWidth - M.outerMargin - buttonSize
  let settingsX = quitX - buttonGap - buttonSize
  check("buttons end on card edge", abs((quitX + buttonSize) - card.maxX) < 0.01,
        String(format: "quit right %.1f, card right %.1f", quitX + buttonSize, card.maxX))
  check("buttons do not collide", settingsX + buttonSize < quitX,
        String(format: "settings %.1f → %.1f, quit %.1f → %.1f", settingsX, settingsX + buttonSize, quitX, quitX + buttonSize))

  // The buttons live in their own NSMenuItem, stacked below the card's item. Their vertical
  // positions therefore belong to a different coordinate space, and comparing them against
  // the card's rows directly — which this script used to do — reports a collision that
  // cannot happen on screen. Model the menu as the vertical stack it is instead: the card
  // item occupies y ∈ [0, itemHeight], the button item sits directly below it at
  // y ∈ [−buttonViewHeight, 0]. They share the boundary and never overlap.
  let buttonViewHeight = buttonSize + 12
  let buttonPadY = (buttonViewHeight - buttonSize) / 2
  let buttonItemTop: CGFloat = 0
  let settingsAbs = NSRect(x: settingsX, y: buttonItemTop - buttonViewHeight + buttonPadY,
                           width: buttonSize, height: buttonSize)
  let quitAbs = NSRect(x: quitX, y: settingsAbs.minY, width: buttonSize, height: buttonSize)

  // 7. the button item must clear the card item, and keep its own menu-item padding
  check("button item clears the card item", settingsAbs.maxY <= buttonItemTop + 0.01,
        String(format: "buttons top %.1f, card item bottom %.1f", settingsAbs.maxY, buttonItemTop))
  check("button item keeps its own padding", buttonPadY >= 4,
        String(format: "%.1f pt above and below the icons", buttonPadY))

  // 8. nothing may overlap anything else — compared within one coordinate space at a time,
  // since separate menu items are stacked rather than drawn over each other.
  var cardItems: [(String, NSRect)] = [("label", labelRect), ("icon", iconAbs), ("slider", sliderAbs)]
  for (index, row) in rowRects.enumerated() {
    cardItems.append(("row \(index + 1)", row))
  }
  let buttonItems: [(String, NSRect)] = [("settings", settingsAbs), ("quit", quitAbs)]

  var collisions: [String] = []
  for group in [cardItems, buttonItems] {
    for i in 0 ..< group.count {
      for j in (i + 1) ..< group.count {
        let a = group[i], b = group[j]
        // rows contain their own icon/slider, so skip those pairs
        if a.0.hasPrefix("row") && (b.0 == "icon" || b.0 == "slider") { continue }
        if b.0.hasPrefix("row") && (a.0 == "icon" || a.0 == "slider") { continue }
        if a.0.hasPrefix("row") && b.0.hasPrefix("row") { continue }
        if a.1.intersects(b.1) { collisions.append("\(a.0) x \(b.0)") }
      }
    }
  }
  check("no overlaps", collisions.isEmpty, collisions.isEmpty ? "clean" : collisions.joined(separator: ", "))
  print("")
}

print(failures.isEmpty ? "ALL CHECKS PASSED" : "FAILURES: \(failures.joined(separator: ", "))")
