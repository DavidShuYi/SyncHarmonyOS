// SystemIcons.swift — Finder-consistent icons for folders and file types.

import AppKit
import UniformTypeIdentifiers
import SyncHarmonyCore

extension MTPObjectInfo {
    /// 与系统（Finder）一致的图标：文件夹用系统文件夹图标，
    /// 文件按扩展名取对应文档图标。
    var systemIcon: NSImage {
        if isFolder { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
