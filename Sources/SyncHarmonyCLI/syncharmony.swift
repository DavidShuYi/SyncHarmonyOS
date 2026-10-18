//
//  File:    syncharmony.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// syncharmony.swift — command-line front end. Useful for validating device
// connectivity without launching the GUI.

import Foundation
import SyncHarmonyCore

/// Navigation helper: resolve "内部存储/DCIM/Camera" style paths to handles.
public enum MTPPathResolver {
    /// Resolve a "/"-separated path from a storage root to a parent handle
    /// plus the object at the end of the path (when it exists).
    public static func resolve(_ path: String, session: MTPSession,
                               storageID: UInt32) throws -> (parent: UInt32, object: MTPObjectInfo?) {
        var parent: UInt32 = Handle.root
        var found: MTPObjectInfo?
        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        for component in components {
            let children = try session.listChildren(storageID: storageID, parent: parent)
            guard let match = children.first(where: { $0.filename.compare(component, options: .caseInsensitive) == .orderedSame }) else {
                throw MTPError.fileSystem("路径不存在: \(path)")
            }
            parent = match.handle
            found = match
        }
        return (parent, found)
    }
}

/// Parse "STORAGE:path" (default storage when omitted).
struct DevicePath {
    let storageAlias: String?
    let path: String

    static func parse(_ argument: String) -> DevicePath {
        if let range = argument.range(of: ":") {
            return DevicePath(storageAlias: String(argument[..<range.lowerBound]),
                              path: String(argument[argument.index(after: range.lowerBound)...]))
        }
        return DevicePath(storageAlias: nil, path: argument)
    }
}

@main
struct SyncHarmonyCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try run(arguments)
        } catch let error as MTPError {
            FileHandle.standardError.write(Data("错误: \(error)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("错误: \(error)\n".utf8))
            exit(2)
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "devices":
            try listDevices()
        case "info":
            try deviceInfo()
        case "storages":
            try withSession { session in
                for storage in try session.listStorages() {
                    print("\(storage.storageID)\t\(storage.displayName)\t" +
                          "已用 \(ByteCount.format(storage.maxCapacity - storage.freeSpaceInBytes))" +
                          " / 剩余 \(ByteCount.format(storage.freeSpaceInBytes))" +
                          (storage.isReadOnly ? " (只读)" : ""))
                }
            }
        case "ls":
            try listDirectory(rest)
        case "pull":
            try pull(rest)
        case "push":
            try push(rest)
        case "mkdir":
            try makeDirectory(rest)
        case "rm":
            try remove(rest)
        case "diag":
            try diagnose()
        case "diag2":
            try diagnoseFullSession()
        case "thumb":
            try fetchThumbnail(rest)
        default:
            FileHandle.standardError.write(Data("未知命令: \(command)\n".utf8))
            printUsage()
            exit(2)
        }
    }

    static func printUsage() {
        print("""
        syncharmony — SyncHarmonyOS 命令行工具 (MTP over USB)

        用法:
          syncharmony devices              列出已连接的 MTP 设备
          syncharmony info                 显示设备信息
          syncharmony storages             列出存储卷
          syncharmony ls [存储别名:]路径    列出目录（如 ls 存储1:/DCIM）
          syncharmony pull <路径> <本地>   下载文件
          syncharmony push <本地> <路径>   上传文件
          syncharmony mkdir <路径>         新建文件夹
          syncharmony rm <路径>            删除文件或空文件夹

        提示: 手机需通过 USB 连接并选择「传输文件」模式。
        """)
    }

    // MARK: - Commands

    static func listDevices() throws {
        let devices = USBDeviceScanner.scanDevices()
        guard !devices.isEmpty else {
            print("未发现 MTP 设备（请检查手机是否选择了「传输文件」模式）")
            return
        }
        for device in devices {
            print(String(format: "%016llX\t%04X:%04X\t%@ (%@) class=%02X/%02X/%02X",
                         device.registryEntryID, device.vendorID, device.productID,
                         device.displayName, device.serialNumber,
                         device.interfaceClass, device.interfaceSubClass,
                         device.interfaceProtocol))
        }
    }

    static func deviceInfo() throws {
        try withSession { session in
            let info = session.deviceInfo
            print("设备:      \(info.displayName)")
            print("厂商:      \(info.manufacturer)")
            print("型号:      \(info.model)")
            print("版本:      \(info.deviceVersion)")
            print("序列号:    \(info.serialNumber)")
            print("PTP 版本:  \(String(format: "0x%04X", info.standardVersion))")
            print("MTP 扩展:  \(info.vendorExtensionDesc.isEmpty ? "标准 PTP" : info.vendorExtensionDesc)")
        }
    }

    static func listDirectory(_ arguments: [String]) throws {
        let rawPath = arguments.first ?? "/"
        try withSession { session in
            try withStorage(session: session, rawPath: rawPath) { storage, path in
                let resolved = try MTPPathResolver.resolve(path, session: session, storageID: storage.storageID)
                let parent = resolved.object?.handle ?? Handle.root
                let children = try session.listChildren(storageID: storage.storageID, parent: parent)
                for child in children.sorted(by: { $0.filename < $1.filename }) {
                    let marker = child.isFolder ? "/" : ""
                    let size = child.isFolder ? "-" : ByteCount.format(child.size)
                    print("\(child.handle)\t\(size)\t\(child.filename)\(marker)")
                }
            }
        }
    }

    static func pull(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw MTPError.fileSystem("用法: syncharmony pull <远程路径> <本地路径>")
        }
        let remote = DevicePath.parse(arguments[0])
        let local = URL(fileURLWithPath: arguments[1])
        try withSession { session in
            try withStorage(session: session, rawPath: remote.path, alias: remote.storageAlias) { storage, path in
                let resolved = try MTPPathResolver.resolve(path, session: session, storageID: storage.storageID)
                guard let object = resolved.object, !object.isFolder else {
                    throw MTPError.fileSystem("远程路径不是文件: \(remote.path)")
                }
                let size = try session.objectSize(handle: object.handle, fallback: object.compressedSize)
                let start = Date()
                try session.download(handle: object.handle, totalSize: size, to: local) { done, total in
                    printProgress("下载 \(object.filename)", done: done, total: total)
                }
                printProgress("下载 \(object.filename)", done: size, total: size)
                print(String(format: "\n完成: %@ (%@, %.1fs)", local.path, ByteCount.format(size), Date().timeIntervalSince(start)))
            }
        }
    }

    static func push(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw MTPError.fileSystem("用法: syncharmony push <本地文件> <远程目录路径>")
        }
        let source = URL(fileURLWithPath: arguments[0])
        let remote = DevicePath.parse(arguments[1])
        try withSession { session in
            try withStorage(session: session, rawPath: remote.path, alias: remote.storageAlias) { storage, path in
                let resolved = try MTPPathResolver.resolve(path, session: session, storageID: storage.storageID)
                let parent = resolved.object.map { $0.isFolder ? $0.handle : $0.parentObject } ?? Handle.root
                let start = Date()
                let handle = try session.upload(fileAt: source, storageID: storage.storageID,
                                                parent: parent) { done, total in
                    printProgress("上传 \(source.lastPathComponent)", done: done, total: total)
                }
                print(String(format: "\n完成: 对象句柄 %u (%.1fs)", handle, Date().timeIntervalSince(start)))
            }
        }
    }

    static func makeDirectory(_ arguments: [String]) throws {
        guard let rawPath = arguments.first else {
            throw MTPError.fileSystem("用法: syncharmony mkdir <路径>")
        }
        let parsed = DevicePath.parse(rawPath)
        try withSession { session in
            try withStorage(session: session, rawPath: parsed.path, alias: parsed.storageAlias) { storage, path in
                let folderName = String(path.split(separator: "/").last.map(String.init) ?? path)
                let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                let resolved = try MTPPathResolver.resolve(parentPath, session: session, storageID: storage.storageID)
                let parent = resolved.object?.handle ?? Handle.root
                let handle = try session.createFolder(named: folderName,
                                                      storageID: storage.storageID, parent: parent)
                print("已创建: \(folderName) (句柄 \(handle))")
            }
        }
    }

    static func remove(_ arguments: [String]) throws {
        guard let rawPath = arguments.first else {
            throw MTPError.fileSystem("用法: syncharmony rm <路径>")
        }
        let parsed = DevicePath.parse(rawPath)
        try withSession { session in
            try withStorage(session: session, rawPath: parsed.path, alias: parsed.storageAlias) { storage, path in
                let resolved = try MTPPathResolver.resolve(path, session: session, storageID: storage.storageID)
                guard let object = resolved.object else {
                    throw MTPError.fileSystem("路径不存在: \(path)")
                }
                try session.delete(handle: object.handle)
                print("已删除: \(object.filename)")
            }
        }
    }

    // MARK: - Helpers

    /// Low-level connectivity staging: open → OpenSession → read, each step
    /// reported so hangs can be localized without a debugger.
    static func diagnose() throws {
        let devices = USBDeviceScanner.scanDevices()
        guard let device = devices.first else {
            print("未发现 MTP 设备")
            return
        }
        print("① 扫描 OK: \(device.displayName) entry=\(device.registryEntryID)")
        print("② 正在独占打开 USB 接口…")
        let pipe = try IOKitUSBBulkPipe(registryEntryID: device.registryEntryID)
        print("③ 打开 OK，bulk in=\(pipe.inMaxPacket)B out=\(pipe.outMaxPacket)B")

        let transport = PTPTransport(pipe: pipe)
        print("④ 发送 OpenSession…")
        let tx = try transport.sendRequest(code: Operation.openSession, params: [1])
        print("⑤ 请求已发出 tx=\(tx)，等待响应（5 秒看门狗）…")

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            do {
                let data = try transport.receiveData(expectedCode: Operation.openSession,
                                                     expectedTransaction: tx)
                print("⑥ 数据阶段: \(data.count) 字节")
            } catch {
                print("⑥ 数据阶段异常: \(error)")
            }
            group.leave()
        }
        if group.wait(timeout: .now() + 5) == .timedOut {
            print("!! 读取阻塞超过 5 秒 —— 设备在该接口上不应答 OpenSession")
            print("   提示: 12D1:1101 常见为华为 HiSuite/HDC 模式；")
            print("   请在手机 USB 连接方式里选择「传输文件」，或关闭「HiSuite 通过 HDB 连接设备」。")
        } else {
            print("⑦ 诊断完成")
        }
        pipe.close()
    }

    /// Full transaction sequence replicating MTPSession.init with step logs.
    static func diagnoseFullSession() throws {
        let devices = USBDeviceScanner.scanDevices()
        guard let device = devices.first else {
            print("未发现 MTP 设备")
            return
        }
        let pipe = try IOKitUSBBulkPipe(registryEntryID: device.registryEntryID)
        let transport = PTPTransport(pipe: pipe)

        print("A. OpenSession sendRequest…")
        let tx1 = try transport.sendRequest(code: Operation.openSession, params: [1])
        print("B. OpenSession receiveResponse…")
        let resp1 = try transport.receiveResponse(expectedTransaction: tx1)
        print("   → 0x\(String(resp1.code, radix: 16)) params=\(resp1.params)")
        guard resp1.code == ResponseCode.ok || resp1.code == ResponseCode.sessionAlreadyOpened else {
            print("   会话打开被拒绝")
            return
        }

        print("C. GetDeviceInfo sendRequest…")
        let tx2 = try transport.sendRequest(code: Operation.getDeviceInfo, params: [])
        print("D. GetDeviceInfo receiveData（10 秒看门狗）…")
        let group = DispatchGroup()
        group.enter()
        var infoData: Data?
        var infoError: Error?
        DispatchQueue.global().async {
            do {
                infoData = try transport.receiveData(expectedCode: Operation.getDeviceInfo,
                                                     expectedTransaction: tx2)
            } catch {
                infoError = error
            }
            group.leave()
        }
        if group.wait(timeout: .now() + 10) == .timedOut {
            print("!! GetDeviceInfo 数据阶段阻塞 >10s")
            return
        }
        if let infoError {
            print("   → 数据阶段异常: \(infoError)")
            return
        }
        print("   → \(infoData?.count ?? 0) 字节")

        print("E. GetDeviceInfo receiveResponse…")
        let resp2 = try transport.receiveResponse(expectedTransaction: tx2)
        print("   → 0x\(String(resp2.code, radix: 16))")
        var reader = DataReader(infoData!)
        let info = try MTPDeviceInfo(reading: &reader)
        print("F. 完成: \(info.displayName)")
        pipe.close()
    }

    /// Fetch an object's embedded thumbnail for protocol verification.
    static func fetchThumbnail(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw MTPError.fileSystem("用法: syncharmony thumb <远程路径> <输出.jpg>")
        }
        let parsed = DevicePath.parse(arguments[0])
        let output = URL(fileURLWithPath: arguments[1])
        try withSession { session in
            try withStorage(session: session, rawPath: parsed.path, alias: parsed.storageAlias) { storage, path in
                let resolved = try MTPPathResolver.resolve(path, session: session, storageID: storage.storageID)
                guard let object = resolved.object else {
                    throw MTPError.fileSystem("路径不存在: \(path)")
                }
                if let data = try session.thumbnailData(handle: object.handle) {
                    try data.write(to: output)
                    print("缩略图: \(data.count) 字节 → \(output.path)")
                } else {
                    print("设备无内嵌缩略图: \(object.filename)")
                }
            }
        }
    }

    static func withSession(_ body: (MTPSession) throws -> Void) throws {
        let devices = USBDeviceScanner.scanDevices()
        guard let device = devices.first else { throw MTPError.noDevice }
        let pipe = try IOKitUSBBulkPipe(registryEntryID: device.registryEntryID)
        let session = try MTPSession(pipe: pipe)
        var ok = false
        defer { if !ok { try? session.close() } }
        try body(session)
        try session.close()
        ok = true
    }

    /// Resolve the storage part of a path. Supports explicit aliases
    /// "存储1:/path" or the first storage when omitted.
    static func withStorage(session: MTPSession, rawPath: String,
                            alias: String? = nil,
                            _ body: (MTPStorage, String) throws -> Void) throws {
        let storages = try session.listStorages()
        guard !storages.isEmpty else { throw MTPError.fileSystem("设备没有可用存储卷") }
        var storage = storages[0]
        var path = rawPath
        if let alias {
            guard let match = storages.first(where: {
                $0.displayName.contains(alias) || String($0.storageID) == alias
            }) else {
                throw MTPError.fileSystem("找不到存储卷: \(alias)")
            }
            storage = match
        }
        try body(storage, path)
        _ = path // silence unused warnings in narrow builds
    }

    static func printProgress(_ label: String, done: UInt64, total: UInt64) {
        guard total > 0 else { return }
        let percent = Int(Double(done) / Double(total) * 100)
        let bar = String(repeating: "█", count: max(0, percent / 5)) +
                  String(repeating: "░", count: max(0, 20 - percent / 5))
        FileHandle.standardError.write(Data("\r\(label) [\(bar)] \(percent)% \(ByteCount.format(done))/\(ByteCount.format(total))".utf8))
    }
}
