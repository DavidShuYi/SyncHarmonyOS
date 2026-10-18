//
//  File:    IOKitUSBBulkPipe.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// IOKitUSBBulkPipe.swift — USBBulkPipe backed by the CUSBShim/IOKit user client.
// One instance owns one exclusive USB interface claim.

import Foundation
import CUSBShim

/// A detected MTP-capable USB interface, as produced by the scanner.
public struct MTPUSBDeviceInfo: Identifiable, Equatable {
    /// IOKit registry entry ID; stable for the lifetime of the connection.
    public let registryEntryID: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    public let productName: String
    public let manufacturer: String
    public let serialNumber: String
    public let interfaceClass: UInt8
    public let interfaceSubClass: UInt8
    public let interfaceProtocol: UInt8

    public var id: UInt64 { registryEntryID }

    /// Fallback label when the device publishes no product string.
    public var displayName: String {
        if !productName.isEmpty { return productName }
        return String(format: "USB %04X:%04X", vendorID, productID)
    }
}

/// Scans the IOKit registry for MTP-capable USB interfaces.
public enum USBDeviceScanner {
    /// Enumerate every currently attached MTP interface.
    /// HarmonyOS/Android phones expose MTP when the user picks "传输文件" mode.
    public static func scanDevices() -> [MTPUSBDeviceInfo] {
        var list: UnsafeMutablePointer<ShimMTPDeviceInfo>?
        var count: Int32 = 0
        let kr = shimListMTPDevices(&list, &count)
        guard kr == KERN_SUCCESS, let list, count > 0 else {
            if let list { shimFreeList(list) }
            return []
        }
        defer { shimFreeList(list) }

        func field(_ info: ShimMTPDeviceInfo, _ index: Int32) -> String {
            var copy = info
            var buffer = [CChar](repeating: 0, count: 256)
            shimCopyStringField(&copy, index, &buffer, buffer.count)
            return String(cString: buffer)
        }

        var devices: [MTPUSBDeviceInfo] = []
        devices.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let info = list[i]
            devices.append(MTPUSBDeviceInfo(
                registryEntryID: info.registryEntryID,
                vendorID: info.vendorID,
                productID: info.productID,
                productName: field(info, 0),
                manufacturer: field(info, 1),
                serialNumber: field(info, 2),
                interfaceClass: info.interfaceClass,
                interfaceSubClass: info.interfaceSubClass,
                interfaceProtocol: info.interfaceProtocol
            ))
        }
        return devices
    }
}

/// Concrete pipe that talks to the CUSBShim context.
public final class IOKitUSBBulkPipe: USBBulkPipe {
    private var context: UnsafeMutableRawPointer?
    private let ioLock = NSLock()
    private var closed = false

    public let inMaxPacket: Int
    public let outMaxPacket: Int

    /// Claim the interface exclusively and locate its bulk pipe references.
    public init(registryEntryID: UInt64) throws {
        var context: UnsafeMutableRawPointer?
        var errorBuffer = [CChar](repeating: 0, count: 256)
        let kr = shimOpenByEntryID(registryEntryID, &context, &errorBuffer, errorBuffer.count)
        guard kr == KERN_SUCCESS, let context else {
            let message = String(cString: errorBuffer)
            if kr == kIOReturnExclusiveAccess { throw MTPError.deviceBusy }
            throw MTPError.io(message.isEmpty
                ? String(format: "shimOpenByEntryID: 0x%08x", kr)
                : message)
        }
        self.context = context

        var outPipe: UInt8 = 0
        var outMax: UInt16 = 0
        var inPipe: UInt8 = 0
        var inMax: UInt16 = 0
        let pipesKr = shimGetPipes(context, &outPipe, &outMax, &inPipe, &inMax)
        guard pipesKr == KERN_SUCCESS else {
            shimClose(context)
            self.context = nil
            throw MTPError.io(String(format: "shimGetPipes: 0x%08x", pipesKr))
        }
        self.inMaxPacket = Int(inMax)
        self.outMaxPacket = Int(outMax)
    }

    deinit {
        close()
    }

    /// Watchdog for bulk operations. MTP devices normally answer in under a
    /// second; 30 s covers slow flash while still unblocking a dead pipe.
    private static let ioTimeoutMs: UInt32 = 30_000

    public func write(_ data: Data) throws {
        try withRetryOnStall { context in
            let written = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
                var size = UInt32(raw.count)
                let kr = shimWrite(context, raw.baseAddress, &size, Self.ioTimeoutMs)
                guard kr == KERN_SUCCESS else { throw USBKernelError(kr) }
                return size
            }
            if Int(written) != data.count {
                throw MTPError.io("bulk short write: \(written)/\(data.count)")
            }
        }
    }

    public func read(maxLength: Int) throws -> Data {
        try withRetryOnStall { context in
            var buffer = Data(count: maxLength)
            let got = try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                var size = UInt32(raw.count)
                let kr = shimRead(context, raw.baseAddress, &size, Self.ioTimeoutMs)
                guard kr == KERN_SUCCESS else { throw USBKernelError(kr) }
                return Int(size)
            }
            buffer.removeSubrange(got..<buffer.count)
            return buffer
        }
    }

    public func clearStall() throws {
        try withLockedContext { context in
            shimClearStall(context)
        }
    }

    public func close() {
        ioLock.lock()
        defer { ioLock.unlock() }
        if let context, !closed {
            shimClose(context)
            closed = true
        }
        self.context = nil
    }

    /// Serialize all pipe I/O: MTP forbids interleaved transactions.
    private func withLockedContext<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let context, !closed else { throw MTPError.disconnected }
        return try body(context)
    }

    /// Recovery after timeout or stall: ClearPipeStallBothEnds resets the
    /// data toggle on both sides (host + device) via the USB CLEAR_FEATURE
    /// control request, then retries once. This mirrors what libusb does on
    /// the same conditions and is safe for the bus state.
    private func withRetryOnStall<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        try withLockedContext { context in
            do {
                return try body(context)
            } catch let error as USBKernelError {
                let recoverable = error.code == kIOReturnNotRespondingCode
                    || error.code == kIOReturnStallCode
                    || error.code == kIOUSBTransactionTimeoutCode
                    || error.code == kIOReturnTimeoutCode
                guard recoverable else { throw error.asMTPError }
                shimClearStall(context)
                do {
                    return try body(context)
                } catch {
                    throw (error as? USBKernelError)?.asMTPError ?? error
                }
            }
        }
    }
}

/// Raw kern result wrapper so the retry layer can inspect the code.
struct USBKernelError: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
    var asMTPError: MTPError {
        if code == kIOReturnTimeoutCode {
            return MTPError.io("bulk 传输超时（设备无响应），请重新插拔数据线后重试")
        }
        if code == kIOReturnNotRespondingCode || code == kIOReturnStallCode {
            return MTPError.io("设备停止响应（端点停顿），请重新插拔数据线或解锁手机后重试")
        }
        return MTPError.io(String(format: "USB I/O: 0x%08x", code))
    }
}

/// kern_return_t values used for stall recovery.
private let kIOReturnExclusiveAccess = Int32(bitPattern: 0xe000_02c5)
private let kIOReturnTimeoutCode = Int32(bitPattern: 0xe000_02f1)
private let kIOReturnNotRespondingCode = Int32(bitPattern: 0xe000_02d6)
private let kIOReturnStallCode = Int32(bitPattern: 0xe000_0400)
private let kIOUSBTransactionTimeoutCode = Int32(bitPattern: 0xe000_4051)
