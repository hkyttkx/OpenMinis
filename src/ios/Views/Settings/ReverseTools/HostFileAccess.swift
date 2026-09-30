//
//  HostFileAccess.swift
//  KyTuT
//
//  宿主文件访问（直读模式）。
//
//  设计依据（来自参考实现 AppFetchHelper 的验证做法）：
//    参考实现从不挂载任何东西 —— App 进程凭 entitlements
//    (no-sandbox / storage.AppBundles / storage.AppDataContainers)
//    直接用 NSFileManager 读 /var/containers/... 与任意宿主路径。
//    读到的文件按需复制到 App 沙盒，再交给 iSH 内的分析工具。
//
//  为什么不用 iSH bind mount：
//    bind mount 是给 iSH 沙盒（fakefs）用的通道，App 自身读取不需要它。
//    之前把两者混在一起，导致挂载点元数据注册不完整时返回 EINVAL(-22)，
//    而 App 明明有权限直读。直读彻底避开这个问题。
//
//  权限策略：
//    - 系统关键位置（/、/System、/usr、越狱根、App 安装包）→ 只读
//    - App 数据容器 / App Group / 用户目录               → 可读改写
//
//  AI 使用方式：
//    1. host_explore  列目录
//    2. host_read     读文件（小文件直接返回内容）
//    3. host_deliver  投递到沙盒（大文件/二进制交给 r2 分析）
//

import Foundation
import UIKit

enum HostFileAccess {

    /// 投递根目录（沙盒内，iSH 可读）
    static let guestRoot = "/var/minis/workspace/host"

    private static var hostRoot: URL { URL(fileURLWithPath: guestRoot) }

    // MARK: - 只读判定

    /// 系统关键路径：只读，禁止写入
    static func isSystemCritical(_ path: String) -> Bool {
        let p = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        let prefixes = [
            "/System", "/usr", "/bin", "/sbin", "/etc", "/var/jb",
            "/AppleInternal", "/Developer",
            "/var/containers/Bundle/Application",   // App 安装包只读
        ]
        if p == "/" { return true }
        for pre in prefixes where p == pre || p.hasPrefix(pre + "/") { return true }
        return false
    }

    // MARK: - 目录列举

    struct Entry {
        var name: String
        var path: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date?
        var writable: Bool
    }

    /// 列出目录内容
    static func list(_ path: String, limit: Int = 500) -> Result<[Entry], Error> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .failure(NSError(domain: "HostFileAccess", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "路径不存在：\(path)"]))
        }
        guard isDir.boolValue else {
            return .failure(NSError(domain: "HostFileAccess", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "不是目录：\(path)"]))
        }
        do {
            let items = try fm.contentsOfDirectory(atPath: path)
            let readOnly = isSystemCritical(path)
            var out: [Entry] = []
            for name in items.sorted().prefix(limit) {
                let full = (path as NSString).appendingPathComponent(name)
                var sub: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &sub) else { continue }
                let attrs = try? fm.attributesOfItem(atPath: full)
                out.append(Entry(name: name,
                                 path: full,
                                 isDirectory: sub.boolValue,
                                 size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                                 modified: attrs?[.modificationDate] as? Date,
                                 writable: !readOnly))
            }
            return .success(out)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 读文件

    /// 读取文件内容（文本直接返回；二进制返回投递结果）
    static func read(_ path: String, inlineLimit: Int = 256 * 1024) -> Result<(text: String?, delivered: String?, size: Int64), Error> {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return .failure(NSError(domain: "HostFileAccess", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "无法读取：\(path)"]))
        }

        // 小文件尝试按文本内联返回
        if size <= Int64(inlineLimit) {
            if let data = fm.contents(atPath: path) {
                if let s = String(data: data, encoding: .utf8) {
                    return .success((s, nil, size))
                }
            }
        }
        // 大文件或二进制：投递到沙盒
        switch deliver(path) {
        case .success(let guest):
            return .success((nil, guest, size))
        case .failure(let e):
            return .failure(e)
        }
    }

    // MARK: - 写入 / 删除

    static func write(_ path: String, content: String) -> Result<Void, Error> {
        guard !isSystemCritical(path) else {
            return .failure(NSError(domain: "HostFileAccess", code: 4,
                                    userInfo: [NSLocalizedDescriptionKey: "系统路径只读：\(path)"]))
        }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func remove(_ path: String) -> Result<Void, Error> {
        guard !isSystemCritical(path) else {
            return .failure(NSError(domain: "HostFileAccess", code: 5,
                                    userInfo: [NSLocalizedDescriptionKey: "系统路径只读：\(path)"]))
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 投递到沙盒

    /// 把宿主文件复制到沙盒，返回 iSH 可读路径
    static func deliver(_ path: String) -> Result<String, Error> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .failure(NSError(domain: "HostFileAccess", code: 6,
                                    userInfo: [NSLocalizedDescriptionKey: "源文件不存在：\(path)"]))
        }
        // 目标：host/<路径哈希前8位>/<文件名>
        let tag = String(UInt32(truncatingIfNeeded: abs(path.hashValue)), radix: 16)
        let dir = hostRoot.appendingPathComponent(tag, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent((path as NSString).lastPathComponent)
            try? fm.removeItem(at: dst)
            try fm.copyItem(atPath: path, toPath: dst.path)
            chmod(dst.path, 0o644)
            return .success(guestRoot + "/" + tag + "/" + dst.lastPathComponent)
        } catch {
            return .failure(error)
        }
    }

    /// 投递整个目录
    static func deliverDirectory(_ path: String, limit: Int = 2000) -> Result<String, Error> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(NSError(domain: "HostFileAccess", code: 7,
                                    userInfo: [NSLocalizedDescriptionKey: "不是目录：\(path)"]))
        }
        let tag = String(UInt32(truncatingIfNeeded: abs(path.hashValue)), radix: 16)
        let dir = hostRoot.appendingPathComponent(tag, isDirectory: true)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var count = 0
            if let en = fm.enumerator(atPath: path) {
                for case let rel as String in en {
                    if count >= limit { break }
                    let src = (path as NSString).appendingPathComponent(rel)
                    let dst = dir.appendingPathComponent(rel)
                    var sub: ObjCBool = false
                    guard fm.fileExists(atPath: src, isDirectory: &sub) else { continue }
                    if sub.boolValue {
                        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    } else {
                        try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                        try? fm.copyItem(atPath: src, toPath: dst.path)
                        count += 1
                    }
                }
            }
            return .success(guestRoot + "/" + tag)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 常用位置

    /// 已安装 App 的包路径（直读，不挂载）
    static func installedAppBundlePaths() -> [(bundleID: String, path: String)] {
        let base = "/var/containers/Bundle/Application"
        let fm = FileManager.default
        guard let uuids = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        var out: [(String, String)] = []
        for uuid in uuids {
            let dir = (base as NSString).appendingPathComponent(uuid)
            guard let apps = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for app in apps where app.hasSuffix(".app") {
                let p = (dir as NSString).appendingPathComponent(app)
                let plist = (p as NSString).appendingPathComponent("Info.plist")
                let bid = (NSDictionary(contentsOfFile: plist)?["CFBundleIdentifier"] as? String)
                    ?? app.replacingOccurrences(of: ".app", with: "")
                out.append((bid, p))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// App 数据容器路径
    static func dataContainerPath(bundleID: String) -> String? {
        // 通过 container-manager 权限解析
        let fm = FileManager.default
        let base = "/var/mobile/Containers/Data/Application"
        guard let uuids = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for uuid in uuids {
            let meta = (base as NSString).appendingPathComponent(uuid)
                + "/.com.apple.mobile_container_manager.metadata.plist"
            if let d = NSDictionary(contentsOfFile: meta),
               let id = d["MCMMetadataIdentifier"] as? String,
               id == bundleID {
                return (base as NSString).appendingPathComponent(uuid)
            }
        }
        return nil
    }
}
