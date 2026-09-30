//
//  AIChatViewModel+CaptureTools.swift
//  KyTuT
//
//  AI 工具：capture —— 抓包全流程控制与数据读取。
//
//  让 AI 能自主完成：
//    开始抓包 → 打开目标 App → 等待 → 停止 → 读取 → 分析
//

import Foundation
import UIKit
import NetworkExtension

extension AIChatViewModel {

    func executeCaptureTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for capture.", false)
        }
        let action = (args["action"] as? String)?.lowercased() ?? ""
        func str(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ 抓包: \(action)…"
            scrollToBottomSignal.send()
        }

        switch action {

        // ── 状态 ──
        case "status":
            let st = await MainActor.run { () -> String in
                let vm = VPNManager.shared
                let map: [NEVPNStatus: String] = [
                    .invalid: "未配置", .disconnected: "未连接",
                    .connecting: "连接中", .connected: "已连接",
                    .reasserting: "重连中", .disconnecting: "断开中",
                ]
                return "VPN：\(map[vm.status] ?? "未知")"
            }
            return ("\(st)\n\(await caStatusText())", true)

        case "ca_status":
            return (await caStatusText(), true)

        // ── 启停 ──
        case "start":
            await MainActor.run { VPNManager.shared.startVPN() }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let ok = await MainActor.run { VPNManager.shared.status == .connected }
            if ok {
                return ("✅ 抓包已启动（VPN 已连接）。\n\n接下来可用 open_app 打开目标 App，或让用户操作，然后用 sessions / flows 读取抓到内容。", true)
            }
            return ("已发起连接但尚未就绪。用 status 再查；若一直连不上，确认 CA 证书是否已信任。", true)

        case "stop":
            await MainActor.run { VPNManager.shared.stopVPN() }
            return ("✅ 已停止抓包。", true)

        case "open_app":
            guard let bid = str("bundle_id"), !bid.isEmpty else {
                return ("Error: open_app 需要 bundle_id。", false)
            }
            let opened = await MainActor.run { Self.openAppByBundleId(bid) }
            return (opened ? "✅ 已打开 \(bid)。" : "无法打开 \(bid)。", opened)

        // ── 数据 ──
        case "sessions":
            let list = await MainActor.run { CaptureBridge.shared.recentSessions(limit: (args["limit"] as? Int) ?? 30) }
            guard !list.isEmpty else {
                return ("暂无抓包记录。请先用 start 开始抓包，并让目标 App 产生流量。", true)
            }
            let body = list.map { s in
                "\(s.time)  [\(s.method)] \(s.host)\(s.path)  → \(s.statusCode)  \(s.byteCount)B  #\(s.id)"
            }.joined(separator: "\n")
            return ("最近 \(list.count) 条：\n\n\(body)", true)

        case "flows":
            let list = await MainActor.run {
                CaptureBridge.shared.flows(sessionId: str("session"), limit: (args["limit"] as? Int) ?? 50)
            }
            guard !list.isEmpty else { return ("未找到请求记录。", true) }
            let body = list.map { f in
                "\(f.time)  [\(f.method)] \(f.url)  → \(f.statusCode)  \(f.byteCount)B"
            }.joined(separator: "\n")
            return ("共 \(list.count) 条：\n\n\(body)", true)

        case "detail":
            guard let fid = str("id") else { return ("Error: detail 需要 id。", false) }
            guard let d = await MainActor.run(body: { CaptureBridge.shared.detail(id: fid) }) else {
                return ("未找到编号 \(fid) 的记录。", false)
            }
            return (d, true)

        case "search":
            let kw = str("keyword") ?? ""
            guard !kw.isEmpty else { return ("Error: search 需要 keyword。", false) }
            let list = await MainActor.run { CaptureBridge.shared.search(keyword: kw, limit: (args["limit"] as? Int) ?? 50) }
            guard !list.isEmpty else { return ("未找到包含「\(kw)」的请求。", true) }
            let body = list.map { "\($0.time)  [\($0.method)] \($0.url)  → \($0.statusCode)" }
                .joined(separator: "\n")
            return ("匹配 \(list.count) 条：\n\n\(body)", true)

        case "clear":
            await MainActor.run { CaptureBridge.shared.clearAll() }
            return ("✅ 已清空抓包记录。", true)

        default:
            return ("""
            Error: 未知 action '\(action)'。

            可用：
              status     当前 VPN / 证书状态
              ca_status  CA 证书信任状态
              start      开始抓包
              stop       停止抓包
              open_app   打开目标 App（需 bundle_id）
              sessions   列出抓包会话（带时间）
              flows      列出请求记录（可选 session）
              detail     读取单条详情（需 id）
              search     按关键词搜索（需 keyword）
              clear      清空记录
            """, false)
        }
    }

    private func caStatusText() async -> String {
        await MainActor.run {
            let state = CAManager.shared.certificateTrustState()
            switch state {
            case .trusted:
                return "CA 证书：已信任 ✅（可解密 HTTPS）"
            case .generated:
                return "CA 证书：已生成但未信任 ⚠️\n请到「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任。"
            default:
                return "CA 证书：尚未生成 ❓"
            }
        }
    }

    /// 打开指定 App（供抓包时把目标 App 拉到前台）
    static func openAppByBundleId(_ bundleID: String) -> Bool {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as AnyObject? else { return false }
        let sel = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: sel),
              let wsAny = cls.perform(sel)?.takeUnretainedValue(),
              let ws = wsAny as? NSObject else { return false }
        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        guard ws.responds(to: openSel) else { return false }
        _ = ws.perform(openSel, with: bundleID as NSString)
        return true
    }
}
