# 架构

SyncHarmonyOS 分为四个 SwiftPM target，依赖自上而下单向流动，协议栈与 UI 完全解耦。

```
┌────────────────────────────────────────────────────┐
│  SyncHarmonyOSApp (SwiftUI)   SyncHarmonyCLI       │  界面层
│  Views / AppModel             子命令 + 路径解析     │
└───────────────┬────────────────────┬───────────────┘
                │                    │
┌───────────────▼────────────────────▼───────────────┐
│                SyncHarmonyCore                     │  核心（平台无关协议栈）
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ Transfer/    │  │ MTP/         │  │ Util/     │ │
│  │ 传输队列      │  │ 会话/模型/常量 │  │ 字节读写   │ │
│  └──────┬───────┘  └──────┬───────┘  └───────────┘ │
│         │          ┌──────▼────────┐                │
│         │          │ Transport/    │                │
│         │          │ PTP 容器帧     │                │
│         │          └──────┬────────┘                │
│  ┌──────▼─────────────────▼───────┐                │
│  │ USB/                           │                │
│  │ USBBulkPipe 协议 + IOKit 实现   │                │
│  └──────────────┬─────────────────┘                │
└─────────────────┼──────────────────────────────────┘
                  │ C 函数
┌─────────────────▼──────────────────────────────────┐
│  CUSBShim (C)                                      │  USB 桥接层
│  IOKit IOUSBLib CFPlugin 用户客户端封装              │
│  （异步事件源 + 内核超时 + 停顿恢复）                 │
└─────────────────┬──────────────────────────────────┘
                  │
            macOS IOKit / USB 硬件
```

## 各层职责

### CUSBShim（C 桥接层）

IOUSBLib 的用户客户端是一张 C 函数指针表（`IOUSBInterfaceInterface300`），Swift 无法直接调用。这一层用纯 C 封装出平铺函数：

| 函数 | 职责 |
|---|---|
| `shimListMTPDevices` | 扫描 IOKit 注册表，过滤 MTP 类接口（06/01/01 或厂商自定义），回读 VID/PID/序列号 |
| `shimOpenByEntryID` | 按注册表 ID 独占打开接口，识别 bulk IN/OUT 管道，启动异步 IO 线程 |
| `shimRead` / `shimWrite` | `ReadPipeAsyncTO` / `WritePipeAsyncTO` + 条件变量等待，**内核级超时** |
| `shimClearStall` | `ClearPipeStallBothEnds`（两端同步重置 data toggle） |
| `shimClose` | 停线程、关接口、释放资源 |

关键设计：
- **专用 RunLoop 线程**：每个连接一个线程服务 `CreateInterfaceAsyncEventSource`，同步 API 的阻塞问题彻底消除。
- **超时由内核执行**：`…AsyncTO(noDataTimeout, completionTimeout)` 到期时内核自己中止请求并回调 `kIOUSBTransactionTimeout`，主机端不触碰端点状态——**绝不手动 ClearPipeStall 普通超时**（会单方面重置 data toggle，设备端不知情，之后所有包被静默丢弃，只能重新插拔恢复）。
- **停顿恢复**：仅对真正的端点停顿（`kIOReturnNotResponding` / stall）调用 `ClearPipeStallBothEnds`，它向设备发 CLEAR_FEATURE 控制请求，两端同步重置 toggle，与 libusb 的恢复策略一致。

### SyncHarmonyCore.USB（Swift USB 抽象）

- `USBBulkPipe`：协议（`read` / `write` / `clearStall` / `close`），把"一对 bulk 端点"抽象出来，让传输层可以在测试里用内存实现替换。
- `IOKitUSBBulkPipe`：shim 的 Swift 封装。串行锁保证 MTP 事务不交错；停顿自动恢复 + 一次重试。
- `USBDeviceScanner`：设备发现。
- `MTPUSBDeviceInfo`：设备元数据（含注册表 ID，作为重开句柄的稳定键）。

### SyncHarmonyCore.Transport（PTP 帧）

`PTPTransport` 实现 USB 上的裸 PTP 容器协议（**没有** mass-storage BOT 的 CBW/CSW）：

```
容器 = length:u32 | type:u16 | code:u16 | transactionID:u32 | payload
type: 1=操作请求  2=数据  3=响应  4=事件
```

- `sendRequest`：发出请求容器。事务 ID 从 0 开始（OpenSession 必须为 0），单调递增。
- `receiveData` / `receiveData(sink:)`：数据阶段。首读拿到容器头（有的设备把 12 字节头单独发包），校验 type/code/tx 后把 payload 流式交给调用方；短包结束传输，零长包按协议处理。
- `sendData`：出站数据阶段。容器头 + 分块 payload（16 KiB，与 Windows 主机节奏一致），总长恰为 maxPacket 整数倍时补零长包。
- `receiveResponse`：读取响应容器，带回最多 5 个 u32 参数。

### SyncHarmonyCore.MTP（会话与模型）

- `MTPSession`：OpenSession / GetDeviceInfo / GetStorageIDs / GetStorageInfo / GetObjectHandles / GetObjectInfo / GetObject（流式下载 + 进度）/ SendObjectInfo + SendObject（流式上传）/ DeleteObject / CreateFolder / GetObjectPropValue（64 位大小探测）/ GetThumb（图片与视频缩略图，布局自动探测：标准 6 字节头或华为的裸 JPEG）。
- `MTPModels`：`MTPDeviceInfo` / `MTPStorage` / `MTPObjectInfo` 数据集解析与编码。**双布局解析**：PTP 的容量字段是 u32，MTP 扩展把它加宽为 u64——先按 MTP 解析（带合理性校验），失败回退 PTP 布局。`sortName` / `sortDate` / `size` 为排序键（默认修改时间倒序）。
- `MTPError`：把设备响应码、USB 错误、本地文件问题统一成用户可读的中文错误。

### SyncHarmonyCore.Transfer（队列）

`TransferManager` + `TransferTask`：串行队列（MTP 不允许并发事务）、ObservableObject 状态机（queued → running → finished/failed/cancelled）、按字节的进度上报。

### 界面层

- **App**（SwiftUI）：三栏布局 = 设备侧边栏 + 文件表格（Table，多选）+ 传输队列；工具栏（根目录/刷新/下载/上传/新建/删除）；拖拽上传；`fileImporter` 选择下载目录。
- **CLI**（`syncharmony`）：`devices / info / storages / ls / pull / push / mkdir / rm / diag / diag2`，`MTPPathResolver` 把 `存储:路径` 解析成句柄，`SHO_TRACE=1` 输出线级日志。

## 线程模型

- UI 全部 `@MainActor`；AppModel 把阻塞的 MTP 调用派发到 `workQueue`（串行），结果回主线程。
- USB I/O 在 shim 的专用 RunLoop 线程完成回调，Swift 侧以信号量语义等待。
- 传输队列独立串行；同一时间设备上只有一个 MTP 事务。

## 测试策略

`Tests/SyncHarmonyCoreTests` 用一个**模拟 MTP 设备**（`MockMTPPipe`：脚本化的容器应答器）做全链路测试，无需真机：

- PTP 字节序 / 字符串 / 数组编解码
- DeviceInfo / ObjectInfo 数据集解析与编码往返
- 完整会话生命周期（打开 → 列存储 → 浏览 → 读对象信息 → 关闭）
- 错误响应映射
- 请求帧精确性（长度、类型、事务 ID、参数）
- 大文件分块流式下载（30 万字节 / 8 KiB 块，验证分块与进度）

真机行为（华为平板）另做了人工验证：浏览中文目录、下载照片（EXIF 完整）、上传随机文件、删除，均通过。
