// AppModel.swift — central observable state for the SwiftUI front end.
// Bridges the blocking MTP core onto background queues and republishes
// results on the main actor.

import Foundation
import SyncHarmonyCore
import Combine

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
    @Published public var errorMessage: String?
    @Published public private(set) var isLoadingEntries = false

    /// Selected rows (handles) for batch operations.
    @Published public var selectedHandles: Set<UInt32> = []

    private var session: MTPSession?
    private var sessionPipe: USBBulkPipe?
    private let workQueue = DispatchQueue(label: "io.syncharmonyos.appwork", qos: .userInitiated)
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

    // MARK: - Browsing

    public func selectStorage(_ id: UInt32) {
        selectedStorageID = id
        pathComponents = []
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
        reloadEntries()
    }

    public func navigateToPathComponent(at index: Int) {
        pathComponents = Array(pathComponents.prefix(index + 1))
        reloadEntries()
    }

    public func navigateToRoot() {
        pathComponents = []
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

    /// Called after transfers finish so listings refresh.
    public func transfersDidChange() {
        reloadEntries()
    }
}
