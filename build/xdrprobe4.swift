// What does macOS actually expose for going brighter than SDR on this panel?
//
// xdrprobe3 proved DisplayServicesSetBrightness() hard-clamps at 1.0. So the question
// becomes: how is extended brightness meant to be reached at all? On XDR panels the
// answer is EDR (Extended Dynamic Range) headroom, not a brightness setter. This probe
// measures that headroom and dumps the brightness-related symbols the private frameworks
// actually export, so we can see whether another entry point exists.

import Cocoa
import Darwin

print("=== NSScreen EDR headroom ===")
for screen in NSScreen.screens {
  let name = screen.localizedName
  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  let screenID = number.map { CGDirectDisplayID($0.uint32Value) } ?? 0
  print("screen \"\(name)\" id=\(screenID) builtin=\(CGDisplayIsBuiltin(screenID) != 0)")
  print("  maximumExtendedDynamicRangeColorComponentValue          = \(screen.maximumExtendedDynamicRangeColorComponentValue)")
  if #available(macOS 15.0, *) {
    print("  maximumPotentialExtendedDynamicRangeColorComponentValue  = \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
  }
  if #available(macOS 15.0, *) {
    print("  maximumReferenceExtendedDynamicRangeColorComponentValue  = \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
  }
  if let cs = screen.colorSpace {
    print("  colorSpace = \(cs.localizedName ?? "?")  components=\(cs.numberOfColorComponents)  cgColorSpace HDR=\(cs.cgColorSpace?.isHDR() ?? false)")
  }
  print("  frame = \(screen.frame)")
}

print("")
print("=== CGDisplayMode / HDR flags for display 1 ===")
if let mode = CGDisplayCopyDisplayMode(1) {
  print("  width=\(mode.width) height=\(mode.height) refresh=\(mode.refreshRate) ioFlags=\(mode.ioFlags)")
  print("  pixelEncoding=\(mode.pixelEncoding)")
}

print("")
print("=== private symbol dump: brightness entry points ===")
func dumpSymbols(_ frameworkPath: String, _ needle: String) {
  guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
    print("  (could not dlopen \(frameworkPath))")
    return
  }
  var info = Dl_info()
  // Walk the loaded image headers is overkill; instead grep the binary's symbol table.
  _ = handle
  _ = info
  print("  --- \(frameworkPath) ---")
  let task = Process()
  task.launchPath = "/usr/bin/nm"
  task.arguments = ["-gU", frameworkPath]
  let pipe = Pipe()
  task.standardOutput = pipe
  do {
    try task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    let lines = text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(needle) }
    if lines.isEmpty {
      print("    (no symbols matching \"\(needle)\")")
    } else {
      for line in lines.prefix(60) { print("    \(line)") }
    }
  } catch {
    print("    nm failed: \(error)")
  }
}

dumpSymbols("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", "brightness")
dumpSymbols("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", "brightness")
dumpSymbols("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", "hdr")
dumpSymbols("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", "edr")

print("")
print("=== can we raise the panel by drawing EDR content? ===")
print("  see xdrprobe5: draws a full-screen overlay with wantsExtendedDynamicRangeContent")
