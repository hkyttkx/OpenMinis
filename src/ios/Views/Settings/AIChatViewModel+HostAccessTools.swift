//
//  AIChatViewModel+HostAccessTools.swift
//  KyTuT
//
//  AI 工具：host_access
//  申请/查询宿主文件系统访问权限，并把授权位置 bind mount 进 iSH 沙盒，
//  使 r2 / binutils / file / strings / sqlite3 能直接读取手机上的原始文件。
//
//  访问级别由用户在「设置 → 挂载外部文件夹 → 宿主访问」选择：
//    off   —— 一律拒绝
//    ask   —— 弹窗确认后放行（本会话记住）
//    auto  —— 常用位置直接放行
//

import Foundation

extension AIChatViewModel {

    /// 参数：
    ///   action   必填，list（查看可用位置与状态）/ request（申请访问）
    ///   location 选填，位置短名（apps / containers / shared / jb / root）
    ///   path     选填，自定义宿主路径（配合 location 为空时使用）
    func executeHostAccessTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for host_access.", false)
        }

        let action = (args["action"] as? String)?.lowercased() ?? "list"
        let locationKey = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customPath = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let manager = await MainActor.run { HostAccessManager.shared }

        // MARK: list
        if action == "list" {
            let desc = await MainActor.run { manager.availableDescription() }
            return ("""
            \(desc)

            说明：
            - 位置挂载后，沙盒里可直接用 /var/minis/host/<短名>/... 访问对应宿主目录
            - 例：app_binary 分析已装 App 时，可直接读
              /var/minis/host/apps/<UUID>/X.app/X
            - 请求访问请调用：host_access 参数 action=request, location=<短名>
            - 访问级别在「设置 → 挂载外部文件夹 → 宿主访问」调整
            """, true)
        }

        // MARK: request
        guard action == "request" else {
            return ("Error: 'action' must be 'list' or 'request'.", false)
        }

        // 解析目标位置
        let loc: HostLocation
        if let key = locationKey, !key.isEmpty {
            guard let found = HostLocation.builtins.first(where: { $0.key == key }) else {
                let keys = HostLocation.builtins.map(\.key).joined(separator: ", ")
                return ("Error: 未知的 location '\(key)'。可用值：\(keys)", false)
            }
            loc = found
        } else if let p = customPath, !p.isEmpty {
            // 自定义路径：临时构造一个 HostLocation（key 由路径派生）
            let safeKey = p.replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            loc = HostLocation(key: safeKey.isEmpty ? "custom" : safeKey,
                               hostPath: p,
                               title: "自定义路径",
                               detail: p)
        } else {
            return ("Error: 'request' 需要 location 或 path 参数之一。", false)
        }

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ 正在申请访问 \(loc.title)…"
            scrollToBottomSignal.send()
        }

        // 交由管理器决策：放行 / 挂起待确认 / 直接拒绝
        let immediate = await MainActor.run { () -> Bool in
            manager.requestAccess(loc, requester: "AI 静态分析")
        }

        if immediate {
            let ok = await MainActor.run { manager.ensureMounted(loc) }
            if ok {
                return ("""
                ✅ 已挂载 \(loc.title)
                沙盒路径：\(loc.guestPath)
                宿主路径：\(loc.hostPath)

                现在可直接用该前缀读取宿主文件，例如：
                  r2_execute file=\(loc.guestPath)/<子路径> commands='aa; afl'
                  binutils_query file=\(loc.guestPath)/<子路径> tool='strings -a'
                """, true)
            }
            return ("⚠️ 已授权但挂载失败。可能原因：路径不存在，或该位置在当前越狱环境下不可访问。\n路径：\(loc.hostPath)", false)
        }

        // 未立即放行 —— 区分「关闭」与「等待确认」
        let level = await MainActor.run { manager.level }
        if level == .off {
            return ("""
            ❌ 宿主访问已被关闭。

            用户可在「设置 → 挂载外部文件夹 → 宿主访问」中切换为「询问后访问」或「全自动访问」。
            在此之前，静态分析只能读取已复制到沙盒的文件。
            """, false)
        }

        return ("""
        ⏸ 已向用户发起访问申请：\(loc.title)
        宿主路径：\(loc.hostPath)

        用户在弹出的确认框批准后，该位置即可通过 \(loc.guestPath) 访问。
        请等待用户确认后重试；若用户拒绝，请改为请用户手动把目标文件复制到沙盒。
        """, false)
    }
}
