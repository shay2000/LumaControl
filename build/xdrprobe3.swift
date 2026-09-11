// Ground-truth XDR probe for the built-in panel.
//
// Writes a ladder of brightness values above 1.0 and reads each one back. If the panel
// is XDR-capable the read-back tracks the write above 1.0; if it is not, every value
// clamps to 1.0. Restores the original brightness at the end, always.

import Cocoa
import Darwin

typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

func loadSymbol<T>(_ name: String) -> T? {
  let candidates = [
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
  ]
  for path in candidates {
    guard let handle = dlopen(path, RTLD_NOW) else { continue }
    if let sym = dlsym(handle, name) {
      return unsafeBitCast(sym, to: T.self)
    }
  }
  return nil
}

let getBrightness: GetBrightnessFn? = loadSymbol("DisplayServicesGetBrightness")
let setBrightness: SetBrightnessFn? = loadSymbol("DisplayServicesSetBrightness")

// --- when did the running app start? (tells us if its cached probe predates unplugging)
func processStartTime(_ pid: pid_t) -> String {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  let ret = sysctl(&mib, 4, &info, &size, nil, 0)
  guard ret == 0, size > 0 else { return "unknown" }
  let tv = info.kp_proc.p_starttime
  let date = Date(timeIntervalSince1970: Double(tv.tv_sec))
  let fmt = DateFormatter()
  fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return fmt.string(from: date)
}

print("=== display state ===")
var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
CGGetOnlineDisplayList(count, &ids, &count)
for id in ids.prefix(Int(count)) {
  print("  id=\(id) builtin=\(CGDisplayIsBuiltin(id) != 0) active=\(CGDisplayIsActive(id) != 0) online=\(CGDisplayIsOnline(id) != 0) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))")
}

let appPid = ProcessInfo.processInfo.processIdentifier
print("")
print("=== context ===")
print("now                 : \(processStartTime(appPid))  (this probe process)")

let target: CGDirectDisplayID = 1
guard CGDisplayIsOnline(target) != 0 else {
  print("display 1 is OFFLINE - cannot probe")
  exit(1)
}

var original: Float = -1
let readRet = getBrightness?(target, &original) ?? -99
print("brightness read ret : \(readRet)")
guard readRet == 0 else {
  print("cannot read brightness - aborting")
  exit(1)
}
print("original brightness : \(original)")

print("")
print("=== brightness ladder (write -> read back) ===")
print(String(format: "%-10@ %-10@ %@", "written", "read back", "verdict"))
let ladder: [Float] = [0.5, 1.0, 1.0 + 1.0 / 16.0, 1.125, 1.25, 1.375, 1.5, 1.75, 2.0]
var held: Float = 1.0
for value in ladder {
  setBrightness?(target, value)
  usleep(120_000)
  var back: Float = -1
  let backRet = getBrightness?(target, &back) ?? -99
  let verdict: String
  if backRet != 0 {
    verdict = "read failed"
  } else if back > 1.0001 {
    verdict = "EXTENDED"
    held = value
  } else if back > value - 0.02 {
    verdict = "ok (<=1.0)"
  } else {
    verdict = "CLAMPED to 1.0"
  }
  print(String(format: "%-10.4f %-10.4f %@", value, back, verdict))
}

print("")
print("=== quantisation check: 1/16 steps around 1.0 ===")
for step in stride(from: 12, through: 17, by: 1) {
  let value = Float(step) / 16.0
  setBrightness?(target, value)
  usleep(120_000)
  var back: Float = -1
  _ = getBrightness?(target, &back)
  print(String(format: "  write %.4f -> read %.4f  (delta %+.4f)", value, back, back - value))
}

print("")
print("=== restoring brightness to \(original) ===")
let restoreRet = setBrightness?(target, original) ?? -99
usleep(200_000)
var after: Float = -1
_ = getBrightness?(target, &after)
print("restore ret=\(restoreRet)  brightness now \(after)")

print("")
print("max value the panel held above 1.0: \(held)")
print(held > 1.0001 ? "VERDICT: this panel IS XDR-capable" : "VERDICT: this panel does NOT hold brightness above 1.0")
