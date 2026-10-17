# MTP over USB 线级协议

本文记录 SyncHarmonyOS 实现的协议细节，全部来自公开规范（ISO 15740 / USB Still Image Capture Device 规范 / Microsoft MTP 扩展），并附华为鸿蒙平板的实测验证结果。

## 1. 设备侧形态

鸿蒙/安卓手机用 USB 线连接并在手机上选择「传输文件」后，会向主机暴露一个 MTP 接口：

| 字段 | 标准值 | 说明 |
|---|---|---|
| bInterfaceClass | `0x06`（Still-Image）或 `0xFF`（厂商自定义） | 两类都可能是 MTP |
| bInterfaceSubClass | `0x01` | 厂商自定义时常见 `0x02` |
| bInterfaceProtocol | `0x01`（PIMA 15740） | ADB 是 `0xFF/0x42/0x01`，注意排除 |
| 端点 | bulk OUT + bulk IN（+ 可选 interrupt IN） | 三端点结构 |

实测设备（HUAWEI SGT-AL10，鸿蒙）：

```
12D1:1101  HDC Device  class=06/01/01  bulk in=512B out=512B
MTP 扩展串: "microsoft.com: 1.0; openharmony: 1.0;"
```

> `12D1` 是华为的 USB Vendor ID。

## 2. 容器格式

USB 上的一切都是**裸 PTP 容器**——没有 mass-storage BOT 的 CBW/CSW 包装（这是最常见的实现误区）：

```
┌────────────┬──────────┬──────────┬───────────────┬─────────────┐
│ length u32 │ type u16 │ code u16 │ transactionID │ payload     │
│ (含头)     │          │          │ u32           │ (变长)      │
└────────────┴──────────┴──────────┴───────────────┴─────────────┘
        小端序，头固定 12 字节
```

| type | 方向 | 用途 | 大小 |
|---|---|---|---|
| `0x0001` 操作请求 | 主机→设备 | 12 + 4×参数个数 | 最多 32 字节 |
| `0x0002` 数据 | 双向 | 数据阶段（头 + payload） | 变长 |
| `0x0003` 响应 | 设备→主机 | 12 + 4×返回参数 | 最多 32 字节 |
| `0x0004` 事件 | 设备→主机 | 走 interrupt 端点 | 16 字节（本项目未使用） |

### 事务 ID 规则

- OpenSession 的 transactionID **必须为 0**，之后每个操作 +1。
- 同一操作的请求、数据、响应三个容器共用同一个事务 ID。
- 实测踩坑：数据阶段容器头若误用"下一个"事务 ID，设备会在响应里回新 ID，导致 `transaction id 11 != 10` 帧错误。

## 3. 事务时序

```
无数据操作（OpenSession / DeleteObject）:
  主机 → 请求容器
  设备 → 响应容器

入站数据操作（GetDeviceInfo / GetObject）:
  主机 → 请求容器
  设备 → 数据容器（头 + payload，分多个 USB 包）
  设备 → 响应容器

出站数据操作（SendObjectInfo / SendObject）:
  主机 → 请求容器
  主机 → 数据容器
  设备 → 响应容器
```

### 数据阶段的分块与终止

- 主机按 ~16 KiB 块发送/接收（与 Windows 主机节奏一致，兼容性最好）。
- **短包（< maxPacket）即结束**信号。
- 当数据总长恰为 maxPacket（512/1024）整数倍时，用**零长包**显式标记结束——出站方向必须主动补发，入站方向必须容忍并继续等。

实测华为平板 GetDeviceInfo：

```
→ REQ code=0x1001 tx=1 params=[]
← DATA type=0x2 code=0x1001 tx=1 len=361     ← 349 字节数据 + 12 字节头
← RESP code=0x2001 tx=1
```

## 4. 关键操作

| 操作 | code | 参数 → 返回 |
|---|---|---|
| OpenSession | 0x1002 | [sessionID=1] → OK / **0x201E SessionAlreadyOpened**（可继续用） |
| GetDeviceInfo | 0x1001 | [] → DeviceInfo 数据集 |
| GetStorageIDs | 0x1004 | [] → u32 数组 |
| GetStorageInfo | 0x1005 | [storageID] → StorageInfo 数据集 |
| GetObjectHandles | 0x1007 | [storageID, format, parent] → u32 句柄数组（parent=0xFFFFFFFF 表示根） |
| GetObjectInfo | 0x1008 | [handle] → ObjectInfo 数据集 |
| GetObject | 0x1009 | [handle] → 文件字节流 |
| SendObjectInfo | 0x100C | [storageID, parent] + ObjectInfo 数据集 → [storage, **新句柄**] |
| SendObject | 0x100D | 文件字节流 → [句柄]（华为实测有时不返回句柄） |
| DeleteObject | 0x100B | [handle, 0] |
| GetObjectPropValue | 0x9803 | [handle, 0xDC04] → ObjectSize（u64，突破 ObjectInfo 的 4 GB 上限） |

## 5. 数据集布局

### StorageInfo（注意 32/64 位差异！）

```
PTP:        type u16 | fs u16 | access u16 | maxCapacity u32 | free u32 | freeImages u32 | 描述串 | 卷标串
MTP 扩展:   type u16 | fs u16 | access u16 | maxCapacity u64 | free u64 | freeImages u32 | 描述串 | 卷标串
```

实测华为平板返回 **u64 布局**（len=50）。解析器先按 MTP 解析（容量 < 1 PB 合理性校验），失败回退 PTP 布局，两种设备都兼容。

### ObjectInfo（上传时也要构造）

```
storage u32 | format u16 | protection u16 | size u32 | 缩略图 5×u32 |
parent u32 | association u16 | desc u32 | sequence u32 |
文件名 PTPString | 拍摄时间 PTPString | 修改时间 PTPString | 关键词 PTPString
```

- 文件夹 = format `0x3001`（Association）+ associationType `0x0001`（GenericFolder）。
- PTPString = `u8 字符数（含结尾 NUL）+ UTF-16LE 码元 + NUL`。
- 时间格式 `yyyyMMddTHHmmss`。

## 6. 错误响应码（常用）

| code | 名字 | 常见原因 |
|---|---|---|
| 0x2001 | OK | |
| 0x2002 | GeneralError | 设备端异常 |
| 0x2005 | OperationNotSupported | 设备不认识该操作 |
| 0x2009 | StoreFull | 存储满 |
| 0x200A | ObjectWriteProtected | 只读文件 |
| 0x2013 | InvalidObjectHandle | 句柄过期（设备被重新枚举） |
| 0x2019 | DeviceBusy | 设备忙 |
| 0x201E | SessionAlreadyOpened | 会话残留——按规范继续使用即可 |

## 7. USB 层的坑（全部实测踩过）

1. **同步 `ReadPipe` 无超时**：设备不应答时永久阻塞 → 必须用 `ReadPipeAsyncTO`/`WritePipeAsyncTO`，让内核做超时中止。
2. **`ClearPipeStall` ≠ `ClearPipeStallBothEnds`**：前者只重置主机端 data toggle，设备端不知情，之后所有 OUT 包被静默丢弃（症状：写入"成功"但设备永不响应，重插拔才恢复）。后者通过 CLEAR_FEATURE 控制请求让两端同步重置，才是安全恢复。
3. **超时不要清 stall**：普通超时端点并没有 halt，此时清 stall = 主动破坏 toggle 同步。只在真正的停顿错误（`kIOReturnNotResponding` / stall）时恢复。
4. **IOUSBLib 的函数指针表 Swift 不可见**：CFUUID 常量是 C 宏、接口结构体含函数指针表，需要一层 C shim 桥接（本项目 `CUSBShim`）。
5. **异步回调需要事件源**：`CreateInterfaceAsyncPort` + `CreateInterfaceAsyncEventSource`，并在专用线程的 RunLoop 里服务它。

## 8. 传输吞吐

- 16 KiB 分块下，华为平板实测下载 283.8 KB 截图 < 1 s；MTP 单线程协议本身是速度瓶颈（USB 2.0 设备实际约 20–30 MB/s）。
- 提升空间：`GetPartialObject`（0x980C）分段并行拉取——列为路线图。
