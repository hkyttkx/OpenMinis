//
//  AIChatViewModel+HostFileTools.swift
//  KyTuT
//
//  AI 工具：host_file
//  直读手机上的任意文件与文件夹（含已安装 App 的二进制、数据容器），
//  不受系统文件只读限制：读写删由 HostFileAccess 的路径策略决定。
//
//  实现依据：参考实现（AppFetchHelper）从不挂载，直接以 App 身份
//  NSFileManager 读写 —— 依赖 entitlements 的 no-sandbox 等权限。
//

import Foundation

extension AIChatViewModel {

    /// action:
    ///   list_apps          列出所有已安装 App 与包路径
    ///   container          解析某个 App 的数据容器路径
    ///   ls                 列目录
    ///   read               读文件（小文件内联，大文件自动投递到沙盒）
    ///   write              写文件（系统路径拒绝）
    ///   rm                 删除（系统路径拒绝）
    ///   deliver            投递文件或目录到沙盒（给 r2 分析）
    ///   search             按文件名在目录内递归搜索
    func executeHostFileTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for host_file.", false)
        }
        let action = (args["action"] as? String)?.lowercased() ?? ""
        func str(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func need(_ k: String) throws -> String {
            guard let v = str(k), !v.isEmpty else {
                throw NSError(domain: "host_file", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "缺少参数 '\(k)'"])
            }
            return v
        }

        // 宿主访问级别门禁
        let level = await MainActor.run { HostAccessManager.shared.level }
        if level == .off {
            return ("宿主访问已关闭。请在「设置 → 开发者 → 宿主访问」中启用。", false)
        }

        do {
            switch action {

            case "list_apps":
                let apps = HostFileAccess.installedAppBundlePaths()
                guard !apps.isEmpty else {
                    return ("未读到已安装 App（可能缺少 no-sandbox / container-manager 权限）。", false)
                }
                let body = apps.map { "\($0.bundleID)\n    \($0.path)" }.joined(separator: "\n")
                return ("共 \(apps.count) 个 App：\n\n\(body)", true)

            case "container":
                let bid = try need("bundle_id")
                guard let p = HostFileAccess.dataContainerPath(bundleID: bid) else {
                    return ("未找到 \(bid) 的数据容器。", false)
                }
                return ("\(bid) 数据容器：\n\(p)", true)

            case "ls":
                let path = try need("path")
                switch HostFileAccess.list(path) {
                case .success(let entries):
                    guard !entries.isEmpty else { return ("目录为空：\(path)", true) }
                    let body = entries.map { e -> String in
                        let icon = e.isDirectory ? "📁" : "📄"
                        let sz = e.isDirectory ? "" : "  \(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))"
                        let ro = e.writable ? "" : "  [只读]"
                        return "\(icon) \(e.name)\(sz)\(ro)"
                    }.joined(separator: "\n")
                    let roNote = HostFileAccess.isSystemCritical(path) ? "\n\n（该位置为系统路径，只读）" : ""
                    return ("\(path) 共 \(entries.count) 项：\n\n\(body)\(roNote)", true)
                case .failure(let e):
                    return ("Error: \(e.localizedDescription)", false)
                }

            case "read":
                let path = try need("path")
                switch HostFileAccess.read(path) {
                case .success(let r):
                    if let text = r.text {
                        let cut = text.count > 60_000 ? String(text.prefix(60_000)) + "\n…（已截断）" : text
                        return ("\(path)（\(r.size) 字节）：\n\n\(cut)", true)
                    }
                    return ("已投递到沙盒（\(r.size) 字节，二进制或大文件）：\n\(r.delivered ?? "?")\n\n可直接用 r2_execute / binutils_query 分析该路径。", true)
                case .failure(let e):
                    return ("Error: \(e.localizedDescription)", false)
                }

            case "write":
                let path = try need("path")
                let content = (args["content"] as? String) ?? ""
                if let reason = await writeGuardError(for: path) {
                    return (reason, false)
                }
                // 整盘档位下，每次写入都要用户确认
                let wd = await WriteConfirmationCenter.shared.requestApproval(
                    operation: "写入文件",
                    path: path,
                    contentSize: content.count,
                    preview: String(content.prefix(200)),
                    reason: (args["reason"] as? String)
                )
                switch wd {
                case .approved:
                    break
                case .denied:
                    return ("用户拒绝了对 \(path) 的写入。", false)
                case .timedOut:
                    return ("写入确认超时（用户未响应），已取消：\(path)", false)
                }
                switch HostFileAccess.write(path, content: content) {
                case .success:
                    return ("✅ 已写入 \(path)（\(content.count) 字符）", true)
                case .failure(let e):
                    return ("Error: \(e.localizedDescription)", false)
                }

            case "rm":
                let path = try need("path")
                if let reason = await writeGuardError(for: path) {
                    return (reason, false)
                }
                let wd = await WriteConfirmationCenter.shared.requestApproval(
                    operation: "删除",
                    path: path,
                    reason: (args["reason"] as? String)
                )
                switch wd {
                case .approved: break
                case .denied:   return ("用户拒绝了对 \(path) 的删除。", false)
                case .timedOut: return ("删除确认超时，已取消：\(path)", false)
                }
                switch HostFileAccess.remove(path) {
                case .success:  return ("✅ 已删除 \(path)", true)
                case .failure(let e): return ("Error: \(e.localizedDescription)", false)
                }

            case "deliver":
                let path = try need("path")
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                let r = isDir.boolValue
                    ? HostFileAccess.deliverDirectory(path)
                    : HostFileAccess.deliver(path)
                switch r {
                case .success(let guest):
                    return ("已投递到沙盒：\n\(guest)\n\n可用 r2_execute / binutils_query / file_query 分析。", true)
                case .failure(let e):
                    return ("Error: \(e.localizedDescription)", false)
                }

            case "search":
                let path = try need("path")
                let keyword = (str("keyword") ?? "").lowercased()
                guard !keyword.isEmpty else {
                    throw NSError(domain: "host_file", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "search 需要 keyword"])
                }
                let limit = (args["limit"] as? Int) ?? 200
                var hits: [String] = []
                let fm = FileManager.default
                if let en = fm.enumerator(atPath: path) {
                    for case let rel as String in en {
                        if hits.count >= limit { break }
                        if rel.lowercased().contains(keyword) {
                            hits.append(rel)
                        }
                    }
                }
                guard !hits.isEmpty else { return ("未找到包含「\(keyword)」的项目。", true) }
                return ("匹配 \(hits.count) 项：\n\n" + hits.joined(separator: "\n"), true)

            default:
                return ("""
                Error: 未知 action '\(action)'。

                可用：
                  list_apps   列出所有已安装 App
                  container   解析 App 数据容器（需 bundle_id）
                  ls          列目录（需 path）
                  read        读文件（需 path）
                  write       写文件（需 path、content）
                  rm          删除（需 path）
                  deliver     投递到沙盒供 r2 分析（需 path）
                  search      文件名搜索（需 path、keyword）
                """, false)
            }
        } catch {
            return ("Error: \(error.localizedDescription)", false)
        }
    }
}

// MARK: - 写权限守卫

extension AIChatViewModel {

    /// 判断某个宿主路径当前是否允许写入。
    /// 返回 nil 表示允许；返回字符串表示拒绝原因。
    ///
    /// 规则：
    ///   1. 系统关键路径一律拒绝
    ///   2. 该路径必须落在某个已授权位置内
    ///   3. 该位置的权限必须是「读写」
    func writeGuardError(for path: String) async -> String? {
        if HostFileAccess.isSystemCritical(path) {
            return "系统路径只读，不允许写入：\(path)"
        }
        let mgr = HostAccessManager.shared
        // 找到包含该路径的已授权位置（取最长匹配）
        let hit = await MainActor.run { () -> HostLocation? in
            HostLocation.builtins
                .filter { mgr.isMounted($0) }
                .filter { loc in
                    let root = mgr.resolvedPath(loc)
                    return path == root || path.hasPrefix(root + "/")
                }
                .max { $0.hostPath.count < $1.hostPath.count }
        }
        guard let loc = hit else {
            return "该路径不在任何已授权范围内：\(path)\n请在「设置 → 开发者 → 宿主访问」中开启对应位置。"
        }
        let perm = await MainActor.run { mgr.permission(loc) }
        guard perm == .readWrite else {
            return "\(loc.title) 当前是只读权限，无法写入。\n请在「设置 → 开发者 → 宿主访问」中将其切换为「读写」。"
        }
        return nil
    }
}
