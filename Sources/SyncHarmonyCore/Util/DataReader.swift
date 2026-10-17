// DataReader.swift — little-endian cursor over PTP/MTP datasets.
// PTP datasets are little-endian per ISO 15740 / USB Still Image class spec.

import Foundation

/// Thrown when a dataset ends before all requested fields were parsed.
public struct MTPParseError: Error, CustomStringConvertible {
    public let field: String
    public init(_ field: String) { self.field = field }
    public var description: String { "malformed MTP dataset: ran out of bytes reading \(field)" }
}

/// Sequential little-endian reader over an in-memory buffer.
/// MTP datasets are small (KBs), so the buffer is materialized in memory.
public struct DataReader {
    public let data: [UInt8]
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = [UInt8](data)
        self.offset = 0
    }

    public var remaining: Int { data.count - offset }

    public mutating func u8(_ field: String = #function) throws -> UInt8 {
        guard remaining >= 1 else { throw MTPParseError(field) }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func u16(_ field: String = #function) throws -> UInt16 {
        guard remaining >= 2 else { throw MTPParseError(field) }
        defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    public mutating func u32(_ field: String = #function) throws -> UInt32 {
        guard remaining >= 4 else { throw MTPParseError(field) }
        defer { offset += 4 }
        let b = data[(offset + 1)...(offset + 3)] + [data[offset]]
        _ = b
        let v = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        return v
    }

    public mutating func u64(_ field: String = #function) throws -> UInt64 {
        guard remaining >= 8 else { throw MTPParseError(field) }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(data[offset + i])
        }
        return v
    }

    /// PTP string: one byte char count (including the terminator) followed by
    /// UTF-16LE code units. The stored terminator is dropped.
    public mutating func ptpString(_ field: String = #function) throws -> String {
        let count = Int(try u8(field))
        guard remaining >= count * 2 else { throw MTPParseError(field) }
        defer { offset += count * 2 }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for i in 0..<count {
            let base = offset + i * 2
            let lo = data[base]
            let hi = data[base + 1]
            units.append(UInt16(lo) | (UInt16(hi) << 8))
        }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// PTP array of uint16: uint32 element count followed by elements.
    public mutating func u16Array(_ field: String = #function) throws -> [UInt16] {
        let count = Int(try u32(field))
        guard remaining >= count * 2 else { throw MTPParseError(field) }
        var out: [UInt16] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try u16(field)) }
        return out
    }

    /// PTP array of uint32: uint32 element count followed by elements.
    public mutating func u32Array(_ field: String = #function) throws -> [UInt32] {
        let count = Int(try u32(field))
        guard remaining >= count * 4 else { throw MTPParseError(field) }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try u32(field)) }
        return out
    }
}

/// Little-endian writer used to build request containers and ObjectInfo datasets.
public struct DataWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8(v >> 8))
    }
    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8(v >> 24))
    }
    public mutating func u64(_ v: UInt64) {
        u32(UInt32(v & 0xFFFFFFFF))
        u32(UInt32(v >> 32))
    }

    public mutating func ptpString(_ s: String) {
        let units = Array(s.utf16)
        u8(UInt8((units.count + 1) & 0xFF))
        for u in units {
            u16(u)
        }
        u16(0) // NUL terminator is part of the PTP string encoding
    }

    public mutating func u16Array(_ values: [UInt16]) {
        u32(UInt32(values.count))
        values.forEach { u16($0) }
    }

    public mutating func u32Array(_ values: [UInt32]) {
        u32(UInt32(values.count))
        values.forEach { u32($0) }
    }

    public var data: Data { Data(bytes) }
}
