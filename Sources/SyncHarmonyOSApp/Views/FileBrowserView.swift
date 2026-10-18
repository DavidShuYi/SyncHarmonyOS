// FileBrowserView.swift — file/folder listing with breadcrumbs and selection.

import SwiftUI
import SyncHarmonyCore

struct FileBrowserView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            fileTable
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

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(model.currentStorage?.displayName ?? "根目录") {
                    model.navigateToRoot()
                }
                .buttonStyle(.link)
                ForEach(Array(model.pathComponents.enumerated()), id: \.element.handle) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if index == model.pathComponents.count - 1 {
                        Text(component.filename)
                            .font(.callout.weight(.semibold))
                    } else {
                        Button(component.filename) {
                            model.navigateToPathComponent(at: index)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var fileTable: some View {
        Table(model.entries, selection: $model.selectedHandles) {
            TableColumn("") { entry in
                Image(systemName: entry.isFolder ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
            }
            .width(28)

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
        // The registered selection type must match the Table's selection
        // value type (Set<UInt32> of object handles); primaryAction then
        // receives the double-clicked row's IDs.
        .contextMenu(forSelectionType: UInt32.self) { selectedHandles in
            Button("刷新") { model.reloadEntries() }
            if !selectedHandles.isEmpty {
                Button("下载所选…") {
                    NotificationCenter.default.post(name: .shoDownloadSelected, object: nil)
                }
            }
        } primaryAction: { selectedHandles in
            if let handle = selectedHandles.first,
               let entry = model.entries.first(where: { $0.handle == handle }) {
                model.openFolder(entry)
            }
        }
        .background {
            // Return opens the selected folder, matching Finder conventions.
            Button("打开") {
                if let handle = model.selectedHandles.first,
                   let entry = model.entries.first(where: { $0.handle == handle }) {
                    model.openFolder(entry)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}
