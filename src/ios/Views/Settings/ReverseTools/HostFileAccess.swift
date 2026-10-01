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

    /// 投递根目录（iSH 沙盒内可见的路径，回给调用方用）
    static let guestRoot = "/var/minis/workspace/host"

    /// 同一个目录在 **App 进程**里的真实路径。
    ///
    /// 这是之前 deliver 一直报「没有权限写入 host 文件夹」的根因：
    /// App 进程里根本不存在 `/var/minis` —— 它是 iSH fakefs 的视图，
    /// 宿主侧实际位于 App 容器的 `Documents/alpine-rootfs/data/var/minis`。
    /// 拿沙盒 guest 路径去调用 NSFileManager，等于往一个不存在的路径写，
    /// 系统只抛出一个含糊的权限错误。
    ///
    /// `RootfsManager.shared.dataPath` = `Documents/alpine-rootfs/data`，
    /// 也就是 fakefs 的 `/`，因此 fakefs 路径 `/var/...` 对应
    /// `dataPath/var/...`。
    static var hostRoot: URL {
        RootfsManager.shared.dataPath
            .appendingPathComponent("var/minis/workspace/host", isDirectory: true)
    }

    /// 把 iSH 沙盒路径转成 App 进程可用的宿主路径。
    /// 例：`/var/minis/workspace/host/x` → `<dataPath>/var/minis/workspace/host/x`
    ///
    /// 已经是绝对宿主路径（形如 /var/mobile/... 或 /var/containers/...）的原样返回，
    /// 避免双重拼接。
    static func hostURL(forGuestPath path: String) -> URL {
        let dataPrefix = RootfsManager.shared.dataPath.standardized.path
        if path.hasPrefix(dataPrefix) { return URL(fileURLWithPath: path) }
        // 去掉开头的 /，拼到 dataPath 下
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return RootfsManager.shared.dataPath.appendingPathComponent(rel)
    }

    // MARK: - 只读判定

    // MARK: - 写入保护

    /// 无论位于哪里都必须只读的系统目录。
    ///
    /// 写坏这些会直接让系统或越狱无法启动，且 iOS 上没有简单的回退手段，
    /// 所以这里是硬性护栏 —— 不接受任何设置覆盖。
    private static let protectedAbsolutePrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/Library",
        "/Applications", "/private", "/dev", "/cores", "/AppleInternal",
        "/Developer", "/boot", "/mnt", "/proc", "/sys",
        "/var/jb",          // roothide 的越狱根符号区
        "/var/db",          // 系统数据库
        "/var/root",        // root 家目录
    ]

    /// App 安装包目录：只读，但其中的 `.jbroot-*`（越狱根）单独放行，
    /// 因此不能直接塞进上面的前缀表 —— 需要先判越狱根。
    private static let appBundlePrefix = "/var/containers/Bundle/Application"

    /// 越狱根内部同样受保护的系统子目录（相对于越狱根）。
    ///
    /// 实测这台机器的越狱根下有 `System/Library` 与 `usr/{bin,lib,sbin,...}`，
    /// 它们是根文件系统的挂载覆盖层，等同真实的 /System 与 /usr。
    /// 只放开用户数据区（var/mobile、tmp、User 等）。
    private static let protectedInsideJailbreakRoot: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/Library",
        "/Applications", "/private", "/dev", "/cores", "/AppleInternal",
        "/Developer", "/boot", "/var/db", "/var/root", "/var/jb",
    ]

    /// 归一化：去掉 /private 前缀，折叠重复斜杠，去掉末尾斜杠。
    private static func normalizePath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if p.count > 1, p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }

    private static func isUnder(_ path: String, _ prefix: String) -> Bool {
        if prefix == "/" { return path.hasPrefix("/") }
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    /// 该路径是否位于越狱根内；是则返回相对路径（以 / 开头）。
    private static func jailbreakRelativePath(_ p: String) -> String? {
        if let jb = JailbreakInjector.resolveJailbreakRoot(), !jb.isEmpty {
            let j = normalizePath(jb)
            if isUnder(p, j) { return String(p.dropFirst(j.count)) }
        }
        // 解析失败时的兜底：直接识别 .jbroot-<hex> 段
        guard let r = p.range(of: "/.jbroot-") else { return nil }
        let after = p[r.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return "/" }
        return String(after[slash...])
    }

    /// 系统关键路径：只读，禁止写入。
    ///
    /// 分三层判断：
    ///   1. 全局系统目录（/System、/usr、/bin、/etc、/var/db …）→ 只读
    ///   2. 越狱根内部：其中的 /System、/usr 等系统子树 → 只读；
    ///      用户数据区（var/mobile、tmp、User …）→ 允许读写
    ///   3. 其余路径 → 允许（是否真的可写由权限与沙盒决定）
    ///
    /// 之所以要单独处理越狱根：roothide 的越狱环境位于
    /// `/var/containers/Bundle/Application/.jbroot-<hex>`，外层是只读的
    /// App 安装包目录，但内部混放了系统覆盖层与用户数据，
    /// 不能一刀切（全放开会写坏系统，全锁死则用户无法用）。
    static func isSystemCritical(_ path: String) -> Bool {
        let p = normalizePath(path)

        if p == "/" { return true }

        // 1. 越狱根优先判断。
        //    它物理上位于 App 安装包目录之内，若让安装包前缀先匹配，
        //    越狱根里的用户数据（var/mobile、tmp…）会被整体误判为只读。
        if let rel = jailbreakRelativePath(p) {
            let r = rel.isEmpty ? "/" : rel
            if r == "/" { return true }
            for pre in protectedInsideJailbreakRoot where isUnder(r, pre) { return true }
            return false     // 越狱根内的用户数据区：放开
        }

        // 2. App 安装包（越狱根已在上面拦掉）
        if isUnder(p, appBundlePrefix) { return true }

        // 3. 全局系统目录
        for pre in protectedAbsolutePrefixes where isUnder(p, pre) { return true }

        // 4. 其余
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
            // 让 iSH 内以任意用户身份都能读到
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
