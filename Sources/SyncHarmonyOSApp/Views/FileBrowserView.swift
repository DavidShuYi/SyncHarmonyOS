// FileBrowserView.swift — file browsing with list & preview (thumbnail grid)
// modes, Finder-consistent icons, and fully clickable breadcrumbs.

import SwiftUI
import AppKit
import SyncHarmonyCore

struct FileBrowserView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            switch model.viewMode {
            case .list:
                listTable
            case .preview:
                iconGrid
            }
        }
        .overlay {
            if model.isLoadingEntries {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 面包屑（全部层级可点击）

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    model.navigateToRoot()
                } label: {
                    Label(model.currentStorage?.displayName ?? "根目录",
                          systemImage: "internaldrive")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
                ForEach(Array(model.pathComponents.enumerated()), id: \.element.handle) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        // 最后一级也响应：等于刷新当前目录。
                        model.navigateToPathComponent(at: index)
                    } label: {
                        Text(component.filename)
                            .font(.callout)
                            .fontWeight(index == model.pathComponents.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 列表模式（表头可排序，默认时间倒序）

    private var listTable: some View {
        Table(model.sortedEntries, selection: $model.selectedHandles, sortOrder: $model.sortOrder) {
            TableColumn("") { entry in
                Image(nsImage: entry.systemIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            .width(30)

            TableColumn("名称", value: \.sortName) { entry in
                Text(entry.filename)
                    .fontWeight(entry.isFolder ? .medium : .regular)
            }

            TableColumn("大小", value: \.size) { entry in
                Text(entry.isFolder ? "—" : ByteCount.format(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("修改时间", value: \.sortDate) { entry in
                if let date = entry.modificationDate {
                    Text(date, style: .date)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn("状态") { entry in
                if entry.isReadOnly {
                    Text("只读")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .width(60)
        }
        // 注册类型必须与 selection 的值类型（句柄 UInt32）一致，
        // primaryAction 才会收到双击事件。
        .contextMenu(forSelectionType: UInt32.self) { selectedHandles in
            Button("刷新") { model.reloadEntries() }
            let selected = model.entriesFor(handles: selectedHandles)
            if !selected.isEmpty {
                Button("下载所选…") {
                    NotificationCenter.default.post(name: .shoDownloadSelected, object: nil)
                }
                openWithMenu(for: selected)
            }
        } primaryAction: { selectedHandles in
            openByHandles(selectedHandles)
        }
        .background {
            // 回车打开选中的文件夹（对齐 Finder 习惯）。
            Button("打开") { openSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 预览模式（缩略图网格，支持多选）

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                      spacing: 10) {
                ForEach(model.sortedEntries) { entry in
                    PreviewCell(entry: entry,
                                thumbnail: model.thumbnails[entry.handle],
                                isSelected: model.selectedHandles.contains(entry.handle))
                        .contentShape(Rectangle())
                        // 按下即选中（DragGesture onChanged 立即触发），
                        // 双击在抬起时手动检测——避免单击/双击消歧的
                        // 系统等待延迟。
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                model.pressSelectBegin(entry: entry)
                            }
                            .onEnded { _ in
                                model.pressSelectEnd(entry: entry)
                            })
                        .onAppear {
                            model.requestThumbnail(for: entry)
                        }
                        .contextMenu {
                            Button("刷新") { model.reloadEntries() }
                            if !entry.isFolder {
                                Button("下载到 Mac…") {
                                    model.selectedHandles = [entry.handle]
                                    NotificationCenter.default.post(name: .shoDownloadSelected, object: nil)
                                }
                            }
                            // 右键的条目若在选区内则对整个选区生效。
                            let scope: [MTPObjectInfo] =
                                model.selectedHandles.contains(entry.handle)
                                ? model.entriesFor(handles: model.selectedHandles)
                                : [entry]
                            openWithMenu(for: scope)
                        }
                }
            }
            .padding(12)
        }
    }

    // MARK: - plumbing

    /// "打开方式"子菜单：默认应用 + 系统中可打开该类型的应用列表。
    /// 对文件夹不显示；多选时对选区内所有文件生效。
    @ViewBuilder
    private func openWithMenu(for entries: [MTPObjectInfo]) -> some View {
        let files = entries.filter { !$0.isFolder }
        Menu {
            if files.isEmpty {
                Button("（未选中文件）") {}
                    .disabled(true)
            } else {
                Button {
                    files.forEach { model.openWith(entry: $0, appURL: nil) }
                } label: {
                    Label("默认应用", systemImage: "arrow.up.forward.app")
                }
                let candidates = model.candidateApps(for: files[0])
                if !candidates.isEmpty {
                    Divider()
                    ForEach(candidates) { app in
                        Button {
                            files.forEach { model.openWith(entry: $0, appURL: app.url) }
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                app.menuImage
                            }
                        }
                    }
                }
            }
        } label: {
            Label("打开方式", systemImage: "app.badge")
        }
    }

    private func openByHandles(_ handles: Set<UInt32>) {
        guard let handle = handles.first,
              let entry = model.entries.first(where: { $0.handle == handle }) else { return }
        model.openFolder(entry)
    }

    private func openSelected() {
        openByHandles(model.selectedHandles)
    }
}

/// 预览网格单元：文件夹/非图片显示系统图标，图片与视频显示
/// 设备端缩略图（视频叠加播放角标）。
struct PreviewCell: View {
    let entry: MTPObjectInfo
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
                if entry.isFolder {
                    Image(nsImage: entry.systemIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(nsImage: entry.systemIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                }
            }
            .frame(width: 112, height: 112)
            .overlay(alignment: .bottomTrailing) {
                if entry.isVideoFile && thumbnail != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .padding(4)
                        .shadow(radius: 2)
                }
            }
            Text(entry.filename)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)
        }
        .padding(6)
        .frame(width: 128)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
