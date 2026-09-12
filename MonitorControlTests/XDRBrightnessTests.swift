//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import XCTest

@testable import LumaControl

// AppleDisplay.getBrightness() short-circuits to a constant for dummy displays, so
// calcNewBrightness tests use this stub to drive the current brightness directly.
private class StubbedBrightnessAppleDisplay: AppleDisplay {
  var stubbedBrightness: Float = 1

  override func getBrightness() -> Float {
    self.stubbedBrightness
  }
}

private final class RecordingBrightnessDisplay: Display {
  var writes: [(value: Float, isMainThread: Bool)] = []
  var onWrite: ((Float) -> Void)?

  override func applySwBrightnessValue(_ value: Float, enforceGammaActivity: Bool) -> Bool {
    self.writes.append((value, Thread.isMainThread))
    self.onWrite?(value)
    return true
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
      display?.removePref(key: .SwBrightness)
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

  func testSmoothBrightnessDoesNotAddSemaphorePermits() {
    self.otherDisplay.smoothBrightnessTransient = 0.5
    self.otherDisplay.savePref(Float(0.5), for: .brightness)

    XCTAssertTrue(self.otherDisplay.setSmoothBrightness())

    XCTAssertEqual(self.otherDisplay.swBrightnessSemaphore.wait(timeout: .now()), .success)
    defer { self.otherDisplay.swBrightnessSemaphore.signal() }
    XCTAssertEqual(self.otherDisplay.swBrightnessSemaphore.wait(timeout: .now()), .timedOut)
  }

  func testSmoothBrightnessLatestDirectRequestWins() {
    let display = RecordingBrightnessDisplay(3, name: "Recording Display", vendorNumber: 8_001, modelNumber: 4, serialNumber: 3, isDummy: true)
    display.savePref(Float(1), key: .SwBrightness)
    defer {
      display.onWrite = nil
      _ = display.setSwBrightness(1)
      display.removePref(key: .SwBrightness)
    }
    let superseded = expectation(description: "first ramp step emitted")
    let completed = expectation(description: "direct replacement completed")
    let quiet = expectation(description: "old ramp stays cancelled")
    var didReplace = false
    var writesAtEndpoint = 0
    display.onWrite = { value in
      if !didReplace {
        didReplace = true
        superseded.fulfill()
        DispatchQueue.main.async { XCTAssertTrue(display.setSwBrightness(0.8)) }
      }
      if value == display.swBrightnessTransform(value: 0.8) {
        writesAtEndpoint = display.writes.count
        completed.fulfill()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { quiet.fulfill() }
      }
    }

    XCTAssertTrue(display.setSwBrightness(0.4, smooth: true))
    wait(for: [superseded, completed, quiet], timeout: 1.0)

    XCTAssertEqual(display.writes.count, writesAtEndpoint)
    XCTAssertEqual(display.writes.last?.value ?? -1, display.swBrightnessTransform(value: 0.8), accuracy: 0.0001)
  }

  func testSmoothBrightnessLatestSmoothRequestReachesExactEndpointOnMain() {
    let display = RecordingBrightnessDisplay(4, name: "Recording Display 2", vendorNumber: 8_002, modelNumber: 5, serialNumber: 4, isDummy: true)
    display.savePref(Float(1), key: .SwBrightness)
    defer {
      display.onWrite = nil
      _ = display.setSwBrightness(1)
      display.removePref(key: .SwBrightness)
    }
    let superseded = expectation(description: "first ramp step emitted")
    let completed = expectation(description: "smooth replacement completed")
    let quiet = expectation(description: "old ramp stays cancelled")
    var didReplace = false
    var writesAtEndpoint = 0
    display.onWrite = { value in
      if !didReplace {
        didReplace = true
        superseded.fulfill()
        DispatchQueue.main.async { XCTAssertTrue(display.setSwBrightness(0.7, smooth: true)) }
      }
      if value == display.swBrightnessTransform(value: 0.7) {
        writesAtEndpoint = display.writes.count
        completed.fulfill()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { quiet.fulfill() }
      }
    }

    XCTAssertTrue(display.setSwBrightness(0.4, smooth: true))
    wait(for: [superseded, completed, quiet], timeout: 1.0)

    XCTAssertFalse(display.writes.isEmpty)
    XCTAssertEqual(display.writes.count, writesAtEndpoint)
    XCTAssertEqual(display.writes.last?.value ?? -1, display.swBrightnessTransform(value: 0.7), accuracy: 0.0001)
    XCTAssertTrue(display.writes.allSatisfy { $0.isMainThread })
  }

  func testSmoothBrightnessWithNoDistanceWritesExactValueOnce() {
    let display = RecordingBrightnessDisplay(5, name: "Recording Display 3", vendorNumber: 8_003, modelNumber: 6, serialNumber: 5, isDummy: true)
    display.savePref(Float(0.5), key: .SwBrightness)
    defer {
      display.onWrite = nil
      _ = display.setSwBrightness(1)
      display.removePref(key: .SwBrightness)
    }
    let completed = expectation(description: "zero-distance write completed")
    display.onWrite = { _ in completed.fulfill() }

    XCTAssertTrue(display.setSwBrightness(0.5, smooth: true))
    wait(for: [completed], timeout: 1.0)

    XCTAssertEqual(display.writes.count, 1)
    guard let write = display.writes.first else {
      return XCTFail("Expected one smooth brightness write")
    }
    XCTAssertEqual(write.value, display.swBrightnessTransform(value: 0.5), accuracy: 0.0001)
  }

  func testSmoothBrightnessCancelsDuringReconfiguration() {
    let display = RecordingBrightnessDisplay(6, name: "Recording Display 4", vendorNumber: 8_004, modelNumber: 7, serialNumber: 6, isDummy: true)
    display.savePref(Float(1), key: .SwBrightness)
    let previousReconfigureID = app.reconfigureID
    defer {
      display.onWrite = nil
      _ = display.setSwBrightness(1)
      app.reconfigureID = previousReconfigureID
      display.removePref(key: .SwBrightness)
    }
    app.reconfigureID = 1

    XCTAssertTrue(display.setSwBrightness(0.4, smooth: true))
    let settled = expectation(description: "cancellation callback settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { settled.fulfill() }
    wait(for: [settled], timeout: 1.0)
    XCTAssertTrue(display.writes.isEmpty)
  }

  func testSmoothBrightnessCancelsDuringSleep() {
    let display = RecordingBrightnessDisplay(7, name: "Recording Display 5", vendorNumber: 8_005, modelNumber: 8, serialNumber: 7, isDummy: true)
    display.savePref(Float(1), key: .SwBrightness)
    let previousSleepID = app.sleepID
    defer {
      display.onWrite = nil
      _ = display.setSwBrightness(1)
      app.sleepID = previousSleepID
      display.removePref(key: .SwBrightness)
    }
    app.sleepID = 1

    XCTAssertTrue(display.setSwBrightness(0.4, smooth: true))
    let settled = expectation(description: "sleep cancellation callback settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { settled.fulfill() }
    wait(for: [settled], timeout: 1.0)
    XCTAssertTrue(display.writes.isEmpty)
  }
}
