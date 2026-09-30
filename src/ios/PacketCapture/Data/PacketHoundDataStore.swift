import Foundation
import TunnelServices

final class PacketHoundDataStore {
    static let shared = PacketHoundDataStore()
    static let didChangeNotification = Notification.Name("PacketHoundDataStoreDidChange")

    private let appGroupIdentifier = "group.com.openminis.app"

    private var configured = false

    private init() {
        installDatabaseChangeObserver()
    }

    func configureIfNeeded() {
        guard !configured else {
            return
        }

        _ = MitmService.configureSharedDatabase(owner: "Main app")
        configured = true
        NSLog("[PH-DEBUG] Main app DB configured")
    }

    /// 在读取数据库前调用，确保能看到 Tunnel 进程写入的数据
    func checkpoint() {
        guard configured else { return }
        let dbPath = MitmService.getDBPath()
        ASConfigration.reconnectDefaultDB(path: dbPath)
        // 诊断：直接查询 task 表
        if let db = try? ASConfigration.getDefaultDB() {
            do {
                let journalMode = try db.scalar("PRAGMA journal_mode") as? String ?? "?"
                let dataVersion = try db.scalar("PRAGMA data_version") as? Int64 ?? -1
                let walResult = try db.scalar("SELECT count(*) FROM task") as? Int64 ?? -1
                // 获取所有 task id
                var ids: [String] = []
                let stmt = try db.prepare("SELECT id FROM task ORDER BY id DESC LIMIT 20")
                for row in stmt {
                    if let id = row[0] as? Int64 {
                        ids.append("\(id)")
                    }
                }
                NSLog("[PH-DEBUG] checkpoint: journal=%@ data_version=%lld task_count=%lld task_ids=[%@]",
                      journalMode, dataVersion, walResult, ids.joined(separator: ","))
            } catch {
                NSLog("[PH-DEBUG] checkpoint query error: %@", error.localizedDescription)
            }
        }
    }

    private func installDatabaseChangeObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let store = Unmanaged<PacketHoundDataStore>.fromOpaque(observer).takeUnretainedValue()
                store.handleExternalDatabaseChange()
            },
            DatabaseDidChangeDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handleExternalDatabaseChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.configured {
                self.checkpoint()
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }

    /// 只统计抓包相关数据的大小（数据库文件 + Task 抓包文件）
    func appGroupUsageBytes() -> UInt64 {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return 0
        }

        var total: UInt64 = 0

        // 数据库文件（.sqlite / -wal / -shm）
        let dbPath = MitmService.getDBPath()
        if !dbPath.isEmpty {
            let dbURL = URL(fileURLWithPath: dbPath)
            total += fileSize(at: dbURL)
            total += fileSize(at: dbURL.appendingPathExtension("wal"))  // dbPath-wal 不对，用下面的方式
            // SQLite WAL/SHM 文件名是 dbPath + "-wal" / "-shm"
            total += fileSize(at: URL(fileURLWithPath: dbPath + "-wal"))
            total += fileSize(at: URL(fileURLWithPath: dbPath + "-shm"))
        }

        // Task 抓包文件夹
        let taskFolder = containerURL.appendingPathComponent("Task", isDirectory: true)
        total += directorySize(at: taskFolder)

        return total
    }

    func clearAllRecords() {
        configureIfNeeded()

        let sessions = Session.findAll(taskID: nil, keyWord: nil, params: nil, pageSize: 1_000_000, pageIndex: 0, orderBy: "id")
        sessions.forEach { try? $0.delete() }

        let frames = WSFrame.findAll(orders: ["id": false])
        frames.forEach { try? $0.delete() }

        let tasks = Task.findAll(pageSize: 100_000, pageIndex: 0, orderBy: "id")
        tasks.forEach { try? $0.delete() }

        removeCapturedFiles()
        vacuumDatabase()
    }

    private func removeCapturedFiles() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }

        let taskFolder = containerURL.appendingPathComponent("Task", isDirectory: true)
        guard FileManager.default.fileExists(atPath: taskFolder.path) else {
            return
        }

        let childURLs = (try? FileManager.default.contentsOfDirectory(
            at: taskFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in childURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 清除记录后压缩数据库，回收磁盘空间
    private func vacuumDatabase() {
        guard let db = try? ASConfigration.getDefaultDB() else { return }
        do {
            try db.execute("VACUUM")
        } catch {
            NSLog("[PH] VACUUM failed: %@", error.localizedDescription)
        }
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return 0 }
        return size
    }

    private func directorySize(at url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            totalSize += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        return totalSize
    }
}
