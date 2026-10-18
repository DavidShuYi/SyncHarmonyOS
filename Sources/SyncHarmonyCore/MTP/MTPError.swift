//
//  File:    MTPError.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// MTPError.swift — typed errors surfaced to CLI and GUI.

import Foundation

/// Top-level error type for SyncHarmonyOS.
public enum MTPError: Error, CustomStringConvertible, LocalizedError {
    /// The device answered with a non-OK response code.
    case deviceResponse(code: UInt16, operation: String)
    /// USB / framing level failure.
    case io(String)
    /// Another application owns the USB interface.
    case deviceBusy
    /// No MTP-capable device is attached (or the phone is not in file-transfer mode).
    case noDevice
    /// The session was closed because the device disappeared.
    case disconnected
    /// Local file problem (missing, unreadable, destination not writable).
    case fileSystem(String)
    /// The caller cancelled the transfer.
    case cancelled

    public var description: String {
        switch self {
        case let .deviceResponse(code, operation):
            return "设备返回错误(\(operation)): \(ResponseCode.name(code)) [\(String(format: "0x%04X", code))]"
        case let .io(message):
            return "USB 通信失败: \(message)"
        case .deviceBusy:
            return "设备被占用：请先退出 Android File Transfer、MacDroid 等其他 MTP 应用后重试"
        case .noDevice:
            return "未发现 MTP 设备：请用数据线连接手机，并在手机上选择「传输文件」模式"
        case .disconnected:
            return "设备已断开连接"
        case let .fileSystem(message):
            return "本地文件错误: \(message)"
        case .cancelled:
            return "传输已取消"
        }
    }

    public var errorDescription: String? { description }
}
