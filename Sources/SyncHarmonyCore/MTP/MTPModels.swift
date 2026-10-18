//
//  File:    MTPModels.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// MTPModels.swift — parsed views of MTP datasets (DeviceInfo / StorageInfo / ObjectInfo).
// Dataset layouts follow the published PTP/MTP specifications.

import Foundation

/// Result of GetDeviceInfo (0x1001).
public struct MTPDeviceInfo: Equatable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionDesc: String
    public var operationsSupported: [UInt16]
    public var eventsSupported: [UInt16]
    public var devicePropertiesSupported: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init() {
        standardVersion = 0
        vendorExtensionID = 0
        vendorExtensionDesc = ""
        operationsSupported = []
        eventsSupported = []
        devicePropertiesSupported = []
        manufacturer = ""
        model = ""
        deviceVersion = ""
        serialNumber = ""
    }

    public init(reading reader: inout DataReader) throws {
        standardVersion = try reader.u16()
        vendorExtensionID = try reader.u32()
        _ = try reader.u16() // VendorExtensionVersion
        vendorExtensionDesc = try reader.ptpString()
        _ = try reader.u16() // FunctionalMode
        operationsSupported = try reader.u16Array()
        eventsSupported = try reader.u16Array()
        devicePropertiesSupported = try reader.u16Array()
        _ = try reader.u16Array() // CaptureFormats
        _ = try reader.u16Array() // ImageFormats
        manufacturer = try reader.ptpString()
        model = try reader.ptpString()
        deviceVersion = try reader.ptpString()
        serialNumber = try reader.ptpString()
    }

    /// Short display name, e.g. "HUAWEI Mate 60 Pro".
    public var displayName: String {
        let name = [manufacturer, model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? "MTP 设备" : name
    }
}

/// Result of GetStorageInfo (0x1005).
public struct MTPStorage: Equatable, Identifiable {
    public var storageID: UInt32
    public var storageType: UInt16
    public var fileSystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpaceInBytes: UInt64
    public var description: String
    public var volumeLabel: String

    public init() {
        storageID = 0
        storageType = 0
        fileSystemType = 0
        accessCapability = 0
        maxCapacity = 0
        freeSpaceInBytes = 0
        description = ""
        volumeLabel = ""
    }

    /// Parse a StorageInfo dataset. PTP packs the capacity fields as uint32;
    /// the MTP specification widened them to uint64. Devices follow the
    /// layout matching their vendor extension, so try MTP first (with a
    /// sanity bound on the 64-bit values) and fall back to the PTP layout.
    public static func parse(storageID: UInt32, from data: Data) throws -> MTPStorage {
        var mtpReader = DataReader(data)
        if let storage = try? parseMTPLayout(storageID: storageID, reader: &mtpReader),
           storage.maxCapacity < 1_000_000_000_000_000 { // sanity: < 1 PB
            return storage
        }
        var ptpReader = DataReader(data)
        return try parsePTPLayout(storageID: storageID, reader: &ptpReader)
    }

    public init(storageID: UInt32, reading reader: inout DataReader) throws {
        // Convenience path used by tests and simple callers; assumes the
        // 64-bit MTP layout.
        self.init()
        self.storageID = storageID
        storageType = try reader.u16()
        fileSystemType = try reader.u16()
        accessCapability = try reader.u16()
        maxCapacity = try reader.u64()
        freeSpaceInBytes = try reader.u64()
        _ = try reader.u32() // FreeSpaceInImages
        description = try reader.ptpString()
        volumeLabel = try reader.ptpString()
    }

    private static func parseMTPLayout(storageID: UInt32, reader: inout DataReader) throws -> MTPStorage {
        var storage = MTPStorage()
        storage.storageID = storageID
        storage.storageType = try reader.u16()
        storage.fileSystemType = try reader.u16()
        storage.accessCapability = try reader.u16()
        storage.maxCapacity = try reader.u64()
        storage.freeSpaceInBytes = try reader.u64()
        _ = try reader.u32() // FreeSpaceInImages
        storage.description = try reader.ptpString()
        storage.volumeLabel = try reader.ptpString()
        return storage
    }

    private static func parsePTPLayout(storageID: UInt32, reader: inout DataReader) throws -> MTPStorage {
        var storage = MTPStorage()
        storage.storageID = storageID
        storage.storageType = try reader.u16()
        storage.fileSystemType = try reader.u16()
        storage.accessCapability = try reader.u16()
        storage.maxCapacity = UInt64(try reader.u32())
        storage.freeSpaceInBytes = UInt64(try reader.u32())
        _ = try reader.u32() // FreeSpaceInImages
        storage.description = try reader.ptpString()
        storage.volumeLabel = try reader.ptpString()
        return storage
    }

    public var id: UInt32 { storageID }

    /// Human label shown in the sidebar: description falls back to volume label.
    public var displayName: String {
        let label = description.isEmpty ? volumeLabel : description
        return label.isEmpty ? "存储 \(String(format: "%08X", storageID))" : label
    }

    public var isReadOnly: Bool { accessCapability == 0x0001 } // Read-Only
}

/// Result of GetObjectInfo (0x1008) for one file or folder.
public struct MTPObjectInfo: Equatable, Hashable, Identifiable {
    public var handle: UInt32
    public var storageID: UInt32
    public var objectFormat: UInt16
    public var protectionStatus: UInt16
    public var compressedSize: UInt32
    public var parentObject: UInt32
    public var associationType: UInt16
    public var filename: String
    public var modificationDate: Date?

    public init() {
        handle = 0
        storageID = 0
        objectFormat = 0
        protectionStatus = 0
        compressedSize = 0
        parentObject = 0
        associationType = 0
        filename = ""
        modificationDate = nil
    }

    public init(handle: UInt32, reading reader: inout DataReader) throws {
        self.handle = handle
        storageID = try reader.u32()
        objectFormat = try reader.u16()
        protectionStatus = try reader.u16()
        compressedSize = try reader.u32()
        _ = try reader.u16() // ThumbFormat
        _ = try reader.u32() // ThumbCompressedSize
        _ = try reader.u32() // ThumbPixWidth
        _ = try reader.u32() // ThumbPixHeight
        _ = try reader.u32() // ImagePixWidth
        _ = try reader.u32() // ImagePixHeight
        _ = try reader.u32() // ImageBitDepth
        parentObject = try reader.u32()
        associationType = try reader.u16()
        _ = try reader.u32() // AssociationDesc
        _ = try reader.u32() // SequenceNumber
        filename = try reader.ptpString()
        modificationDate = Self.parsePTPDate(try reader.ptpString())
        _ = try reader.ptpString() // Keywords
    }

    public var id: UInt32 { handle }

    public var isFolder: Bool { objectFormat == ObjectFormat.association }

    /// True when the device marks the object read-only.
    public var isReadOnly: Bool { protectionStatus == 0x0001 }

    /// Size in bytes. Prefer the MTP 64-bit ObjectSize when the caller
    /// resolved it; otherwise the 32-bit ObjectInfo field.
    public var size: UInt64 { UInt64(compressedSize) }

    /// PTP date strings look like "20240101T120000".
    static func parsePTPDate(_ s: String) -> Date? {
        guard s.count >= 15 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: s)
    }

    /// 不可空的排序键（KeyPathComparator 需要 Comparable）：
    /// 没有修改时间的对象按最早处理。
    public var sortDate: Date { modificationDate ?? .distantPast }

    /// 大小写不敏感的名称排序键（Finder 风格）。
    public var sortName: String { filename.lowercased() }

    /// Inverse of parsePTPDate, used when building datasets for upload.
    public static func formatPTPDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    /// 判断本地缓存副本是否与设备对象一致（大小 + 修改时间）。
    /// 用于"打开方式"缓存命中：一致则跳过重复下载直接打开。
    /// 超过 4 GB 时 32 位大小字段不可信（0xFFFFFFFF），只按时间判断。
    public func matchesLocalCopy(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let cachedSize = attrs[.size] as? UInt64,
              let cachedDate = attrs[.modificationDate] as? Date,
              let entryDate = modificationDate else { return false }
        if compressedSize != 0xFFFF_FFFF, cachedSize != size { return false }
        return abs(cachedDate.timeIntervalSince(entryDate)) < 60
    }

    /// Encode an ObjectInfo dataset (upload / new folder).
    public static func encode(_ info: MTPObjectInfo) -> Data {
        var w = DataWriter()
        w.u32(info.storageID)
        w.u16(info.objectFormat)
        w.u16(info.protectionStatus)
        w.u32(info.compressedSize)
        w.u16(0) // ThumbFormat
        w.u32(0) // ThumbCompressedSize
        w.u32(0) // ThumbPixWidth
        w.u32(0) // ThumbPixHeight
        w.u32(0) // ImagePixWidth
        w.u32(0) // ImagePixHeight
        w.u32(0) // ImageBitDepth
        w.u32(info.parentObject)
        w.u16(info.associationType)
        w.u32(0) // AssociationDesc
        w.u32(0) // SequenceNumber
        w.ptpString(info.filename)
        w.ptpString(Self.formatPTPDate(info.modificationDate ?? Date()))
        w.ptpString("") // Keywords
        return w.data
    }
}

/// Friendly byte count formatting shared by CLI and GUI.
public enum ByteCount {
    public static func format(_ bytes: UInt64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let tb = gb * 1024
        let v = Double(bytes)
        switch v {
        case ..<kb:
            return "\(bytes) B"
        case ..<mb:
            return String(format: "%.1f KB", v / kb)
        case ..<gb:
            return String(format: "%.1f MB", v / mb)
        case ..<tb:
            return String(format: "%.2f GB", v / gb)
        default:
            return String(format: "%.2f TB", v / tb)
        }
    }
}
