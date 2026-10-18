//
//  File:    MTPSession.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// MTPSession.swift — high-level MTP operations on top of PTPTransport.
// Owns the session lifecycle: OpenSession → operations → CloseSession.

import Foundation

/// Progress callback: (bytesDone, bytesTotal).
public typealias ProgressHandler = (UInt64, UInt64) -> Void

/// One open MTP session with a connected device.
public final class MTPSession {
    private let transport: PTPTransport
    private let device: USBBulkPipe
    public internal(set) var deviceInfo: MTPDeviceInfo
    public private(set) var sessionOpened = false

    /// Wrap an existing pipe, open the MTP session and read device info.
    public init(pipe: USBBulkPipe) throws {
        device = pipe
        transport = PTPTransport(pipe: pipe)
        // Initialized upfront: Swift requires all stored properties be set
        // before any throwing operation in a designated initializer.
        deviceInfo = MTPDeviceInfo()

        // OpenSession takes one parameter: the session id (any nonzero value).
        let open = try runTransaction(Operation.openSession, name: "OpenSession",
                                      params: [1], hasData: false)
        guard open.code == ResponseCode.ok || open.code == ResponseCode.sessionAlreadyOpened else {
            throw MTPError.deviceResponse(code: open.code, operation: "OpenSession")
        }
        sessionOpened = true

        // GetDeviceInfo right away: callers use it for the sidebar label and
        // an early sanity check that the device speaks PTP/MTP.
        let info = try runTransaction(Operation.getDeviceInfo, name: "GetDeviceInfo",
                                      params: [], hasData: true)
        guard info.code == ResponseCode.ok, let data = info.data else {
            throw MTPError.deviceResponse(code: info.code, operation: "GetDeviceInfo")
        }
        var reader = DataReader(data)
        deviceInfo = try MTPDeviceInfo(reading: &reader)
    }

    deinit {
        try? close()
    }

    /// Close the session politely. Safe to call twice.
    public func close() throws {
        guard sessionOpened else { return }
        sessionOpened = false
        _ = try? runTransaction(Operation.closeSession, name: "CloseSession",
                                params: [], hasData: false)
        device.close()
    }

    // MARK: - Storage

    /// List storage volumes (internal storage, SD card…).
    public func listStorages() throws -> [MTPStorage] {
        let response = try runTransaction(Operation.getStorageIDs, name: "GetStorageIDs",
                                          params: [], hasData: true)
        guard response.code == ResponseCode.ok, let data = response.data else {
            throw MTPError.deviceResponse(code: response.code, operation: "GetStorageIDs")
        }
        var reader = DataReader(data)
        let ids = try reader.u32Array()
        return try ids.map { id -> MTPStorage in
            let info = try runTransaction(Operation.getStorageInfo, name: "GetStorageInfo",
                                          params: [id], hasData: true)
            guard info.code == ResponseCode.ok, let payload = info.data else {
                throw MTPError.deviceResponse(code: info.code, operation: "GetStorageInfo")
            }
            return try MTPStorage.parse(storageID: id, from: payload)
        }
    }

    // MARK: - Browsing

    /// List direct children of `parent` (use Handle.root for a storage root).
    public func listChildren(storageID: UInt32, parent: UInt32) throws -> [MTPObjectInfo] {
        let response = try runTransaction(Operation.getObjectHandles, name: "GetObjectHandles",
                                          params: [storageID, UInt32(ObjectFormat.undefined), parent],
                                          hasData: true)
        guard response.code == ResponseCode.ok, let data = response.data else {
            throw MTPError.deviceResponse(code: response.code, operation: "GetObjectHandles")
        }
        var reader = DataReader(data)
        let handles = try reader.u32Array()
        return try handles.map { handle in
            try objectInfo(handle: handle)
        }
    }

    /// Fetch one ObjectInfo dataset.
    public func objectInfo(handle: UInt32) throws -> MTPObjectInfo {
        let response = try runTransaction(Operation.getObjectInfo, name: "GetObjectInfo",
                                          params: [handle], hasData: true)
        guard response.code == ResponseCode.ok, let data = response.data else {
            throw MTPError.deviceResponse(code: response.code, operation: "GetObjectInfo")
        }
        var reader = DataReader(data)
        return try MTPObjectInfo(handle: handle, reading: &reader)
    }

    /// Resolve the 64-bit MTP ObjectSize property when the device supports it.
    /// Falls back to the 32-bit ObjectInfo size; both feed `actualSize`.
    public func objectSize(handle: UInt32, fallback: UInt32) throws -> UInt64 {
        let response = try runTransaction(Operation.getObjectPropValue,
                                          name: "GetObjectPropValue",
                                          params: [handle, UInt32(ObjectProperty.objectSize)],
                                          hasData: true)
        guard response.code == ResponseCode.ok, let data = response.data, data.count >= 6 else {
            return UInt64(fallback)
        }
        var reader = DataReader(data)
        let datatype = try reader.u16()
        if datatype == ObjectProperty.datatypeUINT64 {
            return try reader.u64()
        }
        if datatype == ObjectProperty.datatypeUINT32 {
            return UInt64(try reader.u32())
        }
        return UInt64(fallback)
    }

    // MARK: - Transfer

    /// Download an object (file) to a local URL with progress reporting.
    /// `overwrite` 允许覆盖已存在的目标（"打开方式"缓存重下场景）。
    public func download(handle: UInt32, totalSize: UInt64,
                         to destination: URL,
                         overwrite: Bool = false,
                         progress: ProgressHandler? = nil) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard overwrite else {
                throw MTPError.fileSystem("目标文件已存在: \(destination.lastPathComponent)")
            }
            try? fileManager.removeItem(at: destination)
        }
        // Create the empty target file (and parents) so the handle can open.
        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MTPError.fileSystem("无法创建目标目录: \(directory.path)")
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            throw MTPError.fileSystem("无法创建目标文件: \(destination.path)")
        }
        defer { try? output.close() }

        var done: UInt64 = 0
        let response = try runStreamingTransaction(Operation.getObject,
                                                   name: "GetObject",
                                                   params: [handle]) { [weak self] chunk in
            guard let self else { throw MTPError.disconnected }
            try output.write(contentsOf: chunk)
            done += UInt64(chunk.count)
            progress?(done, totalSize)
        }
        guard response.code == ResponseCode.ok else {
            try? fileManager.removeItem(at: destination)
            throw MTPError.deviceResponse(code: response.code, operation: "GetObject")
        }
    }

    /// Upload a local file into `parent` (Handle.root for storage root).
    /// Returns the new object handle assigned by the device.
    public func upload(fileAt source: URL, storageID: UInt32, parent: UInt32,
                       progress: ProgressHandler? = nil) throws -> UInt32 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = attributes[.size] as? UInt64, size > 0 else {
            throw MTPError.fileSystem("无法读取本地文件: \(source.lastPathComponent)")
        }
        guard let fileSource = FileChunkSource(url: source) else {
            throw MTPError.fileSystem("无法打开本地文件: \(source.path)")
        }
        defer { fileSource.close() }

        let ext = source.pathExtension
        var info = MTPObjectInfo()
        info.storageID = storageID
        info.parentObject = parent
        info.objectFormat = ObjectFormat.forFileExtension(ext)
        info.compressedSize = UInt32(clamping: size)
        info.filename = source.lastPathComponent
        info.modificationDate = attributes[.modificationDate] as? Date ?? Date()

        // Step 1 of 2: SendObjectInfo carries the metadata dataset.
        let infoResponse = try runTransaction(Operation.sendObjectInfo,
                                              name: "SendObjectInfo",
                                              params: [storageID, parent],
                                              hasData: true, dataset: MTPObjectInfo.encode(info))
        guard infoResponse.code == ResponseCode.ok, infoResponse.params.count >= 2 else {
            throw MTPError.deviceResponse(code: infoResponse.code, operation: "SendObjectInfo")
        }

        // Step 2 of 2: SendObject streams the bytes; response carries the handle.
        let sendResponse = try runStreamingSend(Operation.sendObject,
                                                name: "SendObject",
                                                params: [], source: fileSource,
                                                payloadSize: size) { doneBytes in
            // The transport already reports the running total.
            progress?(doneBytes, size)
        }
        guard sendResponse.code == ResponseCode.ok else {
            throw MTPError.deviceResponse(code: sendResponse.code, operation: "SendObject")
        }
        // Prefer the handle echoed by SendObject; some devices (Huawei)
        // return no handle in the SendObject response at all.
        return sendResponse.params.first ?? infoResponse.params[1]
    }

    /// Create an empty folder and return its handle.
    public func createFolder(named name: String, storageID: UInt32, parent: UInt32) throws -> UInt32 {
        var info = MTPObjectInfo()
        info.storageID = storageID
        info.parentObject = parent
        info.objectFormat = ObjectFormat.association
        info.associationType = 0x0001 // GenericFolder
        info.filename = name
        info.modificationDate = Date()

        let response = try runTransaction(Operation.sendObjectInfo, name: "SendObjectInfo",
                                          params: [storageID, parent],
                                          hasData: true, dataset: MTPObjectInfo.encode(info))
        guard response.code == ResponseCode.ok, response.params.count >= 2 else {
            throw MTPError.deviceResponse(code: response.code, operation: "SendObjectInfo")
        }
        return response.params[1]
    }

    /// Fetch the embedded thumbnail of an object (images only).
    /// Returns JPEG bytes, or nil when the device keeps no thumbnail
    /// (response 0x200D NoThumbnailInsideObject / 0x2010-family codes).
    public func thumbnailData(handle: UInt32) throws -> Data? {
        let response = try runTransaction(Operation.getThumbnail, name: "GetThumb",
                                          params: [handle], hasData: true)
        switch response.code {
        case ResponseCode.ok:
            break
        case ResponseCode.noThumbnailInsideObject, ResponseCode.storeNotAvailable:
            return nil
        default:
            throw MTPError.deviceResponse(code: response.code, operation: "GetThumb")
        }
        guard let data = response.data, data.count > 6 else { return nil }

        let jpegSOI = Data([0xFF, 0xD8, 0xFF])
        // Layout A (spec): thumbFormat u16 + thumbSize u32 + image bytes.
        // Layout B (seen on Huawei/OpenHarmony): the raw JPEG with no header
        // at all. Detect by SOI marker first, then fall back to the header.
        let payload = data.dropFirst(6)
        if payload.starts(with: jpegSOI) {
            return Data(payload)
        }
        var reader = DataReader(data)
        _ = try? reader.u16() // thumbFormat
        let declaredSize = (try? reader.u32()) ?? 0
        if declaredSize > 0, Int(declaredSize) <= payload.count {
            return Data(payload.prefix(Int(declaredSize)))
        }
        // Last resort: locate the JPEG SOI anywhere in the payload.
        if let soi = data.firstRange(of: jpegSOI) {
            return Data(data[soi.lowerBound...])
        }
        return nil
    }

    /// Delete a file or an empty folder.
    public func delete(handle: UInt32) throws {
        let response = try runTransaction(Operation.deleteObject, name: "DeleteObject",
                                          params: [handle, 0], hasData: false)
        guard response.code == ResponseCode.ok else {
            throw MTPError.deviceResponse(code: response.code, operation: "DeleteObject")
        }
    }

    // MARK: - Transaction plumbing

    private struct Transaction {
        var code: UInt16
        var params: [UInt32]
        var data: Data?
    }

    private func runTransaction(_ code: UInt16, name: String, params: [UInt32],
                                hasData: Bool, dataset: Data? = nil) throws -> Transaction {
        let tx = try transport.sendRequest(code: code, params: params)

        var data: Data?
        if hasData {
            if let dataset {
                // Outgoing dataset (host → device data phase).
                try transport.sendData(code: code, payloadSize: UInt64(dataset.count),
                                       source: MemoryChunkSource(dataset))
                data = nil
            } else {
                data = try transport.receiveData(expectedCode: code, expectedTransaction: tx)
            }
        }
        let response = try transport.receiveResponse(expectedTransaction: tx)
        return Transaction(code: response.code, params: response.params, data: data)
    }

    private func runStreamingTransaction(_ code: UInt16, name: String, params: [UInt32],
                                         sink: DataChunkSink) throws -> PTPResponse {
        let tx = try transport.sendRequest(code: code, params: params)
        try transport.receiveData(expectedCode: code, expectedTransaction: tx, sink: sink)
        return try transport.receiveResponse(expectedTransaction: tx)
    }

    private func runStreamingSend(_ code: UInt16, name: String, params: [UInt32],
                                  source: DataChunkSource, payloadSize: UInt64,
                                  onChunk: @escaping (UInt64) -> Void) throws -> PTPResponse {
        let tx = try transport.sendRequest(code: code, params: params)
        // Data phase uses the transaction from the request just sent.
        try transport.sendData(code: code, payloadSize: payloadSize,
                               source: source, onChunk: onChunk)
        return try transport.receiveResponse(expectedTransaction: tx)
    }
}

extension URL {
    /// Creates parent directories so a FileHandle(forWritingTo:) can open.
    func enforcingParentExists() -> URL {
        let dir = deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return self
    }
}
