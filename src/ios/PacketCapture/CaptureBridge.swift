//
//  CaptureBridge.swift
//  KyTuT
//
//  抓包数据桥接：把 TunnelServices 的抓包数据库暴露成简单的查询接口，
//  供 AI 工具（capture）读取与分析。
//
//  数据来源：TunnelServices 的 Session 表（由 PacketTunnel 扩展写入
//  App Group 共享容器，因此主 App 可读）。
//

import Foundation

@MainActor
final class CaptureBridge {

    static let shared = CaptureBridge()

    private init() {}

    // MARK: - 模型

    struct SessionRow {
        let id: Int
        let time: String
        let host: String
        let path: String
        let method: String
        let statusCode: String
        let byteCount: Int64
    }

    struct FlowRow {
        let time: String
        let method: String
        let url: String
        let statusCode: String
        let durationMs: Int
        let byteCount: Int64
    }

    // MARK: - 会话列表

    func recentSessions(limit: Int = 30) -> [SessionRow] {
        let all = CapturedSession.loadAll(limit: max(limit, 200))
        return all.prefix(limit).map { s in
            SessionRow(id: s.id,
                       time: s.timeString,
                       host: s.host ?? "-",
                       path: s.uri ?? "",
                       method: s.methods ?? "",
                       statusCode: s.statusCode ?? "-",
                       byteCount: s.uploadTraffic + s.downloadFlow)
        }
    }

    // MARK: - 请求列表

    func flows(sessionId: String?, limit: Int = 50) -> [FlowRow] {
        var all = CapturedSession.loadAll(limit: 500)
        if let sid = sessionId, let want = Int(sid) {
            all = all.filter { $0.id == want }
        }
        return all.prefix(limit).map { s in
            FlowRow(time: s.timeString,
                    method: s.methods ?? "GET",
                    url: "\(s.schemes ?? "http")://\(s.host ?? "")\(s.uri ?? "")",
                    statusCode: s.statusCode ?? "-",
                    durationMs: 0,
                    byteCount: s.uploadTraffic + s.downloadFlow)
        }
    }

    // MARK: - 单条详情

    func detail(id: String) -> String? {
        guard let want = Int(id) else { return nil }
        let all = CapturedSession.loadAll(limit: 1000)
        guard let s = all.first(where: { $0.id == want }) else { return nil }

        var out = """
        编号：\(s.id)
        时间：\(s.timeString)
        请求：\(s.methods ?? "") \(s.schemes ?? "http")://\(s.host ?? "")\(s.uri ?? "")
        状态：\(s.statusCode ?? "-")
        上行：\(s.uploadSize)  下行：\(s.downloadSize)

        ── 请求头 ──
        \(s.reqHeaders ?? "(无)")
        """
        if let rh = s.rspHeaders, !rh.isEmpty {
            out += "\n\n── 响应头 ──\n\(rh)"
        }
        return out
    }

    // MARK: - 搜索

    func search(keyword: String, limit: Int = 50) -> [FlowRow] {
        let kw = keyword.lowercased()
        let all = CapturedSession.loadAll(limit: 1000)
        return all.filter { s in
            let url = "\(s.schemes ?? "")://\(s.host ?? "")\(s.uri ?? "")".lowercased()
            return url.contains(kw)
                || (s.reqHeaders ?? "").lowercased().contains(kw)
                || (s.rspHeaders ?? "").lowercased().contains(kw)
                || (s.methods ?? "").lowercased().contains(kw)
        }.prefix(limit).map { s in
            FlowRow(time: s.timeString,
                    method: s.methods ?? "GET",
                    url: "\(s.schemes ?? "http")://\(s.host ?? "")\(s.uri ?? "")",
                    statusCode: s.statusCode ?? "-",
                    durationMs: 0,
                    byteCount: s.uploadTraffic + s.downloadFlow)
        }
    }

    // MARK: - 清空

    func clearAll() {
        PacketHoundDataStore.shared.clearAllRecords()
    }
}
