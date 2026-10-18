# 故障排查

## 设备侧（手机/平板）

### 「未发现 MTP 设备」

1. **检查手机通知栏**：USB 连接后必须选择「**传输文件**」（有的机型叫「文件传输」「MTP」）。仅充电模式下设备不会暴露 MTP 接口。
2. 换一根**数据线**（部分线只有充电芯线）、换一个 USB 口。
3. 华为设备请关闭「HiSuite 通过 HDB 连接设备」（设置 → 开发者选项），或把 USB 模式从「HiSuite」切到「传输文件」。
4. 用命令验证系统层面能否看到设备：
   ```bash
   /Applications/SyncHarmonyOS.app/Contents/MacOS/syncharmony devices
   ```
   有输出说明枚举正常；没输出说明 USB 层面就没有 MTP 接口。

### 「设备被占用：请先退出 Harmonica…」

USB 的 MTP 接口同一时间只允许**一个**应用独占。退出其他 MTP 软件：

- Harmonica / Android File Transfer / MacDroid / 手动挂载的访达窗口
- 它们常驻后台的话，在 Dock 图标右键退出，或活动监视器搜索进程

### 「设备停止响应 / 传输超时」

1. **解锁手机亮屏**——多数设备息屏后会暂停 MTP 服务。
2. 重新插拔数据线（USB 总线复位能清掉两端的残留状态）。
3. 手机上重选一次「传输文件」模式。
4. 还不行就重启手机/平板的 MTP：切到「仅充电」等 5 秒，再切回「传输文件」。

### 传输中断线

- 大文件传输中不要锁屏（设置 → 显示 → 自动锁定调长）。
- 省电模式可能限制 USB 传输速度。

## Mac 侧

### 首次打开提示「无法验证开发者」

App 未做 Apple 公证（免费分发常见）。**右键点击 App → 打开 → 再点「打开」**，只需一次。

### 上传/下载很慢

MTP 协议本身单线程，速度取决于设备（USB 2.0 设备约 20–30 MB/s 上限）。参见 docs/PROTOCOL.md 第 8 节的优化路线。

### 4 GB 以上大文件

MTP 的 ObjectInfo 大小字段是 32 位（上限 4 GB）。SyncHarmonyOS 会自动尝试 MTP 的 64 位 ObjectSize 属性，但个别老设备不支持——超过 4 GB 的文件传输前先在 `syncharmony info` 里确认设备能力。

## 命令行诊断工具箱

```bash
CLI=/Applications/SyncHarmonyOS.app/Contents/MacOS/syncharmony
$CLI devices          # ① USB 枚举：能看到设备？
$CLI info             # ② 会话层：能打开会话并读到设备信息？
$CLI storages         # ③ 存储层：能列出存储卷？
$CLI ls /             # ④ 文件层：能浏览目录？
SHO_TRACE=1 $CLI ls / # ⑤ 全程线级日志（每个容器一行）
```

哪一步开始失败，问题就在那一层：

| 步骤 | 失败层 | 一般原因 |
|---|---|---|
| ① 无输出 | USB 枚举 | 线/模式/线缆，见上节 |
| ② 失败 | 会话 | 设备被其他应用占用，或设备端 MTP 服务挂起（重插拔） |
| ③④ 失败 | 协议 | 通常是设备状态问题，重插拔后重试 |

## 开发者诊断

源码里有两个内建诊断命令：

```bash
.build/debug/syncharmony diag    # 打开 → OpenSession → 5 秒看门狗读响应
.build/debug/syncharmony diag2   # 完整会话序列分步执行并逐步打印
```

## "打开方式"缓存目录的清理策略

打开方式产生的下载副本存放在 `~/Library/Caches/SyncHarmonyOS/opens/`，由两层策略自动清理：

1. **按年龄**：App 每次启动时，删除**超过 7 天**未被写入的缓存文件。
2. **按总量**：目录总量超过 **1 GB** 时，从最旧的文件开始删除，直到降到限额以内。

此外该目录位于 `~/Library/Caches`，磁盘紧张时 macOS 系统也可能自行回收——App 不依赖缓存文件存在，每次"打开"都会重新下载。想手动清空直接删除该目录即可，无副作用。

## 已知限制（v1.0）

- 不支持 Wi-Fi / SMB 传输（仅 USB MTP）
- 中断端点事件（UDT）未读取——设备主动推送的事件（如对象被手机端删除）不会实时推送，界面手动刷新即可
- 下载不支持断点续传、不支持取消进行中的传输（队列里取消的是未开始的任务）
- 未做 Finder 扩展（Harmonica 的 "Driver" 形态），文件管理在 App 内完成
