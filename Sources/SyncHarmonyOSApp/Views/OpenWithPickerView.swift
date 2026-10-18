//
//  File:    OpenWithPickerView.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// OpenWithPickerView.swift — app picker for "打开方式" (Open With).
// A normal SwiftUI list renders NSImage icons reliably, unlike native
// context-menu submenus which drop NSImage/bitmap label icons.

import SwiftUI
import AppKit
import SyncHarmonyCore

struct OpenWithPickerView: View {
    let files: [MTPObjectInfo]
    let candidates: [AppCandidate]
    let onPick: (URL?) -> Void
    let onCancel: () -> Void

    @State private var query = ""

    private var filtered: [AppCandidate] {
        query.isEmpty ? candidates : candidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Divider()
            appList
        }
        .frame(width: 340, height: 440)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("打开方式")
                    .font(.headline)
                Text(files.count == 1
                     ? files[0].filename
                     : "\(files.count) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var appList: some View {
        List {
            Section {
                Button {
                    onPick(nil)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.forward.app")
                            .frame(width: 26)
                        Text("默认应用")
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("系统默认")
            }

            Section {
                ForEach(filtered) { app in
                    Button {
                        onPick(app.url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                            Text(app.name)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty {
                    Text("没有匹配的应用")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                Text("其他应用（\(filtered.count)）")
            }
        }
        .listStyle(.inset)
    }
}
