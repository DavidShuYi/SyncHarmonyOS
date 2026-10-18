// AppModel.swift — central observable state for the SwiftUI front end.
// Bridges the blocking MTP core onto background queues and republishes
// results on the main actor.

import Foundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import SyncHarmonyCore
import Combine

/// 浏览视图模式：列表 / 预览（图标网格）。
public enum BrowserViewMode: String, CaseIterable {
    case list
    case preview
}

/// 可打开某文件类型的候选应用（"打开方式"子菜单）。
public struct AppCandidate: Identifiable {
    public let id = UUID()
    public let name: String
    public let icon: NSImage
    public let url: URL
}

/// Top-level app state: device scanning, connection, browsing.
@MainActor
public final class AppModel: ObservableObject {
    public enum ConnectionState: Equatable {
        case scanning
        case noDevice
        case connecting
        case busy(String)
        case connected
        case failed(String)
    }

    @Published public private(set) var devices: [MTPUSBDeviceInfo] = []
    @Published public private(set) var connection: ConnectionState = .scanning
    @Published public private(set) var deviceName = ""
    @Published public private(set) var storages: [MTPStorage] = []
    @Published public var selectedStorageID: UInt32?
    @Published public private(set) var entries: [MTPObjectInfo] = []
    @Published public var pathComponents: [MTPObjectInfo] = []
    /// Forward history for the "next folder" toolbar action.
    @Published public private(set) var forwardStack: [MTPObjectInfo] = []
    @Published public var errorMessage: String?
    @Published public private(set) var isLoadingEntries = false
    /// 列表 / 预览 视图模式。
    @Published public var viewMode: BrowserViewMode = .list
    /// 排序状态（表头点击驱动）。默认按修改时间倒序。
    @Published public var sortOrder: [KeyPathComparator<MTPObjectInfo>] = [
        KeyPathComparator(\MTPObjectInfo.sortDate, order: .reverse)
    ]
    /// 当前排序后的列表（列表模式与预览模式共用）。
    public var sortedEntries: [MTPObjectInfo] { entries.sorted(using: sortOrder) }
    /// 预览模式下已加载的缩略图（句柄 → 图片）。
    @Published public private(set) var thumbnails: [UInt32: NSImage] = [:]
    /// 范围多选（Shift 点击）的锚点。
    @Published private(set) var selectionAnchor: UInt32?

    /// Selected rows (handles) for batch operations.
    @Published public var selectedHandles: Set<UInt32> = []

    private var session: MTPSession?
    private var sessionPipe: USBBulkPipe?
    private let workQueue = DispatchQueue(label: "io.syncharmonyos.appwork", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "io.syncharmonyos.thumbs", qos: .userInitiated)
    private var thumbnailLoading = Set<UInt32>()
    private let thumbnailCache = NSCache<NSNumber, NSImage>()
    private var scanTimer: Timer?
    private let serialOps = DispatchQueue(label: "io.syncharmonyos.ops")

    public lazy var transfers: TransferManager = TransferManager { [weak self] in
        self?.session
    }

    public init() {
        startPeriodicScan()
    }

    // MARK: - Device scanning

    public func startPeriodicScan() {
        scanDevices()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scanDevices()
        }
    }

    public func scanDevices() {
        workQueue.async { [weak self] in
            let devices = USBDeviceScanner.scanDevices()
            if ProcessInfo.processInfo.environment["SHO_TRACE"] == "1" {
                FileHandle.standardError.write(Data("[scan] \(devices.count) device(s): \(devices.map { $0.displayName })\n".utf8))
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyScannedDevices(devices)
            }
        }
    }

    private func applyScannedDevices(_ found: [MTPUSBDeviceInfo]) {
        devices = found
        switch connection {
        case .connected, .connecting:
            // If the active device vanished, drop the session.
            if sessionPipe != nil, found.isEmpty {
                session = nil
                sessionPipe = nil
                connection = .noDevice
                entries = []
                storages = []
                pathComponents = []
            }
        case .scanning, .noDevice, .failed, .busy:
            if !isBusyState(connection) {
                connection = found.isEmpty ? .noDevice : connection
            }
        }
    }

    private func isBusyState(_ state: ConnectionState) -> Bool {
        switch state {
        case .connected, .connecting, .busy: return true
        default: return false
        }
    }

    // MARK: - Connect / disconnect

    public func connect(to device: MTPUSBDeviceInfo) {
        guard session == nil else { return }
        connection = .connecting
        workQueue.async { [weak self] in
            do {
                let pipe = try IOKitUSBBulkPipe(registryEntryID: device.registryEntryID)
                let session = try MTPSession(pipe: pipe)
                let storages = try session.listStorages()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.session = session
                    self.sessionPipe = pipe
                    self.deviceName = session.deviceInfo.displayName
                    self.storages = storages
                    self.selectedStorageID = storages.first?.storageID
                    self.connection = .connected
                    self.reloadEntries()
                }
            } catch let error as MTPError {
                DispatchQueue.main.async { [weak self] in
                    self?.connection = .failed(error.description)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.connection = .failed(error.localizedDescription)
                }
            }
        }
    }

    public func disconnect() {
        let current = session
        session = nil
        sessionPipe = nil
        workQueue.async {
            try? current?.close()
        }
        storages = []
        entries = []
        pathComponents = []
        connection = devices.isEmpty ? .noDevice : .scanning
    }

    // MARK: - Navigation（前进 / 后退）

    public var canGoBack: Bool { !pathComponents.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// 后退一层（⌘[）。当前层级压入前进栈。
    public func goBack() {
        guard let last = pathComponents.popLast() else { return }
        forwardStack.append(last)
        thumbnails.removeAll()
        reloadEntries()
    }

    /// 前进一层（⌘]），仅在后退过之后可用。
    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        pathComponents.append(next)
        thumbnails.removeAll()
        reloadEntries()
    }

    private func clearForwardStack() {
        if !forwardStack.isEmpty { forwardStack = [] }
    }

    // MARK: - Browsing

    public func selectStorage(_ id: UInt32) {
        selectedStorageID = id
        pathComponents = []
        clearForwardStack()
        thumbnails.removeAll()
        reloadEntries()
    }

    public func reloadEntries() {
        guard let session, let storageID = selectedStorageID else { return }
        let parent = pathComponents.last?.handle ?? Handle.root
        isLoadingEntries = true
        workQueue.async { [weak self] in
            do {
                let children = try session.listChildren(storageID: storageID, parent: parent)
                DispatchQueue.main.async { [weak self] in
                    self?.entries = children.sorted { a, b in
                        if a.isFolder != b.isFolder { return a.isFolder }
                        return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
                    }
                    self?.selectedHandles = []
                    self?.isLoadingEntries = false
                }
            } catch let error as MTPError {
                DispatchQueue.main.async { [weak self] in
                    self?.isLoadingEntries = false
                    self?.errorMessage = error.description
                    if case .disconnected = error {
                        self?.disconnect()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isLoadingEntries = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func openFolder(_ entry: MTPObjectInfo) {
        guard entry.isFolder else { return }
        pathComponents.append(entry)
        clearForwardStack()
        thumbnails.removeAll()
        reloadEntries()
    }

    public func navigateToPathComponent(at index: Int) {
        pathComponents = Array(pathComponents.prefix(index + 1))
        clearForwardStack()
        thumbnails.removeAll()
        reloadEntries()
    }

    public func navigateToRoot() {
        pathComponents = []
        clearForwardStack()
        thumbnails.removeAll()
        reloadEntries()
    }

    public var currentPathLabel: String {
        let parts = [currentStorage?.displayName ?? ""] + pathComponents.map(\.filename)
        return parts.joined(separator: " / ")
    }

    public var currentStorage: MTPStorage? {
        storages.first { $0.storageID == selectedStorageID }
    }

    // MARK: - Operations

    public func downloadSelected(to directory: URL) {
        guard let session else { return }
        let storageID = selectedStorageID ?? Handle.root
        let parent = pathComponents.last?.handle ?? Handle.root
        // Snapshot entries on the main actor before touching the queue.
        let targets = entries.filter { selectedHandles.contains($0.handle) && !$0.isFolder }
        for entry in targets {
            let destination = directory.appendingPathComponent(entry.filename)
            let size = entry.size
            let handle = entry.handle
            // Resolve 64-bit size lazily inside the transfer (devices with
            // big files report 0xFFFFFFFF in ObjectInfo).
            transfers.enqueueDownload(handle: handle, name: entry.filename,
                                      size: size == 0xFFFFFFFF ? 0 : size,
                                      destination: destination)
        }
        _ = session
        _ = storageID
        _ = parent
    }

    public func uploadFiles(at urls: [URL]) {
        guard let storageID = selectedStorageID else { return }
        let parent = pathComponents.last?.handle ?? Handle.root
        for url in urls {
            transfers.enqueueUpload(fileAt: url, storageID: storageID, parent: parent)
        }
    }

    public func deleteSelected() {
        guard let session, !selectedHandles.isEmpty else { return }
        let storageID = selectedStorageID ?? 0
        let handles = selectedHandles
        let parent = pathComponents.last?.handle ?? Handle.root
        connection = .busy("正在删除…")
        workQueue.async { [weak self] in
            var failure: String?
            for handle in handles {
                do {
                    try session.delete(handle: handle)
                } catch let error as MTPError {
                    failure = error.description
                } catch {
                    failure = error.localizedDescription
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.connection = .connected
                if let failure { self?.errorMessage = failure }
                self?.reloadEntries()
            }
            _ = storageID
            _ = parent
        }
    }

    public func createFolder(named name: String) {
        guard let session, let storageID = selectedStorageID else { return }
        let parent = pathComponents.last?.handle ?? Handle.root
        workQueue.async { [weak self] in
            do {
                _ = try session.createFolder(named: name, storageID: storageID, parent: parent)
                DispatchQueue.main.async { [weak self] in
                    self?.reloadEntries()
                }
            } catch let error as MTPError {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.description
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Open With（打开方式：下载到缓存后交给系统/指定应用）

    /// "打开方式"下载缓存目录。
    private static let openCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("SyncHarmonyOS/opens", isDirectory: true)
    }()

    /// 按扩展名推导内容类型，列出系统中可打开该类型的应用。
    public func candidateApps(for entry: MTPObjectInfo) -> [AppCandidate] {
        let ext = (entry.filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        var seen = Set<String>()
        var candidates: [AppCandidate] = []
        for url in urls {
            let path = url.path
            guard seen.insert(path).inserted else { continue }
            seen.insert(path)
            let name = FileManager.default.displayName(atPath: path)
            candidates.append(AppCandidate(name: name,
                                           icon: NSWorkspace.shared.icon(forFile: path),
                                           url: url))
        }
        return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 用默认应用或指定应用打开设备上的文件：
    /// 先排队下载到缓存目录，完成后由系统交给对应应用。
    public func openWith(entry: MTPObjectInfo, appURL: URL?) {
        guard !entry.isFolder else { return }
        let destination = Self.openCacheDirectory
            .appendingPathComponent("\(entry.handle)_\(entry.filename)")
        transfers.enqueueDownload(handle: entry.handle,
                                  name: entry.filename,
                                  size: entry.size,
                                  destination: destination) { [weak self] in
            self?.launchOpen(fileURL: destination, appURL: appURL)
        }
    }

    private func launchOpen(fileURL: URL, appURL: URL?) {
        try? FileManager.default.createDirectory(at: Self.openCacheDirectory,
                                                 withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let appURL {
            NSWorkspace.shared.open([fileURL],
                                    withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    /// 右键菜单用：把句柄集合换成本地条目（按当前排序）。
    public func entriesFor(handles: Set<UInt32>) -> [MTPObjectInfo] {
        sortedEntries.filter { handles.contains($0.handle) }
    }

    /// Called after transfers finish so listings refresh.
    public func transfersDidChange() {
        reloadEntries()
    }

    // MARK: - Selection（多选：单击 / ⌘ 切换 / ⇧ 范围）

    /// 预览模式的点击选择逻辑（列表模式的 Table 自带 ⌘/⇧ 多选）。
    /// Shift 范围按当前排序后的可见顺序计算。
    public func tapSelect(entry: MTPObjectInfo) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selectedHandles.contains(entry.handle) {
                selectedHandles.remove(entry.handle)
            } else {
                selectedHandles.insert(entry.handle)
            }
            selectionAnchor = entry.handle
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor ?? selectedHandles.first {
            let visible = sortedEntries
            guard let from = visible.firstIndex(where: { $0.handle == anchor }),
                  let to = visible.firstIndex(where: { $0.handle == entry.handle }) else { return }
            let range = min(from, to)...max(from, to)
            selectedHandles = Set(visible[range].map(\.handle))
        } else {
            selectedHandles = [entry.handle]
            selectionAnchor = entry.handle
        }
    }

    // MARK: - 按下即选中（消除单击/双击消歧延迟）

    /// 拖拽手势的一次按压进行中标志：onChanged 可能连发，去重。
    private var pressInProgress = false
    /// 上一次按压（用于双击检测）。
    private var lastActivation: (handle: UInt32?, time: Double) = (nil, 0)

    /// 预览网格：鼠标**按下**立即选中（对齐 Finder 的按下即选中，
    /// 不等待双击消歧）。
    public func pressSelectBegin(entry: MTPObjectInfo) {
        guard !pressInProgress else { return }
        pressInProgress = true
        tapSelect(entry: entry)
    }

    /// 鼠标抬起：同一单元两次按压且间隔在系统双击时间内 → 打开文件夹。
    public func pressSelectEnd(entry: MTPObjectInfo) {
        pressInProgress = false
        let now = CACurrentMediaTime()
        if lastActivation.handle == entry.handle,
           now - lastActivation.time < NSEvent.doubleClickInterval {
            lastActivation = (nil, 0)
            if entry.isFolder { openFolder(entry) }
        } else {
            lastActivation = (entry.handle, now)
        }
    }

    // MARK: - Thumbnails（预览模式缩略图）

    /// 预览网格按需请求缩略图：命中缓存立即返回，否则后台经
    /// GetThumb 拉取并解码。图片与视频均可（视频返回预览帧）。
    public func requestThumbnail(for entry: MTPObjectInfo) {
        guard viewMode == .preview, entry.canPreviewThumbnail else { return }
        if thumbnails[entry.handle] != nil { return }
        if let cached = thumbnailCache.object(forKey: NSNumber(value: entry.handle)) {
            thumbnails[entry.handle] = cached
            return
        }
        guard let session, !thumbnailLoading.contains(entry.handle) else { return }
        thumbnailLoading.insert(entry.handle)
        let handle = entry.handle
        thumbnailQueue.async { [weak self] in
            let data = (try? session.thumbnailData(handle: handle)) ?? nil
            let decoded = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                thumbnailLoading.remove(handle)
                if let decoded {
                    thumbnailCache.setObject(decoded, forKey: NSNumber(value: handle))
                    thumbnails[handle] = decoded
                }
            }
        }
    }
}
