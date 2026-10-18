//
//  File:    TransferManager.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// TransferManager.swift — serial transfer queue with observable state for the GUI.
// MTP transactions cannot run concurrently on one interface claim, so the
// queue is deliberately serial per device.

import Foundation

/// State machine for one queued transfer.
public enum TransferState: Equatable {
    case queued
    case running
    case finished
    case failed(String)
    case cancelled
}

/// One queued operation (download or upload).
public final class TransferTask: Identifiable, ObservableObject {
    public let id = UUID()
    public let kind: Kind
    @Published public var state: TransferState = .queued
    @Published public var bytesDone: UInt64 = 0
    public let bytesTotal: UInt64
    /// 下载成功完成后的回调（主线程调用），用于"打开方式"等后处理。
    public var onFinish: (() -> Void)?

    public enum Kind: Equatable {
        case download(fileName: String, destination: URL)
        case upload(fileName: String)
    }

    public init(kind: Kind, bytesTotal: UInt64) {
        self.kind = kind
        self.bytesTotal = bytesTotal
    }

    public var title: String {
        switch kind {
        case let .download(name, _): return "下载 \(name)"
        case let .upload(name): return "上传 \(name)"
        }
    }

    public var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(Double(bytesDone) / Double(bytesTotal), 1.0)
    }
}

/// Drives transfers against one open session, serially, on a worker queue.
public final class TransferManager: ObservableObject {
    @Published public private(set) var tasks: [TransferTask] = []
    @Published public private(set) var isBusy = false

    private let queue = DispatchQueue(label: "io.syncharmonyos.transfers", qos: .userInitiated)
    private let sessionProvider: () -> MTPSession?
    private var cancelled = Set<UUID>()

    public init(sessionProvider: @escaping () -> MTPSession?) {
        self.sessionProvider = sessionProvider
    }

    public func enqueueDownload(handle: UInt32, name: String, size: UInt64,
                                destination: URL,
                                overwrite: Bool = false,
                                onFinish: (() -> Void)? = nil) {
        let task = TransferTask(kind: .download(fileName: name, destination: destination),
                                bytesTotal: size)
        task.onFinish = onFinish
        append(task)
        queue.async { [self] in
            run(task) { session in
                try session.download(handle: handle, totalSize: size, to: destination,
                                     overwrite: overwrite) { done, _ in
                    DispatchQueue.main.async { task.bytesDone = done }
                }
            }
        }
    }

    public func enqueueUpload(fileAt source: URL, storageID: UInt32, parent: UInt32) {
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? UInt64) ?? 0
        let task = TransferTask(kind: .upload(fileName: source.lastPathComponent),
                                bytesTotal: size)
        append(task)
        queue.async { [self] in
            run(task) { session in
                try session.upload(fileAt: source, storageID: storageID, parent: parent) { done, _ in
                    DispatchQueue.main.async { task.bytesDone = done }
                }
            }
        }
    }

    public func cancel(taskID: UUID) {
        cancelled.insert(taskID)
    }

    /// Drops completed/failed entries from the list.
    public func clearFinished() {
        DispatchQueue.main.async { [self] in
            tasks.removeAll { task in
                task.state == .finished || task.state == .cancelled
            }
        }
    }

    // MARK: - Plumbing

    private func append(_ task: TransferTask) {
        DispatchQueue.main.async { [self] in
            tasks.append(task)
        }
    }

    private func run(_ task: TransferTask, _ body: (MTPSession) throws -> Void) {
        DispatchQueue.main.async { self.isBusy = true }
        guard let session = sessionProvider() else {
            finish(task, state: .failed("设备未连接"))
            return
        }
        do {
            try body(session)
            finish(task, state: .finished)
        } catch let error as MTPError {
            if case .cancelled = error {
                finish(task, state: .cancelled)
            } else {
                finish(task, state: .failed(error.description))
            }
        } catch {
            finish(task, state: .failed(error.localizedDescription))
        }
    }

    private func finish(_ task: TransferTask, state: TransferState) {
        DispatchQueue.main.async { [self] in
            task.state = state
            isBusy = tasks.contains { $0.state == .running || $0.state == .queued }
            if state == .finished {
                task.onFinish?()
            }
        }
    }
}
