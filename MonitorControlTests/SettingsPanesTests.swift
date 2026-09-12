//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import XCTest

@testable import LumaControl

// The Settings window is assembled at launch from five storyboard scenes, and when that
// goes wrong it goes wrong silently.
//
// `NSStoryboard.instantiateController(withIdentifier:)` does not raise when a scene's
// `customModule` names a Swift module that does not exist at runtime. AppKit only logs
// "Unknown class … in Interface Builder file" to the console, hands back a plain
// `NSViewController`, and the `as?` cast in `main.swift` yields nil. `AppDelegate`
// then drops every pane, so the gear button and reopening the app both show
// "Settings could not be opened" with nothing on screen to say why.
//
// That is exactly what happened when the app target was renamed to LumaControl. Every
// scene is declared `customModuleProvider="target"`, so ibtool bakes `PRODUCT_MODULE_NAME`
// into the compiled storyboard — and `PRODUCT_MODULE_NAME` follows `PRODUCT_NAME`, which
// had become `LumaControl`. The app target still carried an explicit
// `SWIFT_MODULE_NAME = XDRMonitorControl`, and that is the string the Swift compiler uses
// for `-module-name` and therefore for the runtime class names. The storyboard asked for
// `LumaControl.MainPrefsViewController`, the binary only had
// `XDRMonitorControl.MainPrefsViewController`, and all five panes vanished.
//
// These tests load the same scenes the same way `main.swift` does, so they fail loudly the
// moment the two names drift apart again. They need no display and touch no hardware.
final class SettingsPanesTests: XCTestCase {
  func testDestroyedShadeDoesNotRetainClosedWindow() {
    let displayID = CGDirectDisplayID.max
    weak var weakShade: NSWindow?

    autoreleasepool {
      let shade = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
      shade.isReleasedWhenClosed = false
      weakShade = shade
      DisplayManager.shared.shades[displayID] = shade

      XCTAssertTrue(DisplayManager.shared.destroyShade(displayID: displayID))
      XCTAssertNil(DisplayManager.shared.shades[displayID])
    }

    XCTAssertNil(weakShade, "Destroying a shade must release the closed window after removing it from the manager.")
  }

  func testEverySettingsPaneLoadsFromTheStoryboard() {
    let storyboard = NSStoryboard(name: "Main", bundle: Bundle.main)

    let main = storyboard.instantiateController(withIdentifier: "MainPrefsVC") as? MainPrefsViewController
    XCTAssertNotNil(main, "The MainPrefsVC scene did not load — see the note at the top of SettingsPanesTests.")

    let menusliders = storyboard.instantiateController(withIdentifier: "MenuslidersPrefsVC") as? MenuslidersPrefsViewController
    XCTAssertNotNil(menusliders, "The MenuslidersPrefsVC scene did not load — see the note at the top of SettingsPanesTests.")

    let keyboard = storyboard.instantiateController(withIdentifier: "KeyboardPrefsVC") as? KeyboardPrefsViewController
    XCTAssertNotNil(keyboard, "The KeyboardPrefsVC scene did not load — see the note at the top of SettingsPanesTests.")

    let displays = storyboard.instantiateController(withIdentifier: "DisplaysPrefsVC") as? DisplaysPrefsViewController
    XCTAssertNotNil(displays, "The DisplaysPrefsVC scene did not load — see the note at the top of SettingsPanesTests.")

    let about = storyboard.instantiateController(withIdentifier: "AboutPrefsVC") as? AboutPrefsViewController
    XCTAssertNotNil(about, "The AboutPrefsVC scene did not load — see the note at the top of SettingsPanesTests.")
  }

  /// The storyboard resolves its scenes against `PRODUCT_MODULE_NAME`, and for an app
  /// target that is `PRODUCT_NAME` — the same value `CFBundleName` carries. So the runtime
  /// name of a pane class has to start with the app's own name. Comparing against
  /// `CFBundleName` rather than a literal means a future rename updates this check for
  /// free while still catching the case where the Swift module is pinned to an old name.
  func testPaneClassesLiveInTheModuleTheStoryboardResolvesAgainst() {
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    XCTAssertEqual(appName, "LumaControl", "CFBundleName should follow PRODUCT_NAME.")

    let paneClasses: [AnyClass] = [
      MainPrefsViewController.self,
      MenuslidersPrefsViewController.self,
      KeyboardPrefsViewController.self,
      DisplaysPrefsViewController.self,
      AboutPrefsViewController.self,
    ]

    for paneClass in paneClasses {
      let runtimeName = NSStringFromClass(paneClass)
      XCTAssertEqual(
        runtimeName.split(separator: ".").first.map(String.init),
        appName,
        "\(runtimeName) is compiled into a different module than the storyboard resolves against."
      )
    }
  }
}
