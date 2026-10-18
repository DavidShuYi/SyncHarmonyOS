// OpenCacheJanitor.swift — retention policy for the "Open With" download cache.
//
// Policy:
//   1. Age: files untouched for `maxAge` are removed at app launch.
//   2. Size cap: when the directory total exceeds `maxTotalBytes`, the
//      oldest files are removed first until under the cap.
// The cache is a viewing-copy convenience only; the app re-downloads on
// every open request and never assumes a cached file exists.

import Foundation

public enum OpenCacheJanitor {
    /// 默认保留 7 天。
    public static let defaultMaxAge: TimeInterval = 7 * 24 * 3600
    /// 默认总量上限 1 GB。
    public static let defaultMaxTotalBytes: UInt64 = 1_000_000_000

    /// App 的"打开方式"缓存目录。
    public static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("SyncHarmonyOS/opens", isDirectory: true)
    }

    /// 后台异步清理（App 启动时调用，不阻塞主线程）。
    public static func cleanAsync() {
        DispatchQueue.global(qos: .utility).async {
            clean()
        }
    }

    /// 执行一次清理，返回删除的文件数与释放的字节数。
    @discardableResult
    public static func clean(directory: URL = OpenCacheJanitor.directory,
                             now: Date = Date(),
                             maxAge: TimeInterval = OpenCacheJanitor.defaultMaxAge,
                             maxTotalBytes: UInt64 = OpenCacheJanitor.defaultMaxTotalBytes)
        -> (removedFiles: Int, freedBytes: UInt64) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return (0, 0)
        }

        struct Item {
            let url: URL
            let date: Date
            let size: UInt64
        }

        var items: [Item] = files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Item(url: url,
                        date: values?.contentModificationDate ?? now,
                        size: UInt64(max(0, values?.fileSize ?? 0)))
        }

        var removedFiles = 0
        var freedBytes: UInt64 = 0

        // 1) 按年龄清理。
        var survivors: [Item] = []
        for item in items {
            if now.timeIntervalSince(item.date) > maxAge {
                try? fileManager.removeItem(at: item.url)
                removedFiles += 1
                freedBytes += item.size
            } else {
                survivors.append(item)
            }
        }

        // 2) 按总量上限清理：最旧的先删（LRU）。
        if survivors.map(\.size).reduce(0, +) > maxTotalBytes {
            survivors.sort { $0.date < $1.date }
            var total = survivors.reduce(UInt64(0)) { $0 + $1.size }
            while total > maxTotalBytes, let oldest = survivors.first {
                try? fileManager.removeItem(at: oldest.url)
                total -= oldest.size
                removedFiles += 1
                freedBytes += oldest.size
                survivors.removeFirst()
            }
        }

        items.removeAll()
        return (removedFiles, freedBytes)
    }
}
