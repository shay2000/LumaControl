//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Foundation

// Debug
let DEBUG_SW = false
let DEBUG_VIRTUAL = false
let DEBUG_MACOS10 = false
let DEBUG_GAMMA_ENFORCER = false
let DDC_MAX_DETECT_LIMIT: Int = 100

// Version
// The lowest *previous* build number whose saved preferences are still considered
// compatible. This fork restarted its own version numbering at 0.1.0 (build 1), so
// there are no older fork builds to migrate away from. This value must stay at or
// below the current build number: if it is higher, setPrefsBuildNumber() treats
// every single launch as an upgrade from an incompatible version and erases the
// whole preference domain, which also discards per-display settings such as whether
// XDR brightness is enabled.
let MIN_PREVIOUS_BUILD_NUMBER = 1

// App
var app: AppDelegate!
var menu: MenuHandler!

let prefs = UserDefaults.standard

// Views
private let storyboard = NSStoryboard(name: "Main", bundle: Bundle.main)
let mainPrefsVc = storyboard.instantiateController(withIdentifier: "MainPrefsVC") as? MainPrefsViewController
let displaysPrefsVc = storyboard.instantiateController(withIdentifier: "DisplaysPrefsVC") as? DisplaysPrefsViewController
let menuslidersPrefsVc = storyboard.instantiateController(withIdentifier: "MenuslidersPrefsVC") as? MenuslidersPrefsViewController
let keyboardPrefsVc = storyboard.instantiateController(withIdentifier: "KeyboardPrefsVC") as? KeyboardPrefsViewController
let aboutPrefsVc = storyboard.instantiateController(withIdentifier: "AboutPrefsVC") as? AboutPrefsViewController
let onboardingVc = storyboard.instantiateController(withIdentifier: "onboardingViewController") as? NSWindowController

autoreleasepool { () in
  let mc = NSApplication.shared
  let mcDelegate = AppDelegate()
  mc.delegate = mcDelegate
  mc.run()
}
