# AGENTS.md — SyncHarmonyOS

给 AI 编码代理的项目指南。读完本文件即可直接参与开发，无需额外上下文。

## 项目是什么

**SyncHarmonyOS**：macOS ↔ 鸿蒙(HarmonyOS/OpenHarmony)/安卓设备的 USB 文件传输工具。
原生 SwiftUI 应用，**纯 Swift 实现 MTP 协议栈，零第三方依赖**。

- 作者：David Zhang
- 许可：AGPL-3.0-or-later（强互惠，修改版本必须同样开源，含网络服务场景）
- 系统要求：macOS 13+，Swift 5.9+（项目用 6.0 开发）
- 已验证设备：HUAWEI SGT-AL10（OpenHarmony 平板，MTP 扩展串 `openharmony: 1.0`）

## 常用命令

```bash
swift build                        # 编译（调试版）
swift test                         # 28 个单元测试，全部用模拟设备，无需真机
scripts/build-app.sh release       # 通用二进制 + 图标 + ad-hoc 签名 → dist/SyncHarmonyOS.app
scripts/make-dmg.sh                # 打包 → dist/SyncHarmonyOS-1.0.0.dmg
SHO_TRACE=1 .build/debug/syncharmony ls /    # 线级协议日志（每个容器一行）
```

CLI（无需 GUI 即可完成所有验证）：

```bash
.build/debug/syncharmony devices|info|storages|ls|pull|push|mkdir|rm|thumb
.build/debug/syncharmony diag      # 分步诊断：打开接口 → OpenSession → 读响应
.build/debug/syncharmony diag2     # 完整会话序列逐步打印
```

## 架构（依赖单向向下）

```
SyncHarmonyOSApp (SwiftUI)   SyncHarmonyCLI
        └──────────┬──────────────┘
             SyncHarmonyCore
       USB/ → Transport/ → MTP/ → Transfer/ → Util/
                   (CUSBShim 仅被 USB/ 使用)
```

| 模块 | 职责 | 关键类型 |
|---|---|---|
| `CUSBShim`（C） | IOKit IOUSBLib CFPlugin 用户客户端的平铺封装。函数指针表 Swift 不可见，必须走 C | `shimListMTPDevices` `shimOpenByEntryID` `shimRead/Write`(AsyncTO+超时) `shimClearStall` |
| `Core/USB` | 管道抽象 + IOKit 实现 + 设备扫描 | `USBBulkPipe`(协议) `IOKitUSBBulkPipe` `USBDeviceScanner` |
| `Core/Transport` | 裸 PTP 容器帧（**无 BOT/CBW/CSW**） | `PTPTransport` |
| `Core/MTP` | 会话操作、数据集模型、错误类型 | `MTPSession` `MTPObjectInfo` `MTPError` |
| `Core/Transfer` | 串行传输队列 + 进度 | `TransferManager` `TransferTask` |
| `App` | SwiftUI 三栏 UI；`OpenWithConfig` 硬编码切换"打开方式"实现 | `AppModel` `FileBrowserView` |

## 协议不变量（改错任何一条都会破坏真机连接）

1. **MTP over USB 没有 mass-storage CBW/CSW 包装**——请求/数据/响应都是裸 PTP 容器
   （`length u32 | type u16 | code u16 | txID u32 | payload`，小端）。
2. **事务 ID 从 0 开始**（OpenSession 必须为 0），单调递增；同一操作的数据阶段复用请求的 txID
   （曾因数据头误用自增后的 ID 导致设备回 `tx 11 != 10`）。
3. **数据阶段 16 KiB 分块**；总长恰为 maxPacket 整数倍时必须补发零长包；短包即结束。
4. **同一设备同一时刻只允许一个 MTP 事务**（管道 I/O 已串行化）。
5. **绝不 对普通超时调用 ClearPipeStall**——它会单方面重置主机端 data toggle，
   设备不知情，之后所有 OUT 包被静默丢弃，只能重新插拔恢复。
   恢复只允许用 `ClearPipeStallBothEnds`（两端同步重置），且仅在真实停顿/超时后执行一次。
6. **存储信息双布局**：PTP 容量字段 u32，MTP 扩展为 u64。解析先 MTP（带 <1PB 合理性校验）
   再回退 PTP（`MTPStorage.parse`）。
7. **设备怪癖（华为/OpenHarmony 实测）**：
   - GetThumb 不带规范的 6 字节头，直接返回裸 JPEG（含视频首帧）→ 布局自动探测
   - SendObject 成功响应可能不带句柄参数 → 回退用 SendObjectInfo 返回的句柄
   - 会话残留时 OpenSession 返回 0x201E SessionAlreadyOpened → 按规范继续使用

## 构建产物注意事项

- `build-app.sh`：`swift build --arch arm64 --arch x86_64`（通用二进制落在
  `.build/apple/Products/Release/`，脚本已处理路径）；图标由 `make-icon.swift` 生成
  （Apple 网格：本体 824/1024 居中，圆角 185）；签名顺序**先内后外**（先 syncharmony 后 bundle）。
- `swift build --product` 一次只能指定一个产品，需要分别构建。
- shell 脚本 shebang 必须保持第一行。

## 版本与打包规范（详见 docs/VERSIONING.md）

- 版本号遵循 **SemVer 2.0.0**（`MAJOR.MINOR.PATCH`）：破坏兼容（含提升最低 macOS 版本、
  CLI 语义变更、缓存格式不兼容）→ MAJOR；向后兼容新功能 → MINOR；问题修复 → PATCH。
  有一位递增右侧归零，版本号只进不退，已发布的版本号永不复用。
- 版本字符串落点共 **5 处**（`build-app.sh` / `make-dmg.sh` / 源文件声明头 /
  `SettingsView.swift` 关于页 / `README.md`），bump 时一次改齐；
  以 App `CFBundleShortVersionString` 为单一事实来源。
- 源文件声明头的 Version = 该文件**最后被改动的版本**：bump 时只更新本次修改/新增的文件，
  未改动的文件保持旧版本号不动，禁止顺手统一全仓版本头。
- 打包只走脚本：产物固定为 `dist/SyncHarmonyOS.app` 与 `dist/SyncHarmonyOS-<version>.dmg`；
  release 必须 arm64+x86_64 通用二进制，`dist/` 不入库。
- 发布必打 annotated tag `v<version>`，tag 与 DMG 一一对应，已推送的 tag 永不移动/删除。

## 测试策略

- **协议层测试全部走 `MockMTPPipe`**（脚本化应答的模拟 MTP 设备），覆盖完整会话生命周期、
  请求帧精确性、事务 ID、错误路径、30 万字节分块流式下载——不依赖真机。
- 改动 `PTPTransport`/`MTPSession`/数据集解析后**必须跑 `swift test`**。
- 真机验证用 CLI（`ls/pull/push`）即可覆盖 GUI 的全部核心路径；
  GUI 手工验证清单：连接 → 浏览 → 双击进入 → 排序 → 多选 → 预览缩略图 → 右键打开方式。

## 已知设备状态坑（用户报障先查这里）

1. 手机必须在通知栏选「传输文件」模式（仅充电不暴露 MTP 接口）。
2. 「设备被占用」= 其他 MTP 应用（Android File Transfer/MacDroid 等）持有接口，退出即可。
3. 设备停顿/无响应：解锁亮屏 → 重新插拔数据线（总线复位清状态）。
4. 同步读无超时是历史 bug（已修，勿回退）：所有管道 IO 必须走 AsyncTO 超时路径。

## 代码约定

- 注释英文、UI 文案中文；错误信息面向用户（中文 + 可操作的解决建议）。
- 所有源文件带统一声明头（`File/Project/Author: David Zhang/Version/Date/License: AGPL-3.0-or-later`），
  生成脚本幂等，勿手写重复。
- 版本号：改动/新增的源文件，其声明头 Version 更新为发布版本（当前 1.0.0）；
  未改动的文件保持原版本号不动。bump 规则见上方「版本与打包规范」与 `docs/VERSIONING.md`。
- UI 层 `@MainActor`；阻塞的 MTP 调用一律派发到后台队列，结果回主线程。
- 新增协议行为优先在 `MockMTPPipe` 上补测试用例，再接真机验证。

## 打开方式的两种呈现（编译期硬编码切换）

`Sources/SyncHarmonyOSApp/Models/OpenWithMode.swift` → `OpenWithConfig.presentation`：

- `.pickerSheet`（列表模式也生效）：右键 → 独立选择器面板（SwiftUI 列表，图标可靠，支持搜索）
- `.nativeMenu`：预览网格右键直接弹原生 NSMenu（AppKit 菜单项原生带图标，
  经 `NativeContextMenuOverlay` 的 hitTest 区分左右键，左键穿透）

背景：SwiftUI 的 contextMenu 不渲染 NSImage/位图形式的菜单图标，只认 SF Symbol——
所以 NSImage 图标只能走普通视图（面板）或 AppKit 原生菜单。

## 文档索引

- `docs/PROTOCOL.md` — MTP over USB 线级协议 + 实测数据 + 踩坑清单
- `docs/ARCHITECTURE.md` — 分层架构与模块职责
- `docs/BUILD.md` — 小白级构建/打包步骤
- `docs/VERSIONING.md` — 版本规范与打包/发布流程（SemVer、落点同步、Release Checklist）
- `docs/TROUBLESHOOTING.md` — 用户侧故障排查 + 缓存清理策略
