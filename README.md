# SyncHarmonyOS

**Mac ↔ 鸿蒙/安卓 设备 USB 文件传输工具** —— 原生 SwiftUI 应用，纯 Swift 实现 MTP 协议，零第三方依赖。

SyncHarmonyOS 让你在 macOS 上直接浏览、上传、下载鸿蒙（HarmonyOS / OpenHarmony）或安卓手机、平板里的文件，只需一根 USB 数据线。已在 **HUAWEI SGT-AL10（鸿蒙平板）** 上实测通过：浏览中文目录、下载照片、上传文件均正常工作。

```
┌─────────────┐   USB (MTP 协议)   ┌──────────────────┐
│  macOS      │ ◄────────────────► │ HarmonyOS /      │
│  SyncHarmonyOS                   │ Android 设备     │
└─────────────┘                    └──────────────────┘
```

## 功能

- 🔍 **自动发现设备**：插入 USB 后自动扫描 MTP 设备（3 秒轮询）
- 📂 **浏览**：多存储卷（内部存储 / SD 卡）、无限层级目录
- 🔀 **两种视图**：列表模式 / **预览模式**（图片自动加载设备端缩略图，网格展示）
- ⬅️ **前进 / 后退**：工具栏按钮 + ⌘[ / ⌘]，面包屑任意层级可点击直达
- ⬇️ **下载**：选中文件下载到 Mac，实时进度条
- ⬆️ **上传**：拖拽文件进窗口，或 ⌘O 选择文件上传
- 🗑️ **删除 / 新建文件夹**：设备端文件管理
- 📊 **传输队列**：串行队列 + 实时进度 + 失败原因展示
- 💻 **CLI 工具**：`syncharmony` 命令行，可脚本化使用
- 🛡️ **健壮性**：30 秒 I/O 看门狗、端点停顿自动恢复（ClearPipeStallBothEnds）、超时不损坏 USB 状态

## 系统要求

| 项目 | 要求 |
|---|---|
| Mac | macOS 13.0+（Apple Silicon 或 Intel） |
| 设备 | HarmonyOS 2+ / OpenHarmony / Android 4+，支持 MTP |
| 连接 | USB 数据线，手机端选择「传输文件」模式 |

## 安装（普通用户）

1. 双击打开 `dist/SyncHarmonyOS-1.0.0.dmg`
2. 把 **SyncHarmonyOS** 拖入 **Applications** 文件夹
3. 首次打开：右键点击应用 → **打开** → 再点「打开」（绕过 Gatekeeper，因为本应用未公证）
4. 用数据线连接鸿蒙/安卓设备，在**手机通知栏**把 USB 用途切换为「**传输文件**」
5. 应用侧边栏出现设备后点击连接

> ⚠️ 如果提示「设备被占用」，请退出 Harmonica、Android File Transfer 等其他 MTP 软件——USB MTP 接口同一时间只允许一个应用独占。

## 使用

1. **连接**：左侧边栏点击你的设备
2. **浏览**：选择存储卷 → 双击文件夹进入，面包屑可快速跳转
3. **下载**：选中文件 → 工具栏 ⬇️ → 选择保存位置
4. **上传**：把文件从 Finder 拖进窗口，或按 ⌘O
5. **传输队列**：右侧面板实时显示每个任务的进度

### 命令行

```bash
/Applications/SyncHarmonyOS.app/Contents/MacOS/syncharmony devices   # 列出设备
syncharmony info                                                     # 设备信息
syncharmony storages                                                 # 存储卷
syncharmony ls "/内部存储/DCIM"                                      # 列目录
syncharmony pull "/图库/截图/a.jpg" ~/Desktop/a.jpg                  # 下载
syncharmony push ~/a.pdf "/Download"                                 # 上传
syncharmony mkdir "/Download/backup"                                 # 新建文件夹
syncharmony rm "/Download/a.pdf"                                     # 删除
```

设置 `SHO_TRACE=1` 可输出每一次 MTP 事务的线级日志（排障利器）。

## 已验证的设备

| 设备 | 系统 | 结果 |
|---|---|---|
| HUAWEI SGT-AL10（MatePad） | OpenHarmony（MTP 扩展 `openharmony: 1.0`） | ✅ 浏览/下载/上传/删除全部通过 |

理论上支持所有标准 MTP 设备（鸿蒙 / 安卓 / Windows 手机 / 部分相机）。

## 从源码构建（开发者）

```bash
git clone <本仓库> && cd SyncHarmonyOS
swift build                 # 编译（调试版）
swift test                  # 运行 14 个单元测试（含模拟设备全链路测试）
scripts/build-app.sh        # 构建 dist/SyncHarmonyOS.app（通用二进制 + 图标 + 签名）
scripts/make-dmg.sh         # 打包 dist/SyncHarmonyOS-1.0.0.dmg
```

详细的小白级步骤见 [docs/BUILD.md](docs/BUILD.md)。

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 分层架构与模块职责
- [docs/PROTOCOL.md](docs/PROTOCOL.md) —— MTP over USB 线级协议详解（含实测抓包数据）
- [docs/BUILD.md](docs/BUILD.md) —— 开发、编译、打包、安装步骤
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) —— 常见问题与排障

## 技术要点

- **协议**：MTP / PTP（ISO 15740 + USB Still Image 类规范 + MTP 扩展），bulk 端点裸容器传输（无 BOT/CBW）
- **USB 层**：IOKit 用户态 IOUSBLib CFPlugin API（Swift 不可直接调用其函数指针表，通过一层 C shim 桥接），异步 IO + 内核超时（`ReadPipeAsyncTO`）
- **架构**：`SyncHarmonyCore`（协议栈，平台无关核心）+ SwiftUI App + CLI 三端复用
- **测试**：模拟 MTP 设备的完整会话测试（请求帧、事务 ID、流式传输、错误路径），14 个用例

## 与 Harmonica 的关系

本项目受 [Harmonica](https://apps.apple.com/)（Mac App Store 收费 MTP 客户端）启发。通过 REA 对其做了黑盒结构分析（确认其使用 libmtp/libusb + SwiftUI + File Provider 扩展），但 **SyncHarmonyOS 未复制其任何代码或资源**——协议栈按公开的 MTP/PTP 规范全新实现（clean-room），UI 为原创设计。

## 许可

MIT —— 见 [LICENSE](LICENSE)。

仅供学习研究和自己设备间合法传输文件使用。
