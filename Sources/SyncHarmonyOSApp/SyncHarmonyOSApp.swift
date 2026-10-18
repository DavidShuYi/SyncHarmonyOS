//
//  File:    SyncHarmonyOSApp.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// SyncHarmonyOSApp.swift — application entry point.

import SwiftUI

@main
struct SyncHarmonyOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("上传文件…") {
                    NotificationCenter.default.post(name: .shoPickUploadFiles, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("新建文件夹") {
                    NotificationCenter.default.post(name: .shoNewFolder, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Keeps the app alive when the last window closes is not desired on macOS
/// for utility apps; standard behavior retained.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // USB access happens on demand; nothing to prime here.
    }
}

extension Notification.Name {
    static let shoPickUploadFiles = Notification.Name("shoPickUploadFiles")
    static let shoNewFolder = Notification.Name("shoNewFolder")
    static let shoDownloadSelected = Notification.Name("shoDownloadSelected")
}
