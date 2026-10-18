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

    // MARK: - 列表模式

    private var listTable: some View {
        Table(model.entries, selection: $model.selectedHandles) {
            TableColumn("") { entry in
                Image(nsImage: entry.systemIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            .width(30)

            TableColumn("名称") { entry in
                Text(entry.filename)
                    .fontWeight(entry.isFolder ? .medium : .regular)
            }

            TableColumn("大小") { entry in
                Text(entry.isFolder ? "—" : ByteCount.format(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("修改时间") { entry in
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
            if !selectedHandles.isEmpty {
                Button("下载所选…") {
                    NotificationCenter.default.post(name: .shoDownloadSelected, object: nil)
                }
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

    // MARK: - 预览模式（缩略图网格）

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                      spacing: 10) {
                ForEach(model.entries) { entry in
                    PreviewCell(entry: entry,
                                thumbnail: model.thumbnails[entry.handle],
                                isSelected: model.selectedHandles.contains(entry.handle))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isFolder { model.openFolder(entry) }
                        }
                        .onTapGesture {
                            model.selectedHandles = [entry.handle]
                        }
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
                        }
                }
            }
            .padding(12)
        }
    }

    // MARK: - plumbing

    private func openByHandles(_ handles: Set<UInt32>) {
        guard let handle = handles.first,
              let entry = model.entries.first(where: { $0.handle == handle }) else { return }
        model.openFolder(entry)
    }

    private func openSelected() {
        openByHandles(model.selectedHandles)
    }
}

/// 预览网格单元：文件夹/非图片显示系统图标，图片显示设备端缩略图。
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
