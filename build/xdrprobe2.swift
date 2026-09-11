// Read-only diagnostic: is the built-in XDR panel actually online right now?

import Cocoa
import Darwin

typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

func loadGetBrightness() -> GetBrightnessFn? {
  let candidates = [
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
  ]
  for path in candidates {
    guard let handle = dlopen(path, RTLD_NOW) else { continue }
    if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
      return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }
  }
  return nil
}

let getBrightness = loadGetBrightness()

func brightness(of id: CGDirectDisplayID) -> String {
  var value: Float = -1
  let ret = getBrightness?(id, &value) ?? -99
  return "ret=\(ret) value=\(value)"
}

func list(_ label: String, _ fn: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError) {
  var count: UInt32 = 0
  fn(0, nil, &count)
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
  fn(count, &ids, &count)
  print("\(label) (\(count)): \(ids.prefix(Int(count)).map(String.init).joined(separator: ", "))")
}

print("=== display lists ===")
list("online", CGGetOnlineDisplayList)
list("active", CGGetActiveDisplayList)

var allCount: UInt32 = 0
CGGetDisplaysWithRect(CGRect(x: -100000, y: -100000, width: 200000, height: 200000), 0, nil, &allCount)
print("all displays in a huge rect: \(allCount)")

print("")
print("=== main display ===")
let main = CGMainDisplayID()
print("CGMainDisplayID: \(main)  builtin: \(CGDisplayIsBuiltin(main) != 0)  brightness: \(brightness(of: main))")

print("")
print("=== built-in display 1, probed directly ===")
let id: CGDirectDisplayID = 1
print("CGDisplayIsBuiltin(1)  : \(CGDisplayIsBuiltin(id) != 0)")
print("vendor/model/serial    : \(CGDisplayVendorNumber(id)) / \(CGDisplayModelNumber(id)) / \(CGDisplaySerialNumber(id))")
print("CGDisplayIsActive(1)   : \(CGDisplayIsActive(id) != 0)")
print("CGDisplayIsOnline(1)   : \(CGDisplayIsOnline(id) != 0)")
print("CGDisplayIsAsleep(1)   : \(CGDisplayIsAsleep(id) != 0)")
print("brightness(1)          : \(brightness(of: id))")

print("")
print("=== NSScreen ===")
for screen in NSScreen.screens {
  let name = screen.localizedName
  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  let screenID = number.map { CGDirectDisplayID($0.uint32Value) }
  let isBuiltin = screenID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
  print("  \"\(name)\"  id=\(screenID.map(String.init) ?? "?")  builtin=\(isBuiltin)  frame=\(screen.frame)")
}
