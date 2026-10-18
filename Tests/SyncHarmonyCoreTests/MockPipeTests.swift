//
//  File:    MockPipeTests.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// MockPipeTests.swift — full-session tests against a simulated MTP device.
// The mock device answers raw PTP containers exactly like the wire protocol
// describes, so request framing, transaction IDs, streaming and response
// handling are all covered without hardware.

import XCTest
@testable import SyncHarmonyCore

/// Simulated MTP device: one in-queue and one out-queue of USB packets.
final class MockMTPPipe: USBBulkPipe {
    let inMaxPacket = 512
    let outMaxPacket = 512

    /// Bytes the host wrote to us (bulk OUT), unframed packet stream.
    private(set) var receivedFromHost: [UInt8] = []
    /// Packets waiting for the host on bulk IN.
    private var queuedIn: [Data] = []

    /// Handler that, given the raw request container bytes, appends the
    /// device's scripted data/response packets to `queuedIn`.
    var onRequest: ([UInt8], MockMTPPipe) -> Void = { _, _ in }

    func write(_ data: Data) throws {
        receivedFromHost.append(contentsOf: data)
        // A complete request container triggers the scripted device answer.
        if receivedFromHost.count >= containerHeaderLength {
            var reader = DataReader(Data(receivedFromHost))
            let length = try reader.u32()
            if receivedFromHost.count >= length {
                let container = Array(receivedFromHost[0..<Int(length)])
                receivedFromHost.removeFirst(Int(length))
                onRequest(container, self)
            }
        }
    }

    func read(maxLength: Int) throws -> Data {
        guard !queuedIn.isEmpty else { return Data() }
        let packet = queuedIn.removeFirst()
        if packet.count <= maxLength {
            return packet
        }
        // Split large scripted packets the way a real endpoint would.
        let head = packet.prefix(maxLength)
        queuedIn.insert(Data(packet.dropFirst(maxLength)), at: 0)
        return Data(head)
    }

    func clearStall() throws {}

    func close() {}

    /// Device-side helpers.
    func enqueue(_ data: Data) { queuedIn.append(data) }

    func sendResponse(code: UInt16, tx: UInt32, params: [UInt32] = []) {
        var w = DataWriter()
        w.u32(UInt32(containerHeaderLength + 4 * params.count))
        w.u16(ContainerType.response)
        w.u16(code)
        w.u32(tx)
        params.forEach { w.u32($0) }
        enqueue(w.data)
    }

    func sendData(code: UInt16, tx: UInt32, payload: Data) {
        var w = DataWriter()
        w.u32(UInt32(containerHeaderLength + payload.count))
        w.u16(ContainerType.data)
        w.u16(code)
        w.u32(tx)
        enqueue(w.data)
        enqueue(payload)
    }

    /// Parse the latest host request container.
    func parseRequest(_ raw: [UInt8]) -> (type: UInt16, code: UInt16, tx: UInt32, params: [UInt32]) {
        var reader = DataReader(Data(raw))
        _ = try! reader.u32()
        let type = try! reader.u16()
        let code = try! reader.u16()
        let tx = try! reader.u32()
        var params: [UInt32] = []
        while reader.remaining >= 4, params.count < 5 {
            params.append(try! reader.u32())
        }
        return (type, code, tx, params)
    }
}

final class MockPipeTests: XCTestCase {
    /// Full happy path: open session, list storages, browse, read ObjectInfo.
    func testSessionLifecycle() throws {
        let pipe = MockMTPPipe()

        pipe.onRequest = { raw, device in
            let req = device.parseRequest(raw)
            switch req.code {
            case Operation.openSession:
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getDeviceInfo:
                var w = DataWriter()
                w.u16(0x0100)
                w.u32(0xFFFFFFFF)
                w.u16(0x0100)
                w.ptpString("microsoft.com/MTP: 1.0;")
                w.u16(0)
                w.u16Array([0x1001])
                w.u16Array([])
                w.u16Array([])
                w.u16Array([])
                w.u16Array([])
                w.ptpString("HUAWEI")
                w.ptpString("TestPhone")
                w.ptpString("1.0")
                w.ptpString("SER42")
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getStorageIDs:
                var w = DataWriter()
                w.u32Array([0x00010001])
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getStorageInfo:
                var w = DataWriter()
                w.u16(0x0003) // fixed RAM
                w.u16(0x0002) // generic
                w.u16(0x0000) // read-write
                w.u64(128_000_000_000)
                w.u64(64_000_000_000)
                w.u32(1000)
                w.ptpString("内部存储")
                w.ptpString("")
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getObjectHandles:
                var w = DataWriter()
                w.u32Array([0x11, 0x22])
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getObjectInfo:
                let handle = req.params[0]
                var w = DataWriter()
                w.u32(0x00010001)
                w.u16(handle == 0x11 ? ObjectFormat.association : ObjectFormat.jpeg)
                w.u16(0)
                w.u32(handle == 0x11 ? 0 : 2048)
                w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
                w.u32(Handle.root)
                w.u16(handle == 0x11 ? 0x0001 : 0)
                w.u32(0); w.u32(0)
                w.ptpString(handle == 0x11 ? "DCIM" : "IMG.jpg")
                w.ptpString("20260102T030405")
                w.ptpString("")
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            default:
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            }
        }

        let session = try MTPSession(pipe: pipe)
        XCTAssertEqual(session.deviceInfo.model, "TestPhone")

        let storages = try session.listStorages()
        XCTAssertEqual(storages.count, 1)
        XCTAssertEqual(storages[0].storageID, 0x00010001)
        XCTAssertEqual(storages[0].displayName, "内部存储")

        let children = try session.listChildren(storageID: 0x00010001, parent: Handle.root)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].filename, "DCIM")
        XCTAssertTrue(children[0].isFolder)
        XCTAssertEqual(children[1].filename, "IMG.jpg")
        XCTAssertEqual(children[1].size, 2048)

        try session.close()
    }

    /// Device reports an error response → typed error surfaces.
    func testErrorResponseSurfaces() {
        let pipe = MockMTPPipe()
        pipe.onRequest = { raw, device in
            let req = device.parseRequest(raw)
            if req.code == Operation.openSession {
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            } else {
                device.sendResponse(code: 0x2002, tx: req.tx) // GeneralError
            }
        }
        XCTAssertThrowsError(try MTPSession(pipe: pipe)) { error in
            guard let mtpError = error as? MTPError,
                  case let .deviceResponse(code, _) = mtpError else {
                return XCTFail("expected deviceResponse, got \(error)")
            }
            // The device answered with GeneralError instead of a dataset;
            // surfaced either from the data phase or the response container.
            XCTAssertEqual(code, 0x2002)
        }
    }

    /// Request frames must be exact: length, type=1, code, tx, params.
    func testRequestFraming() throws {
        let pipe = MockMTPPipe()
        var seen: [UInt8]?
        pipe.onRequest = { raw, device in
            let req = device.parseRequest(raw)
            if req.code == Operation.openSession {
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            } else if req.code == Operation.getDeviceInfo {
                var w = DataWriter()
                w.u16(0x0100); w.u32(0xFFFFFFFF); w.u16(0x0100)
                w.ptpString(""); w.u16(0)
                w.u16Array([]); w.u16Array([]); w.u16Array([]); w.u16Array([]); w.u16Array([])
                w.ptpString(""); w.ptpString(""); w.ptpString(""); w.ptpString("")
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            } else if req.code == Operation.getObjectHandles {
                seen = raw
                var w = DataWriter()
                w.u32Array([])
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            }
        }
        let session = try MTPSession(pipe: pipe)
        _ = try session.listChildren(storageID: 0x00010001, parent: 0x55)

        let frame = try XCTUnwrap(seen)
        var reader = DataReader(Data(frame))
        XCTAssertEqual(try reader.u32(), 24)          // 12 + 4*3 params
        XCTAssertEqual(try reader.u16(), ContainerType.operationRequest)
        XCTAssertEqual(try reader.u16(), Operation.getObjectHandles)
        XCTAssertEqual(try reader.u32(), 2)           // third transaction: Open=0, GetDeviceInfo=1
        XCTAssertEqual(try reader.u32(), 0x00010001)  // storage
        XCTAssertEqual(try reader.u32(), 0x3000)      // format filter (undefined)
        XCTAssertEqual(try reader.u32(), 0x55)        // parent
    }

    /// Large downloads stream through many chunks with progress.
    func testLargeDownloadStreaming() throws {
        let pipe = MockMTPPipe()
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        pipe.onRequest = { raw, device in
            let req = device.parseRequest(raw)
            switch req.code {
            case Operation.openSession:
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getDeviceInfo:
                var w = DataWriter()
                w.u16(0x0100); w.u32(0xFFFFFFFF); w.u16(0x0100)
                w.ptpString(""); w.u16(0)
                w.u16Array([]); w.u16Array([]); w.u16Array([]); w.u16Array([]); w.u16Array([])
                w.ptpString(""); w.ptpString(""); w.ptpString(""); w.ptpString("")
                device.sendData(code: req.code, tx: req.tx, payload: w.data)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            case Operation.getObject:
                device.sendData(code: req.code, tx: req.tx, payload: payload)
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            default:
                device.sendResponse(code: ResponseCode.ok, tx: req.tx)
            }
        }
        let session = try MTPSession(pipe: pipe)

        var chunks = 0
        var collected = Data()
        let tx = 0 as UInt32
        _ = tx
        // Drive the transport directly for a framed data receive.
        let transport = PTPTransport(pipe: pipe)
        transport.chunkSize = 8192
        let requestTx = try transport.sendRequest(code: Operation.getObject, params: [0x99])
        try transport.receiveData(expectedCode: Operation.getObject, expectedTransaction: requestTx) { chunk in
            chunks += 1
            collected.append(chunk)
        }
        let response = try transport.receiveResponse(expectedTransaction: requestTx)

        XCTAssertEqual(response.code, ResponseCode.ok)
        XCTAssertEqual(collected, payload)
        XCTAssertGreaterThan(chunks, 30) // 300 KB / 8 KB streaming
        _ = session
    }
}
