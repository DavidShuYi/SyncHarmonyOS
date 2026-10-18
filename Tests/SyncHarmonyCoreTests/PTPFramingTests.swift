//
//  File:    PTPFramingTests.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// PTPFramingTests.swift — container encode/decode round trips.

import XCTest
@testable import SyncHarmonyCore

final class PTPFramingTests: XCTestCase {
    func testWriterLittleEndianPrimitives() {
        var w = DataWriter()
        w.u8(0xA5)
        w.u16(0x1234)
        w.u32(0x89ABCDEF)
        w.u64(0x0123456789ABCDEF)
        XCTAssertEqual(w.bytes,
                       [0xA5,
                        0x34, 0x12,
                        0xEF, 0xCD, 0xAB, 0x89,
                        0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01])
    }

    func testPTPStringRoundTrip() throws {
        var w = DataWriter()
        w.ptpString("DCIM")
        w.ptpString("相册 中文")
        w.ptpString("")

        var r = DataReader(w.data)
        XCTAssertEqual(try r.ptpString(), "DCIM")
        XCTAssertEqual(try r.ptpString(), "相册 中文")
        XCTAssertEqual(try r.ptpString(), "")
        XCTAssertEqual(r.remaining, 0)
    }

    func testU16ArrayRoundTrip() throws {
        var w = DataWriter()
        w.u16Array([0x1001, 0x1002, 0x9803])
        var r = DataReader(w.data)
        XCTAssertEqual(try r.u16Array(), [0x1001, 0x1002, 0x9803])
    }

    func testReaderBoundsCheck() {
        var r = DataReader(Data([0x01, 0x02]))
        XCTAssertThrowsError(try r.u32())
    }

    func testContainerHeaderLengthMatchesSpec() {
        // length(4) + type(2) + code(2) + transaction(4)
        XCTAssertEqual(containerHeaderLength, 12)
    }
}
