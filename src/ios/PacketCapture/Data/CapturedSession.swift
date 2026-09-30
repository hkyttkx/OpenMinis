import Foundation
import TunnelServices

/// 抓包记录的轻量模型，用于 UI 展示
/// 从 TunnelServices 的 Session 数据库读取
struct CapturedSession: Identifiable {
    let id: Int
    let host: String?
    let uri: String?
    let methods: String?
    let schemes: String?
    let statusCode: String?
    let reqHeaders: String?
    let rspHeaders: String?
    let startTime: Double
    let uploadTraffic: Int64
    let downloadFlow: Int64
    
    var timeString: String {
        guard startTime > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: startTime)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }
    
    var uploadSize: String { formatBytes(uploadTraffic) }
    var downloadSize: String { formatBytes(downloadFlow) }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value < 1024 { return "\(Int(value))B" }
        let units = ["KB", "MB", "GB"]
        var size = value / 1024
        var idx = 0
        while size >= 1024, idx < units.count - 1 {
            size /= 1024
            idx += 1
        }
        return String(format: "%.1f%@", size, units[idx])
    }
    
    /// 从 TunnelServices 数据库加载所有 session
    static func loadAll(limit: Int = 500) -> [CapturedSession] {
        // 通过 TunnelServices 的 Session 模型查询
        // 这里直接使用 SQL 查询 shared database
        guard let db = try? ASConfigration.getDefaultDB() else {
            return []
        }
        
        var results: [CapturedSession] = []
        do {
            let sql = "SELECT id, host, uri, methods, schemes, state, reqHeads, rspHeads, startTime, uploadTraffic, downloadFlow FROM session ORDER BY startTime DESC LIMIT \(limit)"
            let stmt = try db.prepare(sql)
            for row in stmt {
                let session = CapturedSession(
                    id: (row[0] as? Int64).map(Int.init) ?? 0,
                    host: row[1] as? String,
                    uri: row[2] as? String,
                    methods: row[3] as? String,
                    schemes: row[4] as? String,
                    statusCode: row[5] as? String,
                    reqHeaders: row[6] as? String,
                    rspHeaders: row[7] as? String,
                    startTime: (row[8] as? Double) ?? 0,
                    uploadTraffic: (row[9] as? Int64) ?? 0,
                    downloadFlow: (row[10] as? Int64) ?? 0
                )
                results.append(session)
            }
        } catch {
            #if DEBUG
            print("[PacketCapture] loadAll error: \(error)")
            #endif
        }
        return results
    }
}
