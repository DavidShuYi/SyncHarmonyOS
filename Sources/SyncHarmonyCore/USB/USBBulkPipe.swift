// USBBulkPipe.swift — abstract bulk transport surface used by PTPTransport.
// Splitting the protocol from the IOKit implementation keeps the MTP stack
// unit-testable with an in-memory pipe.

import Foundation

/// A pair of USB bulk endpoints (IN/OUT) plus their packet size limits.
public protocol USBBulkPipe: AnyObject {
    /// Max packet size of the bulk IN endpoint (device → host).
    var inMaxPacket: Int { get }
    /// Max packet size of the bulk OUT endpoint (host → device).
    var outMaxPacket: Int { get }

    /// Write exactly `data.count` bytes to the bulk OUT endpoint.
    func write(_ data: Data) throws

    /// Read up to `maxLength` bytes from the bulk IN endpoint.
    /// Returns between 0 and `maxLength` bytes; 0 signals a zero-length packet.
    func read(maxLength: Int) throws -> Data

    /// Best-effort recovery after a protocol error: clear HALT on both pipes.
    func clearStall() throws

    func close()
}

/// Identity placeholder used by tests.
extension USBBulkPipe {
    public var debugName: String { String(describing: type(of: self)) }
}
