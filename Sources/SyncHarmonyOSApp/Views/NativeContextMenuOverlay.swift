//
//  File:    NativeContextMenuOverlay.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// NativeContextMenuOverlay.swift — native NSMenu right-click for the
// preview grid. AppKit menu items carry real icons (NSMenuItem.image),
// unlike SwiftUI context menus which drop NSImage/bitmap label icons.

import AppKit
import SwiftUI
import SyncHarmonyCore

/// An invisible AppKit overlay that intercepts right-clicks (and
/// control-clicks) and presents a native NSMenu. Left clicks pass
/// through to the SwiftUI content underneath by returning nil from
/// hit-test for non-right events.
struct NativeContextMenuOverlay: NSViewRepresentable {
    @ObservedObject var model: AppModel
    /// 右键作用域，在菜单弹出那一刻求值（条目或整个选区）。
    let scopeProvider: () -> [MTPObjectInfo]

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.menuProvider = { [weak model] in
            guard let model else { return nil }
            let scope = scopeProvider()
            return Self.buildMenu(model: model, scope: scope)
        }
        return view
    }

    func updateNSView(_ view: HookView, context: Context) {}

    /// 构建原生菜单。返回的 coordinator 由 HookView 强持有：
    /// NSMenuItem 对 target 是 unsafe-unretained 引用，菜单跟踪期间
    /// 必须保证其存活。
    static func buildMenu(model: AppModel, scope: [MTPObjectInfo]) -> (NSMenu, NSObject)? {
        let files = scope.filter { !$0.isFolder }
        guard !files.isEmpty else { return nil }

        let coordinator = MenuCoordinator()
        let menu = NSMenu()
        menu.autoenablesItems = false

        coordinator.add(to: menu, title: "刷新") {
            model.reloadEntries()
        }
        coordinator.add(to: menu, title: "下载所选…") {
            model.selectedHandles = Set(files.map(\.handle))
            NotificationCenter.default.post(name: .shoDownloadSelected, object: nil)
        }
        menu.addItem(.separator())

        // "打开方式"二级子菜单：默认应用 + 全部候选应用（带图标）。
        let openMenu = NSMenu(title: "打开方式")
        coordinator.add(to: openMenu, title: "默认应用") {
            files.forEach { model.openWith(entry: $0, appURL: nil) }
        }
        let candidates = model.candidateApps(for: files[0])
        if !candidates.isEmpty {
            openMenu.addItem(.separator())
            for app in candidates {
                coordinator.add(to: openMenu, title: app.name, image: app.icon) {
                    files.forEach { model.openWith(entry: $0, appURL: app.url) }
                }
            }
        }
        let openItem = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        openItem.image = NSImage(systemSymbolName: "app.badge",
                                 accessibilityDescription: "打开方式")
        openItem.submenu = openMenu
        menu.addItem(openItem)

        return (menu, coordinator)
    }

    // MARK: - Hook view

    final class HookView: NSView {
        var menuProvider: () -> (NSMenu, NSObject)? = { nil }
        /// 保活当前菜单的 coordinator（target 为 unretained）。
        private var retainedCoordinator: NSObject?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                // Control+左键 = 右键语义（macOS 全局约定）。
                if event.modifierFlags.contains(.control) {
                    return super.hitTest(point)
                }
                return nil
            default:
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let (menu, coordinator) = menuProvider() else { return nil }
            retainedCoordinator = coordinator
            return menu
        }
    }

    /// NSMenuItem 的 action 需要一个 @objc target；此协调器把闭包
    /// 存进数组、用 tag 索引派发。命名避开 Representable 的保留别名
    /// "Coordinator"。
    final class MenuCoordinator: NSObject {
        private var actions: [() -> Void] = []

        func add(to menu: NSMenu, title: String,
                 image: NSImage? = nil,
                 action: @escaping () -> Void) {
            let item = NSMenuItem(title: title,
                                  action: #selector(performAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = actions.count
            item.image = image
            item.isEnabled = true
            actions.append(action)
            menu.addItem(item)
        }

        @objc private func performAction(_ sender: NSMenuItem) {
            let index = sender.tag
            guard actions.indices.contains(index) else { return }
            actions[index]()
        }
    }
}
