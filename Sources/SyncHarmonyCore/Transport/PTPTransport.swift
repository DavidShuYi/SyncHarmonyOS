//
//  File:    PTPTransport.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// PTPTransport.swift — raw PTP container framing over USB bulk endpoints.
//
// MTP over USB does not use mass-storage BOT wrappers (CBW/CSW). Requests,
// data and responses travel as self-describing PTP containers on the two
// bulk endpoints, per the USB Still Image class specification:
//
//   container := length:u32 | type:u16 | code:u16 | transactionID:u32 | payload
//
//   host → device  type 0x0001 (operation request, 12 + 4*N bytes)
//   host → device  type 0x0002 (data; header followed by payload)
//   device → host  type 0x0002 (data)
//   device → host  type 0x0003 (response, up to 12 + 20 bytes)
//
// Devices signal end-of-data with a short packet; when the last packet is
// exactly a max-packet multiple a zero-length packet is used instead, so both
// directions must tolerate and emit zero-length packets.

import Foundation

/// Streams data-phase chunks out of the transport without buffering whole files.
public typealias DataChunkSink = (Data) throws -> Void

/// Supplies data-phase payload chunks without materializing whole files.
public protocol DataChunkSource {
    /// Read up to `maxLength` bytes; 0 signals end of source.
    func next(maxLength: Int) throws -> Data
}

/// In-memory source used for small payloads (ObjectInfo datasets).
public final class MemoryChunkSource: DataChunkSource {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    public func next(maxLength: Int) throws -> Data {
        let end = min(offset + maxLength, data.count)
        guard offset < end else { return Data() }
        let chunk = data.subdata(in: offset..<end)
        offset = end
        return chunk
    }
}

/// File-backed source that streams uploads from disk.
public final class FileChunkSource: DataChunkSource {
    private let handle: FileHandle
    private let totalLength: UInt64
    private var remaining: UInt64

    public init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else { return nil }
        self.handle = handle
        self.totalLength = size
        self.remaining = size
    }

    /// Number of bytes this source will deliver.
    public var length: UInt64 { totalLength }

    public func next(maxLength: Int) throws -> Data {
        guard remaining > 0 else { return Data() }
        let want = min(UInt64(maxLength), remaining)
        guard let chunk = try handle.read(upToCount: Int(want)) else { return Data() }
        remaining -= UInt64(chunk.count)
        return chunk
    }

    public func close() {
        try? handle.close()
    }
}

public struct PTPResponse {
    public var code: UInt16
    public var params: [UInt32]
}

/// Serializes PTP transactions over a USBBulkPipe. One instance = one session
/// lane; MTP transactions must never interleave.
public final class PTPTransport {
    private let pipe: USBBulkPipe
    private let ioLock = NSLock()
    /// PTP requires OpenSession to carry transaction ID 0, incrementing
    /// monotonically for every following operation in the session.
    private var transactionID: UInt32 = 0
    /// Transaction of the most recent request; the data phase of the same
    /// operation must reuse it.
    private var lastRequestTransaction: UInt32 = 0

    /// Chunk size for streaming transfers. 16 KiB matches the pacing Windows
    /// Media Player uses and is accepted by every MTP device tested in practice.
    public var chunkSize = 16 * 1024

    /// Set SHO_TRACE=1 to log every container on stderr.
    private static let traceEnabled = ProcessInfo.processInfo.environment["SHO_TRACE"] == "1"

    private static func trace(_ line: @autoclosure () -> String) {
        guard traceEnabled else { return }
        FileHandle.standardError.write(Data((line() + "\n").utf8))
    }

    public init(pipe: USBBulkPipe) {
        self.pipe = pipe
    }

    // MARK: - Requests

    /// Send an operation request container. Returns the transaction ID used.
    @discardableResult
    public func sendRequest(code: UInt16, params: [UInt32]) throws -> UInt32 {
        ioLock.lock()
        defer { ioLock.unlock() }
        // OpenSession starts at 0; every later operation increments.
        let tx = transactionID
        transactionID = transactionID &+ 1
        lastRequestTransaction = tx

        var w = DataWriter()
        w.u32(UInt32(containerHeaderLength + 4 * params.count))
        w.u16(ContainerType.operationRequest)
        w.u16(code)
        w.u32(tx)
        params.forEach { w.u32($0) }

        Self.trace("→ REQ code=0x\(String(code, radix: 16)) tx=\(tx) params=\(params)")
        try pipe.write(w.data)
        return tx
    }

    // MARK: - Data phase (device → host)

    /// Receive the whole data phase into memory. Only for small datasets
    /// (device info, storage info, object info).
    public func receiveData(expectedCode: UInt16, expectedTransaction tx: UInt32) throws -> Data {
        var sink: [UInt8] = []
        try receiveData(expectedCode: expectedCode, expectedTransaction: tx) { chunk in
            sink.append(contentsOf: chunk)
        }
        return Data(sink)
    }

    /// Stream the data phase into `sink`, chunk by chunk.
    /// Verifies the container header (type/code/transaction) before streaming.
    public func receiveData(expectedCode: UInt16, expectedTransaction tx: UInt32,
                            sink: DataChunkSink) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        try receiveDataLocked(expectedCode: expectedCode, expectedTransaction: tx, sink: sink)
    }

    private func receiveDataLocked(expectedCode: UInt16, expectedTransaction tx: UInt32,
                                   sink: DataChunkSink) throws {
        // First read: usually header + first payload bytes together; some
        // devices split the 12-byte header into its own transfer.
        var header = try readUpTo(chunkSize, allowZero: false)
        if header.count < containerHeaderLength {
            header = try readUpTo(chunkSize, allowZero: false)
        }
        guard header.count >= containerHeaderLength else {
            throw MTPError.io("data phase: short header (\(header.count) bytes)")
        }

        var reader = DataReader(header)
        let totalLength = try reader.u32()
        let type = try reader.u16()
        let code = try reader.u16()
        let rxTx = try reader.u32()

        Self.trace("← DATA type=0x\(String(type, radix: 16)) code=0x\(String(code, radix: 16)) tx=\(rxTx) len=\(totalLength)")

        guard type == ContainerType.data else {
            // The device answered with the response early (error path):
            // surface its response code instead of a framing error.
            if type == ContainerType.response {
                throw MTPError.deviceResponse(code: code, operation: "data phase")
            }
            throw MTPError.io("data phase: unexpected container type 0x\(String(type, radix: 16))")
        }
        guard code == expectedCode else {
            throw MTPError.io("data phase: container code \(String(format: "0x%04X", code)) != \(String(format: "0x%04X", expectedCode))")
        }
        guard rxTx == tx else {
            throw MTPError.io("data phase: transaction id \(rxTx) != \(tx)")
        }
        guard totalLength >= UInt32(containerHeaderLength) else {
            throw MTPError.io("data phase: bogus container length \(totalLength)")
        }

        // Bytes after the header in the first read belong to the payload.
        var headerPayload = header[containerHeaderLength...]
        var received: UInt64 = UInt64(headerPayload.count)
        var total: UInt64 = UInt64(totalLength) - UInt64(containerHeaderLength)

        try sink(Data(headerPayload))
        headerPayload = Data()

        var zeroReads = 0
        while received < total {
            let want = Int(min(UInt64(chunkSize), total - received))
            let chunk = try readUpTo(max(want, 1), allowZero: true)
            if chunk.isEmpty {
                // Zero-length packet: terminator when sizes align, otherwise retry.
                zeroReads += 1
                if zeroReads > 2 { break } // device ended early; lenient, matches common hosts
                continue
            }
            zeroReads = 0
            received += UInt64(chunk.count)
            try sink(chunk)
        }
    }

    // MARK: - Data phase (host → device)

    /// Stream a data phase from `source`. `payloadSize` is the pure payload
    /// length (excluding the 12-byte container header). Must immediately
    /// follow `sendRequest` for the same transaction. `onChunk` reports
    /// payload bytes streamed so far, excluding the container header.
    public func sendData(code: UInt16, payloadSize: UInt64,
                         source: DataChunkSource,
                         onChunk: ((UInt64) -> Void)? = nil) throws {
        ioLock.lock()
        defer { ioLock.unlock() }

        // The data phase belongs to the request just sent; reuse its ID.
        let tx = lastRequestTransaction
        var header = DataWriter()
        header.u32(UInt32(containerHeaderLength) &+ UInt32(truncatingIfNeeded: payloadSize))
        header.u16(ContainerType.data)
        header.u16(code)
        header.u32(tx)

        var sent: UInt64 = 0
        var first = true
        while true {
            let chunk = try source.next(maxLength: first ? max(chunkSize - containerHeaderLength, 0) : chunkSize)
            if first {
                var firstPacket = header.data
                firstPacket.append(chunk)
                try pipe.write(firstPacket)
                sent += UInt64(chunk.count)
                first = false
                onChunk?(sent)
                if chunk.isEmpty { break } // zero-length payload
                continue
            }
            if chunk.isEmpty { break }
            try pipe.write(chunk)
            sent += UInt64(chunk.count)
            onChunk?(sent)
        }

        // If the data phase ended exactly on a max-packet boundary the device
        // expects a zero-length packet as the terminator.
        let totalWire = UInt64(containerHeaderLength) + payloadSize
        if totalWire > 0, totalWire % UInt64(max(pipe.outMaxPacket, 1)) == 0 {
            try pipe.write(Data())
        }
    }

    // MARK: - Response

    /// Read the response container that ends every transaction.
    public func receiveResponse(expectedTransaction tx: UInt32) throws -> PTPResponse {
        ioLock.lock()
        defer { ioLock.unlock() }

        var packet = try readUpTo(64, allowZero: false)
        if packet.count < containerHeaderLength {
            packet = try readUpTo(64, allowZero: false)
        }
        guard packet.count >= containerHeaderLength else {
            throw MTPError.io("response: short header (\(packet.count) bytes)")
        }
        var reader = DataReader(packet)
        _ = try reader.u32() // length
        let type = try reader.u16()
        let code = try reader.u16()
        let rxTx = try reader.u32()

        guard type == ContainerType.response else {
            throw MTPError.io("response: unexpected container type 0x\(String(type, radix: 16))")
        }
        guard rxTx == tx else {
            throw MTPError.io("response: transaction id \(rxTx) != \(tx)")
        }

        Self.trace("← RESP code=0x\(String(code, radix: 16)) tx=\(rxTx)")

        var params: [UInt32] = []
        // Response containers carry up to five uint32 parameters.
        while reader.remaining >= 4, params.count < 5 {
            params.append(try reader.u32())
        }
        return PTPResponse(code: code, params: params)
    }

    // MARK: - Plumbing

    private func readUpTo(_ count: Int, allowZero: Bool) throws -> Data {
        var attempts = 0
        while true {
            let data = try pipe.read(maxLength: count)
            if data.isEmpty {
                // Zero-length packet. For reads that must deliver something,
                // tolerate a couple of ZLPs then give up.
                attempts += 1
                if allowZero || attempts > 2 { return data }
                continue
            }
            return data
        }
    }
}
