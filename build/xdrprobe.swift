// Read-only diagnostic: reproduces the decisions MonitorControl makes about
// displays, without changing anything on screen.
//
// Prints, for every online display:
//   - the public CoreGraphics facts the app uses to classify a display
//   - the CoreDisplay info-dictionary keys the app uses for `isVirtual`
//   - whether DisplayServicesGetBrightness succeeds (the app's "is this an
//     Apple display?" test)
//
// Build: swiftc -O -o /tmp/xdrprobe xdrprobe.swift
// Run:   /tmp/xdrprobe

import Cocoa
import Darwin

typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias InfoDictFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

func loadSymbol<T>(_ framework: String, _ symbol: String, as _: T.Type) -> T? {
  let candidates = [
    "/System/Library/PrivateFrameworks/\(framework).framework/\(framework)",
    "/System/Library/PrivateFrameworks/\(framework).framework/Versions/A/\(framework)",
  ]
  for path in candidates {
    guard let handle = dlopen(path, RTLD_NOW) else { continue }
    if let sym = dlsym(handle, symbol) {
      return unsafeBitCast(sym, to: T.self)
    }
  }
  return nil
}

let getBrightness = loadSymbol("DisplayServices", "DisplayServicesGetBrightness", as: GetBrightnessFn.self)
let infoDict = loadSymbol("CoreDisplay", "CoreDisplay_DisplayCreateInfoDictionary", as: InfoDictFn.self)

print("DisplayServicesGetBrightness available: \(getBrightness != nil)")
print("CoreDisplay_DisplayCreateInfoDictionary available: \(infoDict != nil)")
print("")

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

for id in ids {
  let builtin = CGDisplayIsBuiltin(id) != 0
  let vendor = CGDisplayVendorNumber(id)
  let model = CGDisplayModelNumber(id)
  let serial = CGDisplaySerialNumber(id)

  print("--- display \(id) ---")
  print("  CGDisplayIsBuiltin        : \(builtin)")
  print("  vendor / model / serial   : \(vendor) / \(model) / \(serial)")

  // This mirrors DisplayManager.isVirtual(displayID:)
  var isVirtual = false
  if let infoDict, let dict = infoDict(id)?.takeRetainedValue() as NSDictionary? {
    let virtualDevice = dict["kCGDisplayIsVirtualDevice"] as? Bool
    let airplay = dict["kCGDisplayIsAirPlay"] as? Bool
    print("  kCGDisplayIsVirtualDevice : \(String(describing: virtualDevice))")
    print("  kCGDisplayIsAirPlay       : \(String(describing: airplay))")
    if virtualDevice ?? airplay ?? false { isVirtual = true }
  } else {
    print("  info dictionary           : unavailable")
  }
  print("  => isVirtual              : \(isVirtual)")

  // This mirrors DisplayManager.isAppleDisplay(displayID:)
  var brightness: Float = -1
  let ret = getBrightness?(id, &brightness) ?? -99
  let readOK = (ret == 0 && brightness >= 0)
  print("  DisplayServicesGetBrightness: ret=\(ret) value=\(brightness)")
  let isApple = readOK || builtin
  print("  => isAppleDisplay         : \(isApple)")

  // The prefsId the app would build for this display.
  let name = "?"
  print("  (app prefsId uses display name + \(vendor) + \(model) + @\(isVirtual ? "serial" : String(id)))")
  _ = name
  print("")
}
