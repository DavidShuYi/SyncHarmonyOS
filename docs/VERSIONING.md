# 版本与打包规范（Versioning & Release Policy）

本文约束 SyncHarmonyOS 的版本号命名、版本号落点同步、打包产物与发布流程。
后续任何代码迭代、构建、分发**必须遵守**。依据：[Semantic Versioning 2.0.0]、[Keep a Changelog]、Apple Bundle Resources 惯例与本项目既有实践。

## 1. 版本号格式：SemVer 2.0.0

`MAJOR.MINOR.PATCH`（如 `1.2.3`）。当前版本：**1.0.0**。

### 各位何时递增（结合本项目语义）

| 位 | 何时递增 | 本项目的判定标准 |
|---|---|---|
| **MAJOR** | 不兼容变更 | CLI 子命令/参数语义变更或移除；「协议不变量」（见 AGENTS.md）被打破或行为变更；持久化/缓存数据格式不兼容；**最低 macOS 版本提升**；移除已有功能 |
| **MINOR** | 向后兼容的新功能 | 新增 CLI 子命令或 UI 功能；新增设备怪癖适配；新增设置项；新的打包产物形态 |
| **PATCH** | 向后兼容的问题修复 | 崩溃修复、协议兼容性 bug 修复、UI 细节修正、文档勘误 |

规则：

- 有一位递增，其右侧位全部归零（`1.2.3 → 1.3.0`，而不是 `1.2.4`）。
- 拿不准 MINOR 还是 PATCH 时，**升 MINOR**（宁高勿低）。
- 版本号只进不退；**已发布的版本号永不复用**。
- 项目已进入 1.x 稳定期，不再回归 0.x（0.x 允许 MINOR 内含破坏性变更）。

### 预发布版本（可选）

SemVer 预发布后缀，仅用于真机验证/内测构建：
`1.1.0-alpha.1` → `1.1.0-beta.1` → `1.1.0-rc.1` → `1.1.0`

- `alpha`：功能可能残缺、接口可变；`beta`：功能冻结只修 bug；`rc`：发布候选，只做真机验证。
- 预发布版本不对外正式分发，修复后递增序号（`rc.1 → rc.2`）。

### 提交信息与版本的对应（Conventional Commits）

仓库沿用既有惯例：`feat: / fix: / chore: / docs: / refactor: / test:`。
版本判断时：`feat` → MINOR，`fix` → PATCH，`feat!`/`fix!` 或正文含 `BREAKING CHANGE:` → MAJOR。
一次发布包含多类提交时，取**最高**的那一档。

## 2. 版本号落点（必须一次改齐）

版本字符串当前定义于 **5 处**。bump 时必须同步更新（源文件声明头见下方专项规则），任何一处不一致即视为发布失败：

| # | 位置 | 形式 |
|---|---|---|
| 1 | `scripts/build-app.sh`（内联生成 Info.plist） | `CFBundleShortVersionString` 与 `CFBundleVersion` |
| 2 | `scripts/make-dmg.sh` | `VERSION="x.y.z"` |
| 3 | 源文件声明头（仅本次修改/新增的文件） | `//  Version: x.y.z` |
| 4 | `Sources/SyncHarmonyOSApp/Views/SettingsView.swift` 关于页 | `LabeledContent("版本", value: "x.y.z")` |
| 5 | `README.md` 安装/构建章节 | `SyncHarmonyOS-x.y.z.dmg` |

- **单一事实来源 = App 的 `CFBundleShortVersionString`**（用户在「关于」与 Finder 看到的版本），其余落点向它看齐。
- `CFBundleVersion`（构建号）：本项目不经 App Store 分发，保持与 ShortVersion 一致即可；若未来引入持续构建，改为单调递增整数（如 `git rev-list --count HEAD`），**不得回退**。
- **源文件声明头的 Version = 该文件最后一次被改动时所处的版本**，不是全仓统一值：
  - bump 时**只更新本次实际修改过和新增的文件**的声明头；未改动的文件保持旧版本号，不要动；
  - 新增文件声明头直接写发布时的当前版本；
  - 仓库中因此会同时存在多个版本号，这是有意为之（相当于源码级的变更追踪），**禁止"顺手统一"全仓版本头**；
  - 校验方式：发布前用 `git diff --name-only <上一个 tag>` 列出改动文件，逐一核对声明头已是新版本号。
- 推荐演进：新增 `scripts/bump-version.sh x.y.z`，基于 `git diff` 自动更新固定落点与本次改动文件的声明头（实现时以本文档落点表为准）。

## 3. 打包与产物规范

### 产物与命名

| 产物 | 命名 | 说明 |
|---|---|---|
| App | `dist/SyncHarmonyOS.app` | 固定名，不带版本号（版本写在 Info.plist 里） |
| DMG | `dist/SyncHarmonyOS-<version>.dmg` | 预发布如 `SyncHarmonyOS-1.1.0-rc.1.dmg`（预发布后缀是版本串的一部分） |

硬性要求：

- 打包**只允许走脚本**（`build-app.sh` / `make-dmg.sh`），禁止手工拼 bundle 或 `hdiutil` 手打 DMG。
- release 产物必须是 **arm64 + x86_64 通用二进制**；只出单架构必须在发布说明中显式声明原因。
- 最低部署目标 **macOS 13.0**；提升它属于不兼容变更，必须升 MAJOR。
- `dist/`、`*.dmg`、`*.app` 永不入库（`.gitignore` 已覆盖），产物只存在于发布附件。
- ad-hoc 签名为默认形态；未来接入开发者证书/公证不改变本文版本规则。
- 图标由 `scripts/make-icon.swift` 生成，禁止手工替换 `.icns`。

## 4. 发布流程（Release Checklist）

按序执行，任何一步失败即中止：

1. 按 §1 确定新版本号，更新 §2 全部落点；源文件声明头**只更新本次修改/新增的文件**（§2 专项规则），
   用 `git diff --name-only <上一个 tag>` 核对无一遗漏。
2. `swift build && swift test` 全绿（改协议层的发布尤其如此）。
3. `scripts/build-app.sh release` → `open dist/SyncHarmonyOS.app` 能启动，「关于」页版本正确。
4. `scripts/make-dmg.sh` → 产物文件名与新版本一致。
5. 真机 CLI 冒烟：`devices / info / ls / pull / push`。
6. 提交 commit 并打 annotated tag **`v<version>`**（如 `v1.1.0`）；tag 必须打在版本号落点已同步的 commit 上。已推送的 tag 永不移动、永不删除。
7. 发布 Release：标题 `v<version>`，附件挂 DMG，说明按 Keep a Changelog 风格分 **Added / Changed / Fixed / Removed** 四栏撰写。

自下一个版本起，仓库根目录维护 `CHANGELOG.md`（Keep a Changelog 格式，`Unreleased` 区滚动积累），Release 说明直接取自对应小节。
