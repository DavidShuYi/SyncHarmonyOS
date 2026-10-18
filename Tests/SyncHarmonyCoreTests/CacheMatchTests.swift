// CacheMatchTests.swift — Open With cache-hit detection and overwrite download.

import XCTest
@testable import SyncHarmonyCore

final class CacheMatchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeEntry(name: String, size: UInt32, modified: Date) -> MTPObjectInfo {
        var entry = MTPObjectInfo()
        entry.filename = name
        entry.compressedSize = size
        entry.modificationDate = modified
        return entry
    }

    /// 本地副本大小与修改时间一致 → 缓存命中。
    func testMatchOnSizeAndDate() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let entry = makeEntry(name: "a.jpg", size: 500, modified: date)
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data(count: 500).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        XCTAssertTrue(entry.matchesLocalCopy(at: url))
    }

    /// 大小不一致 → 未命中。
    func testMissOnSizeMismatch() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let entry = makeEntry(name: "a.jpg", size: 500, modified: date)
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data(count: 499).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        XCTAssertFalse(entry.matchesLocalCopy(at: url))
    }

    /// 修改时间不一致 → 未命中（设备端文件已更新）。
    func testMissOnDateMismatch() throws {
        let entry = makeEntry(name: "a.jpg", size: 500,
                              modified: Date(timeIntervalSince1970: 1_760_000_000))
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data(count: 500).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path)

        XCTAssertFalse(entry.matchesLocalCopy(at: url))
    }

    /// 本地文件不存在 → 未命中。
    func testMissOnMissingFile() {
        let entry = makeEntry(name: "missing.jpg", size: 1,
                              modified: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertFalse(entry.matchesLocalCopy(at: tempDir.appendingPathComponent("missing.jpg")))
    }

    /// 超过 4 GB 时 32 位大小字段不可信（0xFFFFFFFF），仅按时间判断。
    func testHugeFileIgnoresUnreliableSize() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        var entry = makeEntry(name: "huge.mp4", size: 100, modified: date)
        entry.compressedSize = 0xFFFF_FFFF
        let url = tempDir.appendingPathComponent("huge.mp4")
        try Data(count: 4096).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)

        XCTAssertTrue(entry.matchesLocalCopy(at: url))
    }
}
