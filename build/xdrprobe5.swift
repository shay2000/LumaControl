// Is there ANY private entry point that pushes the built-in panel past SDR white?
//
// The frameworks live in the dyld shared cache, so `nm <path>` fails; resolve candidate
// symbols at runtime with dlsym instead. Then try the ones that exist and see whether any
// of them moves the panel above 1.0.

import Cocoa
import Darwin

typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

let frameworks = [
  "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
  "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
  "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
]

var handles: [UnsafeMutableRawPointer] = []
for path in frameworks {
  if let h = dlopen(path, RTLD_NOW) {
    handles.append(h)
    print("loaded: \(path)")
  } else {
    print("could not load: \(path)")
  }
}

let candidates = [
  "DisplayServicesGetBrightness",
  "DisplayServicesSetBrightness",
  "DisplayServicesGetLinearBrightness",
  "DisplayServicesSetLinearBrightness",
  "DisplayServicesSetBrightnessWithFade",
  "DisplayServicesCanChangeBrightness",
  "DisplayServicesGetBrightnessRange",
  "DisplayServicesGetMaxBrightness",
  "DisplayServicesGetHDRBrightness",
  "DisplayServicesSetHDRBrightness",
  "DisplayServicesGetEDRBrightness",
  "DisplayServicesSetEDRBrightness",
  "DisplayServicesIsHDRModeEnabled",
  "DisplayServicesSetHDRMode",
  "CoreDisplay_Display_GetBrightness",
  "CoreDisplay_Display_SetBrightness",
  "CoreDisplay_Display_SetUserBrightness",
  "CoreDisplay_Display_GetUserBrightness",
  "CoreDisplay_Display_GetMaxBrightness",
  "CoreDisplay_Display_SetDynamicRange",
  "CoreDisplay_Display_GetDynamicRange",
  "CoreDisplay_Display_IsHDRCapable",
  "CoreDisplay_Display_SetHDRBrightness",
  "CGDisplayIsHDRCapable",
  "CGDisplaySetBrightness",
]

print("")
print("=== symbol resolution ===")
var found: [String: UnsafeMutableRawPointer] = [:]
for name in candidates {
  var resolved = false
  for handle in handles {
    if let sym = dlsym(handle, name) {
      found[name] = sym
      resolved = true
      break
    }
  }
  print("  \(resolved ? "YES" : " no")  \(name)")
}

print("")
print("=== can any of them write above 1.0? ===")
let id: CGDirectDisplayID = 1

if let sym = found["DisplayServicesGetBrightness"] {
  let get = unsafeBitCast(sym, to: GetBrightnessFn.self)
  var original: Float = -1
  _ = get(id, &original)
  print("current brightness: \(original)")

  if let setSym = found["DisplayServicesSetBrightness"] {
    let set = unsafeBitCast(setSym, to: SetBrightnessFn.self)
    for value in [Float(1.0), 1.2, 1.5, 2.0] {
      set(id, value)
      usleep(150_000)
      var back: Float = -1
      _ = get(id, &back)
      print(String(format: "  DisplayServices  write %.2f -> read %.4f", value, back))
    }
  }

  // Generic float setter: (CGDirectDisplayID, Float) -> Int32
  for name in ["DisplayServicesSetLinearBrightness", "DisplayServicesSetHDRBrightness", "DisplayServicesSetEDRBrightness",
               "CoreDisplay_Display_SetBrightness", "CoreDisplay_Display_SetUserBrightness",
               "CoreDisplay_Display_SetHDRBrightness"] {
    guard let sym = found[name] else { continue }
    let set = unsafeBitCast(sym, to: SetBrightnessFn.self)
    for value in [Float(1.0), 1.5, 2.0] {
      let ret = set(id, value)
      usleep(150_000)
      var back: Float = -1
      _ = get(id, &back)
      print(String(format: "  %-42s write %.2f -> read %.4f (ret %d)", name, value, back, ret))
      if back > 1.0001 { print("     ^^ ABOVE 1.0 - this API works") }
    }
    // restore
    set(id, original)
  }

  print("")
  print("restoring brightness to \(original)")
  if let setSym = found["DisplayServicesSetBrightness"] {
    let set = unsafeBitCast(setSym, to: SetBrightnessFn.self)
    set(id, original)
    usleep(200_000)
    var back: Float = -1
    _ = get(id, &back)
    print("brightness now \(back)")
  }
}
