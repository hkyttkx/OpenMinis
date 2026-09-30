//
//  LocalSnapshotStore.swift
//  KyTuT
//
//  本地快照：把聊天记录与配置备份到 App Group 容器。
//
//  为什么用 App Group：
//    iOS 在卸载 App 时会连同其沙盒容器一起删除，但 App Group 共享容器
//    只有在「所有使用该 group 的 App 都被删除」后才清理。因此把数据快照
//    放进 group.com.openminis.app 后，卸载重装依然能恢复。
//
//  与既有备份系统的关系：
//    现有 BackupExporter 产出的是加密的 .zip 包，目的地是用户挂载的外部
//    文件夹（iCloud Drive / SMB / WebDAV 等），面向「跨设备 + 归档」。
//    本模块是「本机热备份」：不做加密、不压缩，直接复制一份可用的数据，
//    面向「卸载重装后一键回来」。两者互不冲突，可以同时存在。
//
//  目录布局：
//    group.com.openminis.app/LocalSnapshot/
//      ├── meta.json          快照元信息（时间、大小、包含项）
//      ├── MinisChat/         聊天记录 DB 与每会话目录
//      └── Config/            设置相关的 plist / json
//

import Foundation
import UIKit

// MARK: - 快照元信息

struct LocalSnapshotMeta: Codable {
    var createdAt: Date
    var appVersion: String
    var buildNumber: String
    var totalBytes: Int64
    var itemCount: Int
    var includedNames: [String]
}

// MARK: - 服务

@MainActor
final class LocalSnapshotStore: ObservableObject {

    static let shared = LocalSnapshotStore()

    @Published private(set) var meta: LocalSnapshotMeta?
    @Published private(set) var busy = false
    @Published var lastError: String?
    @Published private(set) var progressText = ""

    private let appGroupID = "group.com.openminis.app"

    private init() {
        meta = loadMeta()
    }

    // MARK: 路径

    /// App Group 容器根
    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 快照根目录
    var snapshotRoot: URL? {
        containerURL?.appendingPathComponent("LocalSnapshot", isDirectory: true)
    }

    private var metaURL: URL? {
        snapshotRoot?.appendingPathComponent("meta.json")
    }

    /// App 沙盒内的数据源（这些是随卸载消失的部分）
    private var libraryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    /// 只纳入聊天记录与 AI 服务商配置。
    /// 不备份挂载状态、宿主访问权限、注入日志、动态库、临时文件。
    /// ProviderConfigDB / provider-config.json 都位于 MinisChat 内，随聊天目录一起备份。
    private var sources: [(name: String, url: URL, isDir: Bool)] {
        let lib = libraryURL
        return [
            ("MinisChat", lib.appendingPathComponent("MinisChat", isDirectory: true), true),
        ]
    }

    // MARK: 元信息读写

    private func loadMeta() -> LocalSnapshotMeta? {
        guard let u = metaURL, let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LocalSnapshotMeta.self, from: d)
    }

    private func saveMeta(_ m: LocalSnapshotMeta) {
        guard let u = metaURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? enc.encode(m) { try? d.write(to: u) }
        meta = m
    }

    // MARK: 状态查询

    /// 是否存在可用快照
    var hasSnapshot: Bool { meta != nil && snapshotRoot.map { FileManager.default.fileExists(atPath: $0.path) } == true }

    /// 容器是否可用（App Group 配置正确）
    var containerAvailable: Bool { containerURL != nil }

    /// 快照时间（供设置页副标题显示）
    func snapshotTimeText() -> String {
        guard let m = meta else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: m.createdAt)
    }

    func snapshotSizeText() -> String {
        guard let m = meta else { return "—" }
        return ByteCountFormatter.string(fromByteCount: m.totalBytes, countStyle: .file)
    }

    // MARK: 创建快照

    func createSnapshot() async {
        guard !busy else { return }
        guard let root = snapshotRoot else {
            lastError = "App Group 容器不可用（entitlements 缺少 group.com.openminis.app）"
            return
        }

        busy = true
        lastError = nil
        defer { busy = false }

        let fm = FileManager.default

        do {
            // 先写到临时目录，成功后整体替换 —— 避免中途失败破坏已有快照
            let staging = root.deletingLastPathComponent()
                .appendingPathComponent("LocalSnapshot.staging", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            var totalBytes: Int64 = 0
            var itemCount = 0
            var included: [String] = []

            for src in sources {
                guard fm.fileExists(atPath: src.url.path) else { continue }
                progressText = "正在备份 \(src.name)…"
                let dst = staging.appendingPathComponent(src.name, isDirectory: src.isDir)
                try copyTree(from: src.url, to: dst, totalBytes: &totalBytes, itemCount: &itemCount)
                included.append(src.name)
            }

            // 写入元信息
            let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
            let m = LocalSnapshotMeta(createdAt: Date(), appVersion: ver, buildNumber: build,
                                      totalBytes: totalBytes, itemCount: itemCount,
                                      includedNames: included)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(m) {
                try d.write(to: staging.appendingPathComponent("meta.json"))
            }

            // 原子替换
            progressText = "正在写入快照…"
            try? fm.removeItem(at: root)
            try fm.moveItem(at: staging, to: root)

            saveMeta(m)
            progressText = ""
        } catch {
            lastError = "创建快照失败：\(error.localizedDescription)"
            progressText = ""
            // 清理 staging
            if let root = snapshotRoot {
                try? fm.removeItem(at: root.deletingLastPathComponent()
                    .appendingPathComponent("LocalSnapshot.staging"))
            }
        }
    }

    private func copyTree(from src: URL, to dst: URL,
                          totalBytes: inout Int64, itemCount: inout Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        guard let en = fm.enumerator(at: src,
                                     includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return }

        for case let item as URL in en {
            let rel = item.path.replacingOccurrences(of: src.path + "/", with: "")
            let target = dst.appendingPathComponent(rel)

            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                // SQLite 的 -wal / -shm 一并带上，避免恢复时丢最近写入
                try? fm.removeItem(at: target)
                try fm.copyItem(at: item, to: target)
                totalBytes += Int64(vals?.fileSize ?? 0)
                itemCount += 1
            }
        }
    }

    // MARK: 恢复快照

    /// 把快照内容写回 App 沙盒。调用方需要在恢复前让相关子系统停用，
    /// 恢复后重启 App 才会完全生效。
    func restoreSnapshot() async -> Bool {
        guard !busy else { return false }
        guard let root = snapshotRoot, hasSnapshot else {
            lastError = "没有可用的本地快照"
            return false
        }

        busy = true
        lastError = nil
        defer { busy = false; progressText = "" }

        let fm = FileManager.default

        for src in sources {
            let snap = root.appendingPathComponent(src.name, isDirectory: src.isDir)
            guard fm.fileExists(atPath: snap.path) else { continue }
            progressText = "正在恢复 \(src.name)…"

            // 备份现有数据（失败可回退）
            if fm.fileExists(atPath: src.url.path) {
                let bak = src.url.appendingPathExtension("pre-restore")
                try? fm.removeItem(at: bak)
                try? fm.moveItem(at: src.url, to: bak)
            }
            do {
                try fm.createDirectory(at: src.url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: snap, to: src.url)
            } catch {
                lastError = "恢复 \(src.name) 失败：\(error.localizedDescription)"
                // 回退
                if let bak = try? fm.contentsOfDirectory(at: src.url.deletingLastPathComponent(),
                                                         includingPropertiesForKeys: nil)
                    .first(where: { $0.lastPathComponent == src.url.lastPathComponent + ".pre-restore" }) {
                    try? fm.removeItem(at: src.url)
                    try? fm.moveItem(at: bak, to: src.url)
                }
                return false
            }
        }
        return true
    }

    // MARK: 删除快照

    func deleteSnapshot() {
        guard let root = snapshotRoot else { return }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: metaURL ?? root)
        meta = nil
    }

    // MARK: 导出 / 导入（文件形式）

    /// 流式生成 ZIP，返回临时文件路径。
    /// 不使用 FileWrapper 直接包装 2GB 目录，避免 iOS 在导出时内存暴涨闪退。
    func makeExportZip() async -> URL? {
        guard let root = snapshotRoot, hasSnapshot else {
            lastError = "没有可用的本地快照"
            return nil
        }
        busy = true
        defer { busy = false }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("KyTuT-Snapshot-\(Int(Date().timeIntervalSince1970)).zip")
        do {
            try? FileManager.default.removeItem(at: out)
            let writer = try BackupZipWriter(url: out)
            var items: [(source: URL, name: String)] = []
            let fm = FileManager.default
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in en {
                    let v = try? file.resourceValues(forKeys: [.isRegularFileKey])
                    guard v?.isRegularFile == true else { continue }
                    let rel = file.path.replacingOccurrences(of: root.path + "/", with: "")
                    items.append((file, rel))
                }
            }
            progressText = "正在流式打包 \(items.count) 个文件…"
            try writer.addFiles(items)
            try writer.close()
            progressText = ""
            return out
        } catch {
            progressText = ""
            lastError = "导出失败：\(error.localizedDescription)"
            try? FileManager.default.removeItem(at: out)
            return nil
        }
    }

    /// 从外部路径导入快照（覆盖当前快照）
    func importSnapshot(from source: URL) async -> Bool {
        busy = true
        defer { busy = false }

        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let root = snapshotRoot else {
            lastError = "App Group 容器不可用"
            return false
        }

        // 允许用户选择的是快照目录本身，或包含 meta.json 的目录
        var src = source
        if !fm.fileExists(atPath: src.appendingPathComponent("meta.json").path) {
            // 若选中的是父目录，尝试找里面的 LocalSnapshot
            let nested = src.appendingPathComponent("LocalSnapshot")
            if fm.fileExists(atPath: nested.appendingPathComponent("meta.json").path) {
                src = nested
            } else {
                lastError = "所选位置不是有效的快照（缺少 meta.json）"
                return false
            }
        }

        do {
            let staging = root.deletingLastPathComponent()
                .appendingPathComponent("LocalSnapshot.importing", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: src, to: staging)

            try? fm.removeItem(at: root)
            try fm.moveItem(at: staging, to: root)

            meta = loadMeta()
            return meta != nil
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
            return false
        }
    }
}
