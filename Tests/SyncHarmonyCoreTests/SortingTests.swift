//
//  File:    SortingTests.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// SortingTests.swift — default sort order and sort keys.

import XCTest
@testable import SyncHarmonyCore

final class SortingTests: XCTestCase {
    private func makeEntry(_ name: String, date: Date? = nil, size: UInt32 = 0) -> MTPObjectInfo {
        var entry = MTPObjectInfo()
        entry.filename = name
        entry.modificationDate = date
        entry.compressedSize = size
        return entry
    }

    /// 默认排序：修改时间倒序；无时间的对象排最后。
    func testDefaultSortIsDateDescending() {
        let old = makeEntry("old.txt", date: Date(timeIntervalSince1970: 100))
        let new = makeEntry("new.txt", date: Date(timeIntervalSince1970: 300))
        let noDate = makeEntry("nodate.txt")

        let sorted = [old, noDate, new].sorted(using: [
            KeyPathComparator(\MTPObjectInfo.sortDate, order: .reverse)
        ])
        XCTAssertEqual(sorted.map(\.filename), ["new.txt", "old.txt", "nodate.txt"])
    }

    /// 同名时间按大小升序排序。
    func testSortBySizeAscending() {
        let a = makeEntry("a.bin", size: 300)
        let b = makeEntry("b.bin", size: 100)
        let c = makeEntry("c.bin", size: 200)
        let sorted = [a, b, c].sorted(using: [KeyPathComparator(\MTPObjectInfo.size)])
        XCTAssertEqual(sorted.map(\.filename), ["b.bin", "c.bin", "a.bin"])
    }

    /// 按名称排序（大小写不敏感）。
    func testSortByName() {
        let entries = [makeEntry("doc.pdf"), makeEntry("album"), makeEntry("Backup")]
        let sorted = entries.sorted(using: [KeyPathComparator(\MTPObjectInfo.sortName)])
        XCTAssertEqual(sorted.map(\.filename), ["album", "Backup", "doc.pdf"])
    }

    /// 视频格式码识别。
    func testVideoFormatDetection() {
        XCTAssertTrue(ObjectFormat.isVideo(ObjectFormat.mp4))
        XCTAssertTrue(ObjectFormat.isVideo(ObjectFormat.threeGP))
        XCTAssertTrue(ObjectFormat.isVideo(ObjectFormat.avi))
        XCTAssertFalse(ObjectFormat.isVideo(ObjectFormat.jpeg))
        XCTAssertFalse(ObjectFormat.isVideo(ObjectFormat.association))
    }

    /// 图片格式码识别。
    func testImageFormatDetection() {
        XCTAssertTrue(ObjectFormat.isImage(ObjectFormat.jpeg))
        XCTAssertTrue(ObjectFormat.isImage(ObjectFormat.heif))
        XCTAssertFalse(ObjectFormat.isImage(ObjectFormat.mp4))
    }
}
