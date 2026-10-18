//
//  File:    SettingsView.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// SettingsView.swift — minimal settings scene (about + help).

import SwiftUI
import SyncHarmonyCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            Form {
                Section("设备扫描") {
                    Toggle("自动刷新设备列表 (3 秒)", isOn: .constant(true))
                        .disabled(true)
                }
                Section("关于") {
                    LabeledContent("版本", value: "1.0.0")
                    LabeledContent("协议", value: "MTP / PTP over USB (ISO 15740)")
                }
            }
            .padding()
            .tabItem { Label("通用", systemImage: "gearshape") }

            VStack(alignment: .leading, spacing: 12) {
                Text("常见问题").font(.headline)
                Text("• 手机连接后看不到设备？请在手机通知栏选择「传输文件」。\n• 提示设备被占用？退出 Android File Transfer、MacDroid 等其他 MTP 应用。\n• 大文件传输较慢？MTP 协议单线程传输，速度取决于设备。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .tabItem { Label("帮助", systemImage: "questionmark.circle") }
        }
        .frame(width: 420, height: 240)
    }
}
