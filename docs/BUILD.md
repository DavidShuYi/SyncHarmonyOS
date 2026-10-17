# 开发与打包指南（小白版）

从零开始，把这份源码变成可以安装的 `.app` 和 `.dmg`。全程只需要终端，按顺序复制粘贴即可。

## 0. 准备环境（一次性）

| 工具 | 检查命令 | 没有的话 |
|---|---|---|
| macOS 13+ | `sw_vers` | 升级系统 |
| Xcode 15+（含 Swift 5.9+） | `swift --version` | App Store 安装 Xcode（免费） |

```bash
swift --version
# 需要 Swift 5.9 或更高（本项目用 Swift 6.0.3 开发，5.9+ 均可）
```

> 只需要 Xcode 的命令行工具链，不需要打开 Xcode 图形界面。

## 1. 获取源码并编译

```bash
cd ~/Developer/opensource/github/SyncHarmonyOS   # 进入项目目录
swift build                                      # 编译（首次约 1-2 分钟）
```

成功标志：最后输出 `Build complete!`

编译产物在 `.build/debug/` 里，试运行：

```bash
.build/debug/syncharmony devices
# 用数据线连上鸿蒙/安卓设备（选「传输文件」模式），会列出设备
```

## 2. 跑测试

```bash
swift test
```

成功标志：`Executed 14 tests, with 0 failures`。测试用模拟的 MTP 设备跑完整协议链路，不需要插真机。

## 3. 构建 App（release 通用二进制）

```bash
scripts/build-app.sh release
```

这个脚本自动完成：
1. `swift build -c release --arch arm64 --arch x86_64`（Apple Silicon + Intel 双架构）
2. 生成应用图标（CoreGraphics 绘制 → iconset → icns）
3. 组装 `dist/SyncHarmonyOS.app`（含 Info.plist）
4. ad-hoc 代码签名（本机可用；分发给别人需要开发者证书）

试运行 App：

```bash
open dist/SyncHarmonyOS.app
```

## 4. 打包 DMG

```bash
scripts/make-dmg.sh
```

产物：`dist/SyncHarmonyOS-1.0.0.dmg`（约 2 MB），双击即可安装——把 App 拖进 Applications。

## 5. 日常开发循环

```bash
# 改代码（Sources/ 目录）→ 重新编译 → 重跑
swift build && .build/debug/syncharmony info
```

带协议级日志排障：

```bash
SHO_TRACE=1 .build/debug/syncharmony ls /
```

## 6. 在 Xcode 里开发（可选）

```bash
open Package.swift        # Xcode 会以 SwiftPM 包形式打开
```

选 `SyncHarmonyOS` scheme 直接 ⌘R 运行 GUI。

## 7. 清理重来

```bash
swift package clean       # 清编译缓存
rm -rf .build dist        # 彻底重置
```

## 目录结构速查

```
SyncHarmonyOS/
├── Package.swift               # SwiftPM 清单（targets / 依赖 / 平台）
├── Sources/
│   ├── CUSBShim/               # C 桥接：IOKit USB 用户客户端
│   ├── SyncHarmonyCore/        # 协议栈（USB / Transport / MTP / Transfer / Util）
│   ├── SyncHarmonyCLI/         # syncharmony 命令行
│   └── SyncHarmonyOSApp/       # SwiftUI 图形界面
├── Tests/SyncHarmonyCoreTests/ # 模拟设备全链路测试
├── scripts/                    # build-app.sh / make-dmg.sh / make-icon.swift
├── docs/                       # 架构 / 协议 / 本文档 / 排障
└── dist/                       # 构建产物（.app / .dmg，不入库）
```

## 常见构建问题

| 症状 | 解决 |
|---|---|
| `swift: error: unable to find utility` | 安装完整 Xcode，并 `sudo xcode-select -s /Applications/Xcode.app` |
| Swift 版本太旧 | 升级 Xcode 到 15+ |
| `Build complete!` 但找不到命令 | 二进制在 `.build/debug/`，用相对路径运行 |
| 签名错误 `code object is not signed at all` | 重新跑 `scripts/build-app.sh`（脚本按 先内后外 顺序签名） |
