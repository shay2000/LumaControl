// Watches for on-screen HUD/OSD windows.
// The macOS OSD renders at a very high CGWindowLevel, so we list every window with its
// level, owner and bounds and print anything that changes or anything sitting high.
import CoreGraphics
import Foundation

func snapshot() -> [(String, Int, String)] {
  guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    return []
  }
  var out: [(String, Int, String)] = []
  for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
    let level = (w[kCGWindowLayer as String] as? Int) ?? 0
    var b = w[kCGWindowBounds as String] as? [String: Any]
    let bounds = b.map { "\(Int($0["X"] as? Double ?? 0)),\(Int($0["Y"] as? Double ?? 0)) \(Int($0["Width"] as? Double ?? 0))x\(Int($0["Height"] as? Double ?? 0))" } ?? "?"
    let name = (w[kCGWindowName as String] as? String) ?? ""
    out.append(("\(owner)#\(pid) L\(level) \(bounds) \(name)", level, owner))
  }
  return out
}

var seen: Set<String> = []
let seconds = Int(CommandLine.arguments.count > 1 ? (CommandLine.arguments[1] as NSString).intValue : 20)
print("watching \(seconds)s ...")
for i in 0..<seconds {
  let s = snapshot()
  var current: Set<String> = []
  for (desc, level, _) in s {
    current.insert(desc)
    if !seen.contains(desc) {
      // Anything at/above the OSD band (level >= 100) is interesting; print all on first pass.
      if level >= 100 || i == 0 {
        print("[\(i)s] NEW  \(desc)")
      }
    }
  }
  for old in seen where !current.contains(old) {
    print("[\(i)s] GONE \(old)")
  }
  seen = current
  Thread.sleep(forTimeInterval: 1.0)
}
