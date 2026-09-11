// Second half of the feasibility test: lift SDR content into the EDR headroom.
//
// With the panel in HDR mode (see xdrprobe6), multiply the display's gamma table by a
// boost factor and write it back with CGSetDisplayTransferByTable. Values above 1.0 in
// the table address the range beyond SDR white while the panel is in EDR mode.
//
// The original table is saved up front and restored on every exit path.

import Cocoa
import Metal
import QuartzCore
import Darwin

let boostSteps: [Double] = [1.0, 1.3, 1.6, 2.0, 1.0]

// ---------- locate the built-in display ----------
func displayID(of screen: NSScreen) -> CGDirectDisplayID {
  (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 1
}
let screen = NSScreen.screens.first { CGDisplayIsBuiltin(displayID(of: $0)) != 0 } ?? NSScreen.main!
let display = displayID(of: screen)

print("target: \(screen.localizedName) id=\(display)")

// ---------- save the original gamma table so it can always be restored ----------
let tableSize: UInt32 = 256
var redTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
var greenTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
var blueTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
var sampleCount: UInt32 = 0

let readErr = CGGetDisplayTransferByTable(display, tableSize, &redTable, &greenTable, &blueTable, &sampleCount)
print("CGGetDisplayTransferByTable -> \(readErr) sampleCount=\(sampleCount)")
if readErr != .success {
  print("cannot read gamma table; aborting")
  exit(1)
}
let originalRed = redTable
let originalGreen = greenTable
let originalBlue = blueTable
print(String(format: "original table: first=%.4f mid=%.4f last=%.4f", originalRed[0], originalRed[128], originalRed[255]))

var restored = false
func restore() {
  guard !restored else { return }
  restored = true
  CGSetDisplayTransferByTable(display, tableSize, originalRed, originalGreen, originalBlue)
  print("gamma table restored")
}
atexit { restore() }

func apply(boost: Double) -> Bool {
  var r = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var g = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var b = [CGGammaValue](repeating: 0, count: Int(tableSize))
  for i in 0 ..< Int(tableSize) {
    r[i] = CGGammaValue(min(Double(originalRed[i]) * boost, 64.0))
    g[i] = CGGammaValue(min(Double(originalGreen[i]) * boost, 64.0))
    b[i] = CGGammaValue(min(Double(originalBlue[i]) * boost, 64.0))
  }
  let err = CGSetDisplayTransferByTable(display, tableSize, r, g, b)
  usleep(250_000)
  // read back to see whether values above 1.0 survive
  var rb = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var gb = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var bb = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var sc: UInt32 = 0
  CGGetDisplayTransferByTable(display, tableSize, &rb, &gb, &bb, &sc)
  let mid = Int(tableSize) - 1
  print(String(format: "boost %.2f -> set err=%d  readback last=%.4f (asked %.4f)  headroom=%.3f",
               boost, err.rawValue, rb[mid], r[mid], screen.maximumExtendedDynamicRangeColorComponentValue))
  return err == .success
}

// ---------- EDR activation ----------
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
  print("no Metal")
  exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let rect = NSRect(x: 0, y: 0, width: 2, height: 2)
let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
window.isOpaque = false
window.backgroundColor = .clear
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .rgba16Float
layer.wantsExtendedDynamicRangeContent = true
layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
layer.framebufferOnly = false
let view = NSView(frame: rect)
view.wantsLayer = true
view.layer = layer
window.contentView = view
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()

func draw(value: Double) {
  guard let drawable = layer.nextDrawable() else { return }
  let descriptor = MTLRenderPassDescriptor()
  descriptor.colorAttachments[0].texture = drawable.texture
  descriptor.colorAttachments[0].loadAction = .clear
  descriptor.colorAttachments[0].storeAction = .store
  descriptor.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1.0)
  if let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
    encoder.endEncoding()
    buffer.present(drawable)
    buffer.commit()
  }
}

var phase = 0      // 0..n: waiting for headroom, then one step per boost value
var waited: Double = 0
var stepIndex = 0

let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
  draw(value: 4.0)
  if phase == 0 {
    waited += 0.5
    let h = screen.maximumExtendedDynamicRangeColorComponentValue
    print(String(format: "  waiting for headroom... %.3f", h))
    if waited >= 3.0 {
      print("")
      print("=== applying gamma boost (screen will get brighter) ===")
      phase = 1
    }
    return
  }
  if stepIndex < boostSteps.count {
    let boost = boostSteps[stepIndex]
    print("step \(stepIndex + 1)/\(boostSteps.count): ", terminator: "")
    _ = apply(boost: boost)
    stepIndex += 1
    return
  }
  t.invalidate()
  print("")
  restore()
  print("done")
  app.terminate(nil)
}

RunLoop.current.add(timer, forMode: .common)
app.run()
