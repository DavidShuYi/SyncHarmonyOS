//
//  File:    OpenCacheJanitorTests.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// OpenCacheJanitorTests.swift — cache retention policy behavior.

import XCTest
@testable import SyncHarmonyCore

final class OpenCacheJanitorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("janitor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func createFile(_ name: String, size: Int, modifiedDaysAgo: Double) throws {
        let url = tempDir.appendingPathComponent(name)
        let data = Data(count: size)
        try data.write(to: url)
        let date = Date().addingTimeInterval(-modifiedDaysAgo * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func remainingNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
    }

    /// 超过保留期的文件被删除，未过期的保留。
    func testAgePurge() throws {
        try createFile("ancient.txt", size: 10, modifiedDaysAgo: 8)
        try createFile("recent.txt", size: 10, modifiedDaysAgo: 1)

        let result = OpenCacheJanitor.clean(directory: tempDir,
                                            maxAge: 7 * 24 * 3600,
                                            maxTotalBytes: .max)

        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(try remainingNames(), ["recent.txt"])
    }

    /// 总量超限时从最旧的文件开始删除，直到降到限额内。
    /// 1000 B 总量 → 删最旧的 600 B 后剩 400 B ≤ 500 B 上限，停止。
    func testSizeCapEvictsOldestFirst() throws {
        try createFile("oldest.bin", size: 600, modifiedDaysAgo: 3)
        try createFile("middle.bin", size: 300, modifiedDaysAgo: 2)
        try createFile("newest.bin", size: 100, modifiedDaysAgo: 1)

        let result = OpenCacheJanitor.clean(directory: tempDir,
                                            maxAge: 7 * 24 * 3600,
                                            maxTotalBytes: 500)

        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(try remainingNames(), ["middle.bin", "newest.bin"])
        XCTAssertEqual(result.freedBytes, 600)
    }

    /// 未超限的目录不做任何删除。
    func testNoOpUnderLimits() throws {
        try createFile("keep.bin", size: 100, modifiedDaysAgo: 1)
        let result = OpenCacheJanitor.clean(directory: tempDir,
                                            maxAge: 7 * 24 * 3600,
                                            maxTotalBytes: 1_000)
        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertEqual(try remainingNames(), ["keep.bin"])
    }

    /// 目录不存在时安全返回。
    func testMissingDirectoryIsSafe() {
        let missing = tempDir.appendingPathComponent("nope")
        let result = OpenCacheJanitor.clean(directory: missing)
        XCTAssertEqual(result.removedFiles, 0)
    }
}
