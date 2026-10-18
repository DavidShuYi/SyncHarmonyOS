// ContentView.swift — main three-pane layout: devices / files / transfers.

import SwiftUI
import Combine
import UniformTypeIdentifiers
import SyncHarmonyCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showUploadPanel = false
    @State private var showDownloadPanel = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirmation = false
    @State private var transferObserver: AnyCancellable?

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            fileListPane
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            detailPane
        }
        .navigationTitle(model.connection == .connected ? model.currentPathLabel : "SyncHarmonyOS")
        .toolbar { toolbarContent }
        .alert("错误", isPresented: errorBinding, actions: {
            Button("好", role: .cancel) { model.errorMessage = nil }
        }, message: {
            Text(model.errorMessage ?? "")
        })
        .alert("新建文件夹", isPresented: $showNewFolderAlert, actions: {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                if !newFolderName.isEmpty { model.createFolder(named: newFolderName) }
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        })
        .confirmationDialog("删除所选项目？",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("删除 \(model.selectedHandles.count) 个项目", role: .destructive) {
                model.deleteSelected()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销。文件夹必须为空。")
        }
        .fileImporter(isPresented: $showUploadPanel,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                model.uploadFiles(at: urls)
            }
        }
        .fileImporter(isPresented: $showDownloadPanel,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let directory = urls.first {
                model.downloadSelected(to: directory)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shoPickUploadFiles)) { _ in
            showUploadPanel = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .shoNewFolder)) { _ in
            showNewFolderAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .shoDownloadSelected)) { _ in
            showDownloadPanel = true
        }
        .sheet(isPresented: Binding(
            get: { model.openWithEntries != nil },
            set: { if !$0 { model.cancelOpenWithPicker() } }
        )) {
            if let files = model.openWithEntries {
                OpenWithPickerView(files: files,
                                   candidates: model.candidateApps(for: files[0]),
                                   onPick: { appURL in
                                       model.confirmOpenWith(appURL: appURL, files: files)
                                   },
                                   onCancel: { model.cancelOpenWithPicker() })
            }
        }
        .onAppear {
            observeTransfers()
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var fileListPane: some View {
        switch model.connection {
        case .noDevice, .scanning:
            emptyState
        case .connecting:
            ProgressView("正在连接设备…")
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("重试") { model.scanDevices() }
            }
            .padding()
        case let .busy(message):
            ProgressView(message)
        case .connected:
            FileBrowserView(model: model)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if model.connection == .connected {
            TransferQueueView(model: model)
        } else {
            placeholderDetail
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.devices.isEmpty {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("连接你的设备")
                    .font(.title3.bold())
                Text("用 USB 数据线连接鸿蒙 / 安卓手机，\n并在手机上选择「传输文件」模式。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("选择左侧的设备开始浏览")
                    .font(.title3.bold())
                Text("已检测到 \(model.devices.count) 台设备，点击侧边栏中的设备名称即可连接。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if model.connection == .noDevice {
                Button("重新扫描") { model.scanDevices() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("连接设备后，这里显示传输队列")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("后退（⌘[）")

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            .help("前进（⌘]）")

            Button {
                model.navigateToRoot()
            } label: {
                Image(systemName: "house")
            }
            .disabled(model.connection != .connected || model.pathComponents.isEmpty)
            .help("回到存储根目录")

            Button {
                model.reloadEntries()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.connection != .connected)
            .help("刷新")

            Spacer()

            Picker("查看方式", selection: $model.viewMode) {
                Image(systemName: "list.bullet")
                    .tag(BrowserViewMode.list)
                Image(systemName: "square.grid.2x2")
                    .tag(BrowserViewMode.preview)
            }
            .pickerStyle(.segmented)
            .frame(width: 88)
            .disabled(model.connection != .connected)
            .help("列表 / 预览")

            Button {
                showDownloadPanel = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(model.selectedHandles.isEmpty)
            .help("下载所选到 Mac")

            Button {
                showUploadPanel = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(model.connection != .connected)
            .help("从 Mac 上传文件")

            Button {
                showNewFolderAlert = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(model.connection != .connected)
            .help("新建文件夹")

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.selectedHandles.isEmpty)
            .help("删除所选")
        }
    }

    // MARK: - plumbing

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { _ in model.errorMessage = nil })
    }

    private func observeTransfers() {
        guard transferObserver == nil else { return }
        transferObserver = model.transfers.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak model] tasks in
                let idle = !tasks.contains {
                    $0.state == .running || $0.state == .queued
                }
                let hadRunning = model?.entries.isEmpty == false
                if idle && hadRunning {
                    model?.transfersDidChange()
                }
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { [weak model] in
                    model?.uploadFiles(at: [url])
                }
            }
        }
        return handled
    }
}
