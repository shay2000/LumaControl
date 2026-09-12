//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import XCTest

@testable import XDRMonitorControl

// AppleDisplay.getBrightness() short-circuits to a constant for dummy displays, so
// calcNewBrightness tests use this stub to drive the current brightness directly.
private class StubbedBrightnessAppleDisplay: AppleDisplay {
  var stubbedBrightness: Float = 1

  override func getBrightness() -> Float {
    self.stubbedBrightness
  }
}

// Tests for the XDR extended brightness logic. Uses dummy displays so no real
// display is ever touched from the test suite.
final class XDRBrightnessTests: XCTestCase {
  var appleDisplay: AppleDisplay!
  private var stubbedDisplay: StubbedBrightnessAppleDisplay!
  var otherDisplay: Display!

  override func setUp() {
    super.setUp()
    self.appleDisplay = AppleDisplay(1, name: "XDR Test Display", vendorNumber: 1552, modelNumber: 1_002, serialNumber: 1, isVirtual: false, isDummy: true)
    self.appleDisplay.isXDRCapable = true
    self.stubbedDisplay = StubbedBrightnessAppleDisplay(1, name: "XDR Stub Display", vendorNumber: 1552, modelNumber: 1_003, serialNumber: 1, isVirtual: false, isDummy: true)
    self.stubbedDisplay.isXDRCapable = true
    self.otherDisplay = Display(2, name: "Other Test Display", vendorNumber: 7_777, modelNumber: 3, serialNumber: 2, isVirtual: false, isDummy: true)
  }

  override func tearDown() {
    for display in [self.appleDisplay as Display?, self.stubbedDisplay as Display?, self.otherDisplay] {
      display?.removePref(key: .xdrEnabled)
      display?.removePref(key: .xdrMaxBrightness)
      display?.removePref(key: .xdrWarningAcknowledged)
      display?.removePref(key: .value, for: .brightness)
    }
    self.appleDisplay = nil
    self.stubbedDisplay = nil
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
    self.stubbedDisplay.savePref(false, key: .xdrEnabled)
    self.stubbedDisplay.stubbedBrightness = 0.99
    XCTAssertEqual(self.stubbedDisplay.calcNewBrightness(isUp: true, isSmallIncrement: false), 1.0)
  }

  func testCalcNewBrightnessExtendsIntoXDRRange() {
    self.stubbedDisplay.savePref(true, key: .xdrEnabled)
    self.stubbedDisplay.stubbedBrightness = 1.0
    XCTAssertEqual(self.stubbedDisplay.calcNewBrightness(isUp: true, isSmallIncrement: false), Float(1.0625))
  }

  func testCalcNewBrightnessClampsAtXDRMax() {
    self.stubbedDisplay.savePref(true, key: .xdrEnabled)
    // Park it one chiclet below the ceiling: the next step would overshoot, so the
    // result has to be clamped to the XDR maximum rather than landing past it.
    self.stubbedDisplay.stubbedBrightness = self.stubbedDisplay.xdrMaxValue - (1 / 16.0)
    XCTAssertEqual(self.stubbedDisplay.calcNewBrightness(isUp: true, isSmallIncrement: false), self.stubbedDisplay.xdrMaxValue)
  }

  func testCalcNewBrightnessClampsAtZeroGoingDown() {
    self.stubbedDisplay.savePref(true, key: .xdrEnabled)
    self.stubbedDisplay.stubbedBrightness = 0.02
    XCTAssertEqual(self.stubbedDisplay.calcNewBrightness(isUp: false, isSmallIncrement: false), 0.0)
  }

  func testCalcNewBrightnessSupportsSmallIncrements() {
    self.stubbedDisplay.savePref(true, key: .xdrEnabled)
    self.stubbedDisplay.stubbedBrightness = 1.0
    XCTAssertEqual(self.stubbedDisplay.calcNewBrightness(isUp: true, isSmallIncrement: true), Float(1.015625))
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
