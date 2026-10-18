//
//  File:    OpenWithMode.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// OpenWithMode.swift — "打开方式"呈现方式的编译期切换开关。
//
// ★ 修改 OpenWithConfig.presentation 后重新编译即可切换效果 ★
//
// - .pickerSheet（当前默认）
//     右键"打开方式…" → 独立选择器面板。
//     普通 SwiftUI 列表渲染 NSImage 图标毫无限制；支持搜索过滤；
//     超长应用列表可滚动。列表/预览两种模式都生效。
//
// - .nativeMenu
//     右键直接弹出原生 NSMenu：AppKit 菜单项原生携带应用图标
//     （NSMenuItem.image），观感与 Finder 右键完全一致。
//     注意：SwiftUI 的 contextMenu 不会渲染真实图片图标，所以该模式
//     通过一层 AppKit 覆盖视图拦截右键实现，仅作用于预览网格；
//     列表模式仍使用选择器面板。无搜索功能。

import Foundation

enum OpenWithPresentation {
    case pickerSheet
    case nativeMenu
}

enum OpenWithConfig {
    /// ★ 切换点：.pickerSheet / .nativeMenu
    static let presentation: OpenWithPresentation = .nativeMenu
}
