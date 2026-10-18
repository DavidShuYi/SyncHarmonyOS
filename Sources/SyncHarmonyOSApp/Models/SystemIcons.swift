// SystemIcons.swift — Finder-consistent icons for folders and file types.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SyncHarmonyCore

private let videoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "3gp", "3g2", "avi", "mkv", "wmv", "mpg", "mpeg", "webm"
]

extension NSImage {
    /// 菜单可用的位图 SwiftUI Image：SwiftUI 的 Menu/contextMenu
    /// 不渲染 NSImage 形式的 Label 图标（仅支持 SF Symbol 与位图），
    /// 这里把应用图标预渲染为 2x 位图后交由 Image(decorative:) 展示。
    func menuImage(pointSize: CGSize = CGSize(width: 16, height: 16)) -> Image {
        let scale: CGFloat = 2
        let w = max(1, Int(pointSize.width * scale))
        let h = max(1, Int(pointSize.height * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Image(systemName: "app")
        }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(in: NSRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = ctx.makeImage() else {
            return Image(systemName: "app")
        }
        return Image(decorative: cgImage, scale: scale, orientation: .up)
    }
}

extension MTPObjectInfo {
    /// 与系统（Finder）一致的图标：文件夹用系统文件夹图标，
    /// 文件按扩展名取对应文档图标。视频例外——按扩展名推导的
    /// 影片类型会带默认播放器 App 的角标，观感混乱，改用中性的
    /// SF Symbol 图标。
    var systemIcon: NSImage {
        if isFolder { return NSWorkspace.shared.icon(for: .folder) }
        if isVideoFile { return SystemIcons.videoIcon }
        let ext = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// 是否为视频：优先信协议格式码，兜底按扩展名。
    var isVideoFile: Bool {
        if ObjectFormat.isVideo(objectFormat) { return true }
        let ext = ((filename as NSString).pathExtension).lowercased()
        return videoExtensions.contains(ext)
    }

    /// 是否可在预览模式出缩略图（图片 + 视频）。
    var canPreviewThumbnail: Bool {
        ObjectFormat.isImage(objectFormat) || isVideoFile
    }
}

enum SystemIcons {
    /// 中性视频图标（SF Symbol 渲染，不携带任何 App 品牌角标）。
    static let videoIcon: NSImage = neutralIcon("video.fill")

    /// 渲染一枚中性符号图标：圆角底板 + 模板符号（符号按当前填充色着色）。
    static func neutralIcon(_ symbolName: String) -> NSImage {
        let canvas = NSSize(width: 120, height: 120)
        let image = NSImage(size: canvas)
        image.lockFocus()
        NSColor.systemGray.withAlphaComponent(0.15).setFill()
        let box = NSBezierPath(roundedRect: NSRect(x: 14, y: 22, width: 92, height: 76),
                               xRadius: 14, yRadius: 14)
        box.fill()
        NSColor.systemGray.withAlphaComponent(0.85).setStroke()
        box.lineWidth = 5
        box.stroke()

        NSColor.systemGray.withAlphaComponent(0.85).setFill()
        if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
           let symbol = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)) {
            // 模板符号按当前填充色渲染。
            let s = symbol.size
            symbol.draw(in: NSRect(x: (canvas.width - s.width) / 2,
                                   y: (canvas.height - s.height) / 2,
                                   width: s.width, height: s.height))
        }
        image.unlockFocus()
        return image
    }
}
