// ObjectInfoTests.swift — ObjectInfo dataset encode/decode and date handling.

import XCTest
@testable import SyncHarmonyCore

final class ObjectInfoTests: XCTestCase {
    func testParseDeviceDataset() throws {
        var w = DataWriter()
        w.u16(0x0100)             // StandardVersion
        w.u32(0xFFFFFFFF)         // VendorExtensionID (MTP)
        w.u16(0x0100)             // VendorExtensionVersion
        w.ptpString("microsoft.com/MTP: 1.0;")
        w.u16(0)                  // FunctionalMode
        w.u16Array([0x1001, 0x1002, 0x1004])
        w.u16Array([0x4002])
        w.u16Array([0xD402])
        w.u16Array([])
        w.u16Array([0x3000])
        w.ptpString("HUAWEI")
        w.ptpString("Mate 60 Pro")
        w.ptpString("1.0")
        w.ptpString("SN123456")

        var reader = DataReader(w.data)
        let info = try MTPDeviceInfo(reading: &reader)

        XCTAssertEqual(info.standardVersion, 0x0100)
        XCTAssertEqual(info.vendorExtensionID, 0xFFFFFFFF)
        XCTAssertEqual(info.vendorExtensionDesc, "microsoft.com/MTP: 1.0;")
        XCTAssertEqual(info.operationsSupported, [0x1001, 0x1002, 0x1004])
        XCTAssertEqual(info.manufacturer, "HUAWEI")
        XCTAssertEqual(info.model, "Mate 60 Pro")
        XCTAssertEqual(info.displayName, "HUAWEI Mate 60 Pro")
        XCTAssertEqual(info.serialNumber, "SN123456")
    }

    func testObjectInfoRoundTrip() throws {
        var info = MTPObjectInfo()
        info.storageID = 0x00010001
        info.objectFormat = ObjectFormat.jpeg
        info.protectionStatus = 0
        info.compressedSize = 123_456
        info.parentObject = 0x0000ABCD
        info.associationType = 0
        info.filename = "IMG_2026.jpg"
        info.modificationDate = MTPObjectInfo.parsePTPDate("20260102T030405")

        let encoded = MTPObjectInfo.encode(info)
        var reader = DataReader(encoded)
        var decoded = try MTPObjectInfo(handle: 0x77, reading: &reader)
        decoded.handle = 0

        XCTAssertEqual(decoded.storageID, info.storageID)
        XCTAssertEqual(decoded.objectFormat, info.objectFormat)
        XCTAssertEqual(decoded.compressedSize, 123_456)
        XCTAssertEqual(decoded.parentObject, 0x0000ABCD)
        XCTAssertEqual(decoded.filename, "IMG_2026.jpg")
        XCTAssertEqual(decoded.modificationDate, info.modificationDate)
    }

    func testPTPDateFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 2
        components.hour = 3; components.minute = 4; components.second = 5
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let formatted = MTPObjectInfo.formatPTPDate(date)
        XCTAssertEqual(formatted.count, 15)
        XCTAssertTrue(formatted.contains("T"))
    }

    func testFolderDetection() {
        var folder = MTPObjectInfo()
        folder.objectFormat = ObjectFormat.association
        XCTAssertTrue(folder.isFolder)
        var file = MTPObjectInfo()
        file.objectFormat = ObjectFormat.jpeg
        XCTAssertFalse(file.isFolder)
    }

    func testFormatMapping() {
        XCTAssertEqual(ObjectFormat.forFileExtension("jpg"), ObjectFormat.jpeg)
        XCTAssertEqual(ObjectFormat.forFileExtension("PNG"), ObjectFormat.png)
        XCTAssertEqual(ObjectFormat.forFileExtension("mp4"), ObjectFormat.mp4)
        XCTAssertEqual(ObjectFormat.forFileExtension("xyz"), ObjectFormat.undefined)
    }
}
