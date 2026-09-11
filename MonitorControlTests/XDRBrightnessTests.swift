//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import XCTest

@testable import XDRMonitorControl

// Tests for the XDR extended brightness logic. Uses dummy displays so no real
// display is ever touched from the test suite.
final class XDRBrightnessTests: XCTestCase {
  var appleDisplay: AppleDisplay!
  var otherDisplay: Display!

  override func setUp() {
    super.setUp()
    self.appleDisplay = AppleDisplay(1, name: "XDR Test Display", vendorNumber: 1552, modelNumber: 1_002, serialNumber: 1, isVirtual: false, isDummy: true)
    self.appleDisplay.isXDRCapable = true
    self.otherDisplay = Display(2, name: "Other Test Display", vendorNumber: 7_777, modelNumber: 3, serialNumber: 2, isVirtual: false, isDummy: true)
  }

  override func tearDown() {
    for display in [self.appleDisplay as Display?, self.otherDisplay] {
      display?.removePref(key: .xdrEnabled)
      display?.removePref(key: .xdrMaxBrightness)
      display?.removePref(key: .xdrProbed)
      display?.removePref(key: .xdrWarningAcknowledged)
      display?.removePref(for: .brightness)
    }
    self.appleDisplay = nil
    self.otherDisplay = nil
    super.tearDown()
  }

  func testBrightnessMaxIsStandardWhenXDRNotCapable() {
    self.appleDisplay.isXDRCapable = false
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    XCTAssertEqual(self.appleDisplay.brightnessMaxValue, 1.0)
  }

  func testBrightnessMaxIsStandardWhenXDRDisabled() {
    self.appleDisplay.savePref(false, key: .xdrEnabled)
    XCTAssertEqual(self.appleDisplay.brightnessMaxValue, 1.0)
  }

  func testBrightnessMaxIsExtendedWhenXDREnabled() {
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    XCTAssertEqual(self.appleDisplay.brightnessMaxValue, self.appleDisplay.xdrMaxValue)
    XCTAssertGreaterThan(self.appleDisplay.brightnessMaxValue, 1.0)
  }

  func testOtherDisplaysStayAtStandardMaximum() {
    XCTAssertEqual(self.otherDisplay.brightnessMaxValue, 1.0)
  }

  func testCalcNewBrightnessStopsAtStandardMaxWhenXDRDisabled() {
    self.appleDisplay.savePref(false, key: .xdrEnabled)
    self.appleDisplay.savePref(Float(0.99), for: .brightness)
    XCTAssertEqual(self.appleDisplay.calcNewBrightness(isUp: true, isSmallIncrement: false), 1.0)
  }

  func testCalcNewBrightnessExtendsIntoXDRRange() {
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    self.appleDisplay.savePref(Float(1.0), for: .brightness)
    XCTAssertEqual(self.appleDisplay.calcNewBrightness(isUp: true, isSmallIncrement: false), Float(1.0625))
  }

  func testCalcNewBrightnessClampsAtXDRMax() {
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    self.appleDisplay.savePref(Float(1.48), for: .brightness)
    XCTAssertEqual(self.appleDisplay.calcNewBrightness(isUp: true, isSmallIncrement: false), self.appleDisplay.xdrMaxValue)
  }

  func testCalcNewBrightnessClampsAtZeroGoingDown() {
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    self.appleDisplay.savePref(Float(0.02), for: .brightness)
    XCTAssertEqual(self.appleDisplay.calcNewBrightness(isUp: false, isSmallIncrement: false), 0.0)
  }

  func testCalcNewBrightnessSupportsSmallIncrements() {
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    self.appleDisplay.savePref(Float(1.0), for: .brightness)
    XCTAssertEqual(self.appleDisplay.calcNewBrightness(isUp: true, isSmallIncrement: true), Float(1.015625))
  }

  func testXDRPrefsRoundTrip() {
    self.appleDisplay.savePref(true, key: .xdrEnabled)
    self.appleDisplay.savePref(Float(1.5), key: .xdrMaxBrightness)
    XCTAssertTrue(self.appleDisplay.readPrefAsBool(key: .xdrEnabled))
    XCTAssertEqual(self.appleDisplay.readPrefAsFloat(key: .xdrMaxBrightness), 1.5)
    self.appleDisplay.savePref(false, key: .xdrEnabled)
    XCTAssertFalse(self.appleDisplay.readPrefAsBool(key: .xdrEnabled))
    XCTAssertEqual(self.appleDisplay.brightnessMaxValue, 1.0)
  }

  func testSwBrightnessTransformKeepsLowTreshold() {
    XCTAssertEqual(self.appleDisplay.swBrightnessTransform(value: 0), 0.15)
    XCTAssertEqual(self.appleDisplay.swBrightnessTransform(value: 1), 1)
    XCTAssertEqual(self.appleDisplay.swBrightnessTransform(value: 0.15, reverse: true), 0)
    XCTAssertEqual(self.appleDisplay.swBrightnessTransform(value: 1, reverse: true), 1)
  }

  func testSwBrightnessTransformIsReversible() {
    let value: Float = 0.42
    let transformed = self.appleDisplay.swBrightnessTransform(value: value)
    let roundTrip = self.appleDisplay.swBrightnessTransform(value: transformed, reverse: true)
    XCTAssertEqual(roundTrip, value, accuracy: 0.0001)
  }
}
