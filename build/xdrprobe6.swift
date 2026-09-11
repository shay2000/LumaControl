// Feasibility test for the real XDR mechanism.
//
// DisplayServicesSetBrightness() hard-clamps at 1.0 (proved by xdrprobe3), so the current
// implementation cannot work. The public-API route used by BrightIntosh / overnits is:
//
//   1. Show a tiny window whose CAMetalLayer has wantsExtendedDynamicRangeContent = true
//      and is cleared to a value above 1.0. macOS then raises the backlight (HDR mode).
//   2. Scale the display gamma table with CGSetDisplayTransferByTable to lift SDR content
//      into that headroom.
//
// This probe does step 1 only, and logs whether macOS actually grants more headroom.

import Cocoa
import Metal
import QuartzCore

let screen = NSScreen.screens.first { CGDisplayIsBuiltin(
  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 0
) != 0 } ?? NSScreen.main!

let displayID: CGDirectDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 1

print("target screen : \(screen.localizedName) id=\(displayID)")
print("headroom before: current=\(screen.maximumExtendedDynamicRangeColorComponentValue) potential=\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")

guard let device = MTLCreateSystemDefaultDevice() else {
  print("no Metal device")
  exit(1)
}
guard let queue = device.makeCommandQueue() else {
  print("no command queue")
  exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// A 1x1 window in the corner is enough: macOS raises the backlight as soon as EDR
// content is visible anywhere, regardless of size.
let rect = NSRect(x: 0, y: 0, width: 2, height: 2)
let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
window.level = .normal
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
layer.isOpaque = false

let view = NSView(frame: rect)
view.wantsLayer = true
view.layer = layer
window.contentView = view
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()

func draw(value: Double) {
  let drawable = layer.nextDrawable()
  let descriptor = MTLRenderPassDescriptor()
  descriptor.colorAttachments[0].texture = drawable?.texture
  descriptor.colorAttachments[0].loadAction = .clear
  descriptor.colorAttachments[0].storeAction = .store
  descriptor.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1.0)
  if let drawable, let buffer = queue.makeCommandBuffer(),
     let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
    encoder.endEncoding()
    buffer.present(drawable)
    buffer.commit()
  }
}

var tick = 0
let total = 24 // 12 seconds at 2 Hz
var samples: [(Double, Double)] = []

let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
  tick += 1
  draw(value: 4.0)
  let current = screen.maximumExtendedDynamicRangeColorComponentValue
  samples.append((Double(tick) * 0.5, current))
  print(String(format: "  t=%4.1fs  headroom=%.3f", Double(tick) * 0.5, current))
  if tick >= total {
    t.invalidate()
    print("")
    let first = samples.first?.1 ?? 0
    let last = samples.last?.1 ?? 0
    print(String(format: "headroom %.3f -> %.3f", first, last))
    print(last > first + 0.05
      ? "VERDICT: macOS DID grant extra headroom - the EDR route works on this panel"
      : "VERDICT: headroom did not move - EDR activation is not taking effect")
    app.terminate(nil)
  }
}

RunLoop.current.add(timer, forMode: .common)
app.run()
