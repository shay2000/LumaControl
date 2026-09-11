import AppKit
import CoreAudio
import CoreGraphics
import Foundation

typealias CDInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

let handle = dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
var cdInfo: CDInfoFn?
if let handle = handle, let sym = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") {
  cdInfo = unsafeBitCast(sym, to: CDInfoFn.self)
}

func rawName(_ id: CGDirectDisplayID) -> String {
  if let d = cdInfo?(id)?.takeRetainedValue() as NSDictionary?,
     let list = d["DisplayProductName"] as? [String: String],
     let n = list["en_US"] ?? list.first?.value {
    return n
  }
  return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.localizedName ?? ""
}

func normalized(_ name: String) -> String {
  var s = name.replacingOccurrences(of: "(", with: "")
  s = s.replacingOccurrences(of: ")", with: "")
  s = s.replacingOccurrences(of: " ", with: "")
  for i in 0...9 { s = s.replacingOccurrences(of: String(i), with: "") }
  return s
}

func defaultOutputDeviceName() -> String {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var deviceID = AudioObjectID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
        deviceID != kAudioObjectUnknown else { return "<none>" }
  var nameAddr = AudioObjectPropertyAddress(
    mSelector: kAudioObjectPropertyName,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var name: CFString = "" as CFString
  var nsize = UInt32(MemoryLayout<CFString>.size)
  guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nsize, &name) == noErr else { return "<unreadable>" }
  return name as String
}

let audioName = defaultOutputDeviceName()
print("default output device : \"\(audioName)\"")
print("normalized            : \(normalized(audioName))")
print()

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
_ = CGGetOnlineDisplayList(16, &ids, &count)
print("online displays: \(ids.prefix(Int(count)).filter { $0 != 0 })")
print()
var matches = 0
for id in ids where id != 0 {
  let raw = rawName(id)
  let norm = normalized(raw)
  let hit = norm == normalized(audioName)
  if hit { matches += 1 }
  print(String(format: "display %u  raw=\"%@\"  normalized=%@  match=%@", id, raw, norm, hit ? "YES" : "no"))
}
print()
print("updateAudioControlTargetDisplays would return: \(matches)")
