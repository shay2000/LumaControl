//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import XCTest

@testable import LumaControl

final class IntelDDCTests: XCTestCase {
  func testDecodeDDCWordPreservesBothBytes() {
    let cases: [(UInt8, UInt8, UInt16)] = [
      (0x00, 0x00, 0x0000),
      (0x00, 0x64, 0x0064),
      (0x01, 0x00, 0x0100),
      (0x12, 0x34, 0x1234),
      (0xFF, 0xFF, 0xFFFF),
    ]

    for (high, low, expected) in cases {
      XCTAssertEqual(IntelDDC.decodeDDCWord(high: high, low: low), expected)
    }
  }
}
