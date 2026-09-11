import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
  guard owner.contains("XDRMonitor") else { continue }
  let name = w[kCGWindowName as String] as? String ?? ""
  let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print("owner=\(owner) name=\"\(name)\" bounds=\(bounds)")
}
print("done")
