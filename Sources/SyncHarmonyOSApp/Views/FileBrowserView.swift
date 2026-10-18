//
//  File:    FileBrowserView.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

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
                Button {
                    model.showOpenWithPicker(for: selected)
                } label: {
                    Label("打开方式…", systemImage: "app.badge")
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

    // MARK: - 预览模式（缩略图网格，支持多选）

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                      spacing: 10) {
                ForEach(model.sortedEntries) { entry in
                    gridCell(for: entry)
                }
            }
            .padding(12)
        }
    }

    /// 单个预览单元；右键呈现方式由 OpenWithConfig 硬编码切换：
    /// - .pickerSheet：SwiftUI contextMenu → "打开方式…" → 选择器面板
    /// - .nativeMenu ：AppKit 覆盖层拦截右键 → 原生 NSMenu（带图标）
    private func gridCell(for entry: MTPObjectInfo) -> some View {
        let base = PreviewCell(entry: entry,
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

        switch OpenWithConfig.presentation {
        case .pickerSheet:
            return AnyView(base.contextMenu {
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
                Button {
                    model.showOpenWithPicker(for: scope)
                } label: {
                    Label("打开方式…", systemImage: "app.badge")
                }
            })
        case .nativeMenu:
            return AnyView(base.overlay(
                NativeContextMenuOverlay(model: model, scopeProvider: {
                    if model.selectedHandles.contains(entry.handle) {
                        return model.entriesFor(handles: model.selectedHandles)
                    }
                    return [entry]
                })
            ))
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
