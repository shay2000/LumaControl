// Diagnostic: reconstructs the popout menu geometry exactly as MenuHandler and
// SliderHandler lay it out, prints every frame, and flags real overlaps.
//
// Read-only: creates views offscreen, never touches a display or writes prefs.
//
// Build: swiftc -O -o /tmp/uiprobe uiprobe.swift
// Run:   /tmp/uiprobe

import AppKit
import CoreAudio
import Darwin

// ---------------------------------------------------------------- audio device

func defaultOutputDevice() -> AudioDeviceID? {
  var deviceID = AudioDeviceID(0)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
  guard status == noErr, deviceID != 0 else { return nil }
  return deviceID
}

func deviceName(_ id: AudioDeviceID) -> String {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioObjectPropertyName,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var name: CFString = "" as CFString
  var size = UInt32(MemoryLayout<CFString>.size)
  let status = withUnsafeMutablePointer(to: &name) { pointer -> OSStatus in
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
  }
  return status == noErr ? (name as String) : "<unknown>"
}

/// Mirrors SimplyCoreAudio's `canSetVirtualMainVolume(scope:)`: true when the device
/// exposes a settable volume on its main element for the given scope.
func canSetMainVolume(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyVolumeScalar,
    mScope: scope,
    mElement: kAudioObjectPropertyElementMain)
  guard AudioObjectHasProperty(id, &address) else { return false }
  var settable: DarwinBoolean = false
  guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
  return settable.boolValue
}

print("=== default output audio device ===")
if let device = defaultOutputDevice() {
  let name = deviceName(device)
  let canSet = canSetMainVolume(device, scope: kAudioObjectPropertyScopeOutput)
  print("  name                              : \(name)")
  print("  canSetVirtualMainVolume(output)   : \(canSet)")
  print("")
  print("  MonitorControl's updateMediaKeyTap() removes the volume/mute keys from its")
  print("  tap when this is true (and multiKeyboardVolume is not audioDeviceNameMatching).")
  print("  => hardware volume keys are handed back to macOS: \(canSet)")
} else {
  print("  (could not read the default output device)")
}

// ------------------------------------------------------------------- geometry

let app = NSApplication.shared
_ = app

// Values taken from the app's registered defaults for this machine.
let showPercent = false          // enableSliderPercent = false
let showTickMarks = false        // showTickMarks = false
let numOfTickmarks = showTickMarks ? 5 : 0

struct Rect {
  let name: String
  let rect: NSRect
}

func overlaps(_ a: NSRect, _ b: NSRect) -> Bool {
  a.intersects(b)
}

func report(_ title: String, _ rects: [Rect], _ notes: [String] = []) {
  print("")
  print("=== \(title) ===")
  for r in rects {
    print(String(format: "  %-22@  x %7.1f → %7.1f   y %7.1f → %7.1f   (w %6.1f h %5.1f)",
                 r.name as NSString, r.rect.minX, r.rect.maxX, r.rect.minY, r.rect.maxY, r.rect.width, r.rect.height))
  }
  var found = false
  for i in 0 ..< rects.count {
    for j in (i + 1) ..< rects.count {
      if overlaps(rects[i].rect, rects[j].rect) {
        let x = max(0, min(rects[i].rect.maxX, rects[j].rect.maxX) - max(rects[i].rect.minX, rects[j].rect.minX))
        let y = max(0, min(rects[i].rect.maxY, rects[j].rect.maxY) - max(rects[i].rect.minY, rects[j].rect.minY))
        print(String(format: "  !! OVERLAP: %@ x %@  (%.1f x %.1f pt)", rects[i].name, rects[j].name, x, y))
        found = true
      }
    }
  }
  if !found { print("  (no overlaps)") }
  for note in notes { print("  note: \(note)") }
}

// --- one SliderHandler row, replicating SliderHandler.init for macOS 11+ ---
let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
slider.frame.size.width = 180
slider.frame.origin = NSPoint(x: 15, y: 5)

print("")
print("=== measured slider ===")
print("  NSSlider(value:minValue:maxValue:target:action:) height = \(slider.frame.height)")
print("  frame after the app's adjustments = \(slider.frame)")

let rowView = NSView(frame: NSRect(x: 0, y: 0,
                                   width: slider.frame.width + 30 + (showPercent ? 38 : 0),
                                   height: slider.frame.height + 14))
rowView.frame.origin = NSPoint(x: 12, y: 0)

let iconSize = CGFloat(13)
let iconRect = NSRect(x: 1, y: slider.frame.midY - iconSize / 2, width: iconSize, height: iconSize)
let sliderRect = slider.frame
let percentRect = showPercent
  ? NSRect(x: 15 + slider.frame.size.width - 2, y: 17, width: 40, height: 12)
  : NSRect(x: 0, y: 0, width: 0, height: 0)

var rowRects: [Rect] = [
  Rect(name: "row view", rect: NSRect(origin: .zero, size: rowView.frame.size)),
  Rect(name: "icon", rect: iconRect),
  Rect(name: "slider", rect: sliderRect),
]
if showPercent { rowRects.append(Rect(name: "percent box", rect: percentRect)) }
report("slider row (view-local coordinates)", rowRects, [
  "row view height = slider height + 14 = \(rowView.frame.height)",
  "icon vertical centre = \(iconRect.midY), row vertical centre = \(rowView.bounds.midY)",
  "slider is NOT vertically centred: its centre is \(sliderRect.midY) vs row centre \(rowView.bounds.midY)",
])

// --- the display "block" item view, replicating addDisplayMenuBlock ---
let rowHeight = rowView.frame.height
let rowWidth = rowView.frame.width
let sliderCount = 3 // volume + contrast + brightness is the maximum; brightness only here
let effectiveSliders = 2 // LG HDR 4K exposes volume + brightness in the user's setup

let margin = CGFloat(13)
let labelGap = CGFloat(6)
let blockName = "LG HDR 4K"
let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor,
                                            .font: NSFont.boldSystemFont(ofSize: 12)]
let label = NSTextField(labelWithAttributedString: NSAttributedString(string: blockName, attributes: attrs))
label.frame.size.width = rowWidth - margin * 2
let labelHeight = label.fittingSize.height

print("")
print("=== block label ===")
print("  fittingSize = \(label.fittingSize)  (height used by the layout = \(labelHeight))")

var contentWidth = rowWidth
var contentHeight = CGFloat(effectiveSliders) * rowHeight
if labelHeight > 0 { contentHeight += labelHeight + labelGap }
let itemViewSize = NSRect(x: 0, y: 0, width: contentWidth + margin * 2, height: contentHeight + margin * 2)

// The BlockView card rectangle, exactly as drawn.
let cardRect = itemViewSize.insetBy(dx: 15, dy: 15 / 2 + 2).offsetBy(dx: 0, dy: 15 / 2 * -1 + 7)

var blockRects: [Rect] = [Rect(name: "item view", rect: itemViewSize), Rect(name: "card outline", rect: cardRect)]
var sliderPosition = CGFloat(margin * -1 + 1)
for i in 0 ..< effectiveSliders {
  let origin = NSPoint(x: margin, y: margin + sliderPosition + 13)
  blockRects.append(Rect(name: "row \(i + 1) view", rect: NSRect(origin: origin, size: rowView.frame.size)))
  blockRects.append(Rect(name: "  row \(i + 1) icon", rect: iconRect.offsetBy(dx: origin.x, dy: origin.y)))
  blockRects.append(Rect(name: "  row \(i + 1) slider", rect: sliderRect.offsetBy(dx: origin.x, dy: origin.y)))
  sliderPosition += rowHeight
}
blockRects.append(Rect(name: "block label", rect: NSRect(x: margin + 13, y: contentHeight + margin - labelHeight, width: rowWidth - margin * 2, height: labelHeight)))

report("display block item view", blockRects, [
  "card left edge = \(cardRect.minX), card right edge = \(cardRect.maxX)",
  "first slider starts at x = \(margin + 15) — the icon sits at x \(margin + 1) → \(margin + 1 + iconSize)",
  "label baseline area starts at x = \(margin + 13) but sliders' icons start at x = \(margin + 1): the label and the icons use DIFFERENT left edges",
  "row \(effectiveSliders) bottom = \(margin + sliderPosition + 13 - rowHeight + rowHeight); label top = \(contentHeight + margin - labelHeight + labelHeight)",
])

// --- the settings / quit row, replicating addDefaultMenuOptions ---
let iconSizeButton = CGFloat(18)
let viewWidth = max(itemViewSize.width, 130)
let trailingInset: CGFloat = 13 // usesDisplayBlocks == true
let trailingMargin: CGFloat = 10
let buttonRowHeight = iconSizeButton + 10
let settingsRect = NSRect(x: viewWidth - trailingInset - trailingMargin - iconSizeButton * 2 - 14,
                          y: (buttonRowHeight - iconSizeButton) / 2,
                          width: iconSizeButton, height: iconSizeButton)
let quitRect = NSRect(x: viewWidth - trailingInset - trailingMargin - iconSizeButton,
                      y: (buttonRowHeight - iconSizeButton) / 2,
                      width: iconSizeButton, height: iconSizeButton)

report("settings / quit row (view-local)", [
  Rect(name: "item view", rect: NSRect(x: 0, y: 0, width: viewWidth, height: buttonRowHeight)),
  Rect(name: "settings", rect: settingsRect),
  Rect(name: "quit", rect: quitRect),
  Rect(name: "card right edge (x only)", rect: NSRect(x: cardRect.maxX, y: 0, width: 0.5, height: buttonRowHeight)),
], [
  "block item view width = \(itemViewSize.width), settings row width = \(viewWidth) → equal: \(itemViewSize.width == viewWidth)",
  "settings right edge = \(settingsRect.maxX), quit right edge = \(quitRect.maxX)",
])

// --- cross-check: does the row view fit inside the card? ---
print("")
print("=== summary ===")
print("  row view width                : \(rowWidth)")
print("  row placed at x               : \(margin)  → occupies \(margin) → \(margin + rowWidth)")
print("  card outline                  : \(cardRect.minX) → \(cardRect.maxX)")
print("  icon spans x                  : \(margin + 1) → \(margin + 1 + iconSize)")
print("  => icon crosses the card edge : \(margin + 1 < cardRect.minX)")
print("  slider row bottom (last)      : \(margin + sliderPosition + 13 - rowHeight + rowHeight)")
print("  label top                     : \(contentHeight + margin - labelHeight + labelHeight)")
print("  item view height              : \(itemViewSize.height)")
print("  trailing gap under label      : \(itemViewSize.height - (contentHeight + margin - labelHeight + labelHeight))")
