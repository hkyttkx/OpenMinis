//
//  RelayQuotaService.swift
//  KyTuT
//
//  中转站（Relay）多账号管理 + 余额 / 用量查询。
//
//  站点接口契约（1for.cc 这类自研 Relay 网关）：
//    API 前缀          /api/v1
//    登录              POST /auth/login      {email, password}
//                      → {access_token, refresh_token, expires_in, user}
//    刷新              POST /auth/refresh    {refresh_token}
//    当前用户/余额     GET  /auth/me         → {balance, quota, ...}
//    用量              GET  /usage
//    公开设置          GET  /settings/public （无需认证）
//
//    用户侧请求需带 `X-User-UI-Request: 1`；GET 需带 timezone 参数
//    （服务端按 timezone 做分组统计，缺失会导致部分字段为空）。
//
//  凭据策略：
//    登录密码只用于换取令牌，不落盘；
//    每个账号在 Keychain 单独保存 refresh_token（以账号 id 为 account key）。
//    可随时在网页后台「撤销所有会话」使其失效。
//
//  多账号：每个账号独立保存站点、邮箱、令牌与最近余额，互不影响。
//

import Foundation
import Security

// MARK: - 账号条目

struct RelayAccountEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String = ""
    var siteURL: String = ""
    var email: String = ""
    var cachedBalance: Double?
    var lastUpdated: Date?

    var displayLabel: String {
        if !label.isEmpty { return label }
        if let at = email.firstIndex(of: "@") { return String(email[..<at]) }
        return email.isEmpty ? siteURL : email
    }

    var balanceText: String {
        cachedBalance.map { String(format: "$%.2f", $0) } ?? "—"
    }

    /// 站点短名（去掉协议与前缀）
    var siteShort: String {
        siteURL.replacingOccurrences(of: "https://", with: "")
              .replacingOccurrences(of: "http://", with: "")
              .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - 账户数据

struct RelayAccount: Codable {
    var balance: Double?
    var quota: Double?
    var usedQuota: Double?
    var todayCost: Double?
    var totalCost: Double?
    var todayRequests: Int?
    var totalRequests: Int?
    var todayTokens: Int?
    var totalTokens: Int?
    var rpm: Int?
    var tpm: Int?
    var avgResponseSeconds: Double?
    var email: String?
    var username: String?
    var subscription: String?
    var rawText: String?
    /// 累计充值（/auth/me 的 total_recharged）
    var totalRecharged: Double?

    enum CodingKeys: String, CodingKey {
        case balance, quota, username, email, rpm, tpm, subscription
        case usedQuota = "used_quota"
        case todayCost = "today_cost"
        case totalCost = "total_cost"
        case todayRequests = "today_requests"
        case totalRequests = "total_requests"
        case todayTokens = "today_tokens"
        case totalTokens = "total_tokens"
        case avgResponseSeconds = "avg_response_time"
    }
}

struct RelayUsage {
    // 汇总（来自 /usage/dashboard/stats + /usage/stats）
    var todayRequests = 0
    var totalRequests = 0
    var todayCost: Double = 0
    var totalCost: Double = 0          // 计费口径（cost）
    var totalActualCost: Double = 0    // 实付口径（actual_cost）
    var todayTokens = 0
    var totalTokens = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0               // cache_read
    var cacheCreationTokens = 0
    var rpm = 0
    var tpm = 0
    var avgResponseSeconds: Double = 0
    var totalAPIKeys = 0
    var activeAPIKeys = 0

    // 分组维度
    var byPlatform: [RelayGroupRow] = []
    var byModel: [RelayGroupRow] = []
    var byEndpoint: [RelayGroupRow] = []
    var trend: [RelayTrendPoint] = []

    var raw = ""
}

/// 按平台 / 模型 / 端点分组的一行
struct RelayGroupRow: Identifiable, Equatable {
    var id: String { name }
    var name: String                 // platform 名 / model 名 / endpoint 名
    var requests: Int = 0
    var tokens: Int = 0
    var cost: Double = 0
    var actualCost: Double = 0
    var todayRequests: Int = 0
    var todayTokens: Int = 0
    var todayCost: Double = 0
}

/// 趋势里的一个点
struct RelayTrendPoint: Identifiable, Equatable {
    var id: String { date }
    var date: String
    var requests: Int = 0
    var tokens: Int = 0
    var cost: Double = 0
    var actualCost: Double = 0
}

enum RelayError: Error, LocalizedError {
    case notConfigured
    case notLoggedIn
    case authFailed(String)
    case http(Int, String)
    case decode(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:     return "尚未配置中转站地址。"
        case .notLoggedIn:       return "尚未登录该账号，请先登录。"
        case .authFailed(let m): return "登录被拒绝（账号或密码不对）。若确信无误，请检查站点地址是否填成了别的站。详情：\(m)"
        case .http(let c, let m):
            let s = m.count > 200 ? String(m.prefix(200)) : m
            return "中转站返回 \(c)：\(s)"
        case .decode(let m):     return "解析响应失败：\(m)"
        case .network(let m):    return "网络错误：\(m)"
        }
    }
}

// MARK: - 服务

@MainActor
final class RelayQuotaService: ObservableObject {

    static let shared = RelayQuotaService()

    /// 全部已配置账号
    @Published private(set) var accounts: [RelayAccountEntry] = []

    /// 当前选中的账号 id
    @Published var selectedId: UUID?

    /// 每个账号的实时数据：[accountId: (account, usage)]
    @Published private(set) var data: [UUID: RelayData] = [:]

    @Published private(set) var refreshing: Set<UUID> = []
    @Published var lastError: String?

    struct RelayData {
        var account: RelayAccount
        var usage: RelayUsage
        var updatedAt: Date
    }

    private static let listKey = "relay.accounts"
    private static let selectedKey = "relay.selectedId"

    private let tokenService = "com.openminis.app.relay"

    /// 内存中的 access token（按账号），不落盘
    private var accessTokens: [UUID: (token: String, expiry: Date)] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([RelayAccountEntry].self, from: d) {
            accounts = list
        }
        if let s = UserDefaults.standard.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: s), accounts.contains(where: { $0.id == id }) {
            selectedId = id
        } else {
            selectedId = accounts.first?.id
        }
    }

    // MARK: 列表维护

    private func persist() {
        if let d = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(d, forKey: Self.listKey)
        }
        if let id = selectedId {
            UserDefaults.standard.set(id.uuidString, forKey: Self.selectedKey)
        }
    }

    func addAccount(siteURL: String, email: String, label: String = "") {
        var e = RelayAccountEntry()
        e.siteURL = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        e.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        e.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts.append(e)
        selectedId = e.id
        persist()
    }

    func removeAccount(_ id: UUID) {
        Keychain.set(service: tokenService, account: id.uuidString, value: nil)
        accounts.removeAll { $0.id == id }
        data.removeValue(forKey: id)
        accessTokens.removeValue(forKey: id)
        refreshing.remove(id)
        if selectedId == id { selectedId = accounts.first?.id }
        persist()
    }

    func updateAccount(_ id: UUID, label: String? = nil, siteURL: String? = nil) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let l = label { accounts[i].label = l }
        if let s = siteURL { accounts[i].siteURL = s }
        // 站点变了，旧令牌作废
        Keychain.set(service: tokenService, account: id.uuidString, value: nil)
        accounts[i].cachedBalance = nil
        accessTokens.removeValue(forKey: id)
        persist()
    }

    func entry(_ id: UUID) -> RelayAccountEntry? {
        accounts.first { $0.id == id }
    }

    var selectedEntry: RelayAccountEntry? {
        selectedId.flatMap { entry($0) }
    }

    var selectedData: RelayData? {
        selectedId.flatMap { data[$0] }
    }

    // MARK: 令牌

    private func refreshToken(_ id: UUID) -> String? {
        Keychain.string(service: tokenService, account: id.uuidString)
    }

    private func setRefreshToken(_ id: UUID, _ t: String?) {
        Keychain.set(service: tokenService, account: id.uuidString, value: t)
    }

    func isLoggedIn(_ id: UUID) -> Bool {
        (refreshToken(id)?.isEmpty == false) || accessTokens[id] != nil
    }

    // MARK: 登录

    @discardableResult
    func login(accountId: UUID, email: String, password: String) async -> Bool {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return false }
        refreshing.insert(accountId)
        lastError = nil
        defer { refreshing.remove(accountId) }

        do {
            let base = apiBase(accounts[idx].siteURL)
            let json = try await post(base: base, path: "/auth/login",
                                      body: ["email": email, "password": password],
                                      token: nil)
            guard let obj = json as? [String: Any] else {
                throw RelayError.decode("登录响应格式异常")
            }
            // 缓存 token
            var tok: (String, Date)?
            if let at = obj["access_token"] as? String {
                let exp = Date().addingTimeInterval((obj["expires_in"] as? Double ?? 3600) - 60)
                tok = (at, exp)
            }
            if let rt = obj["refresh_token"] as? String {
                setRefreshToken(accountId, rt)
            }
            if let t = tok { accessTokens[accountId] = (t.0, t.1) }

            // 更新邮箱（用户可能改了）
            accounts[idx].email = email
            persist()

            // 立即拉一次
            await refresh(accountId)
            return isLoggedIn(accountId)
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func logout(_ id: UUID) {
        setRefreshToken(id, nil)
        accessTokens.removeValue(forKey: id)
        data.removeValue(forKey: id)
        if let i = accounts.firstIndex(where: { $0.id == id }) {
            accounts[i].cachedBalance = nil
            accounts[i].lastUpdated = nil
            persist()
        }
    }

    // MARK: 刷新

    /// 刷新指定账号（默认全部）
    func refresh(_ id: UUID? = nil) async {
        let targets = id.map { [$0] } ?? accounts.map(\.id)
        for t in targets {
            await refreshOne(t)
        }
    }

    private func refreshOne(_ id: UUID) async {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }

        do {
            let base = apiBase(accounts[idx].siteURL)
            let token = try await ensureToken(id: id, base: base)

            var acc = RelayAccount()
            if let me = try await getJSON(base: base, path: "/auth/me", token: token) as? [String: Any] {
                acc = RelayAccount(from: me)
                acc.rawText = Self.pretty(me)
            }

            // 统计接口：dashboard 用的是 /usage/dashboard/*，不是 /usage。
            // /usage 是账单记录列表（分页用），拿它当统计必然全 0。
            // 统计来自三个互补接口（实测确认，2026-10）：
            //   /usage/dashboard/stats   汇总 + by_platform + 平均耗时
            //   /usage/dashboard/trend   每日趋势
            //   /usage/dashboard/models  按模型
            //   /usage/stats             按 endpoint 的汇总（额外补充）
            // 注意：接口里 today_* 与 rpm/tpm 在当天尚无用量时恒为 0，
            // 这是服务端行为，不是解析问题。
            var usage = RelayUsage()
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let today = df.string(from: Date())
            let start30 = df.string(from: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date())
            let rangeQuery = [
                URLQueryItem(name: "start_date", value: start30),
                URLQueryItem(name: "end_date", value: today),
                URLQueryItem(name: "granularity", value: "day"),
            ]

            var rawParts: [String] = []

            // 汇总
            if let st = try? await getJSON(base: base, path: "/usage/dashboard/stats",
                                           token: token, extraQuery: rangeQuery) as? [String: Any] {
                rawParts.append("=== /usage/dashboard/stats ===\n" + Self.pretty(st))
                usage = parseUsage(st)
                usage.byPlatform = parseGroups(st["by_platform"], nameKey: "platform")
            }
            // 趋势
            if let tr = try? await getJSON(base: base, path: "/usage/dashboard/trend",
                                           token: token, extraQuery: rangeQuery) as? [String: Any] {
                rawParts.append("=== /usage/dashboard/trend ===\n" + Self.pretty(tr))
                usage.trend = parseTrend(tr["trend"])
            }
            // 按模型
            if let md = try? await getJSON(base: base, path: "/usage/dashboard/models",
                                           token: token, extraQuery: rangeQuery) as? [String: Any] {
                rawParts.append("=== /usage/dashboard/models ===\n" + Self.pretty(md))
                usage.byModel = parseGroups(md["models"], nameKey: "model")
            }
            // 按端点（/usage/stats 额外提供）
            if let us = try? await getJSON(base: base, path: "/usage/stats",
                                           token: token, extraQuery: rangeQuery) as? [String: Any] {
                rawParts.append("=== /usage/stats ===\n" + Self.pretty(us))
                usage.byEndpoint = parseGroups(us["endpoints"], nameKey: "endpoint")
                // 汇总字段以 dashboard/stats 为准，这里只补空缺
                if usage.totalRequests == 0 {
                    usage.totalRequests = Self.intValue(us["total_requests"]) ?? 0
                }
            }
            usage.raw = rawParts.joined(separator: "\n\n")

            let now = Date()
            data[id] = RelayData(account: acc, usage: usage, updatedAt: now)
            accounts[idx].cachedBalance = acc.balance
            accounts[idx].lastUpdated = now
            persist()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureToken(id: UUID, base: String) async throws -> String {
        if let t = accessTokens[id], Date() < t.expiry, !t.token.isEmpty {
            return t.token
        }
        guard let rt = refreshToken(id), !rt.isEmpty else { throw RelayError.notLoggedIn }

        let json = try await post(base: base, path: "/auth/refresh",
                                  body: ["refresh_token": rt], token: nil)
        guard let obj = json as? [String: Any],
              let at = obj["access_token"] as? String else {
            throw RelayError.authFailed("刷新令牌已失效，请重新登录")
        }
        let exp = Date().addingTimeInterval((obj["expires_in"] as? Double ?? 3600) - 60)
        accessTokens[id] = (at, exp)
        if let newRT = obj["refresh_token"] as? String {
            setRefreshToken(id, newRT)
        }
        return at
    }

    // MARK: 解析

    private func parseUsage(_ d: [String: Any]) -> RelayUsage {
        let flat = Self.flatten(d)
        var u = RelayUsage()

        func iv(_ k: String) -> Int { Self.intValue(flat[k]) ?? 0 }
        func dv(_ k: String) -> Double { Self.doubleValue(flat[k]) ?? 0 }

        u.totalRequests   = iv("total_requests")
        u.todayRequests   = iv("today_requests")
        u.totalTokens     = iv("total_tokens")
        u.todayTokens     = iv("today_tokens")
        u.inputTokens     = iv("total_input_tokens") != 0 ? iv("total_input_tokens") : iv("input_tokens")
        u.outputTokens    = iv("total_output_tokens") != 0 ? iv("total_output_tokens") : iv("output_tokens")
        u.cachedTokens    = iv("total_cache_read_tokens") != 0 ? iv("total_cache_read_tokens") : iv("cache_read_tokens")
        u.cacheCreationTokens = iv("total_cache_creation_tokens") != 0
            ? iv("total_cache_creation_tokens") : iv("cache_creation_tokens")
        u.totalCost       = dv("total_cost")
        u.totalActualCost = dv("total_actual_cost")
        u.todayCost       = dv("today_actual_cost") != 0 ? dv("today_actual_cost") : dv("today_cost")
        u.totalAPIKeys    = iv("total_api_keys")
        u.activeAPIKeys   = iv("active_api_keys")
        u.rpm             = iv("rpm")
        u.tpm             = iv("tpm")

        // 服务端给的是毫秒
        let avgMs = dv("average_duration_ms")
        if avgMs > 0 { u.avgResponseSeconds = avgMs / 1000 }
        return u
    }

    /// 解析 by_platform / models / endpoints 这类分组数组。
    /// 三种来源的键名不同（platform/model/endpoint），但数值键一致。
    private func parseGroups(_ raw: Any?, nameKey: String) -> [RelayGroupRow] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let name = item[nameKey] as? String, !name.isEmpty else { return nil }
            var r = RelayGroupRow(name: name)
            r.requests   = Self.intValue(item["total_requests"]) ?? Self.intValue(item["requests"]) ?? 0
            r.tokens     = Self.intValue(item["total_tokens"]) ?? Self.intValue(item["tokens"]) ?? 0
            r.cost       = Self.doubleValue(item["total_cost"]) ?? Self.doubleValue(item["cost"]) ?? 0
            r.actualCost = Self.doubleValue(item["total_actual_cost"]) ?? Self.doubleValue(item["actual_cost"]) ?? 0
            r.todayRequests = Self.intValue(item["today_requests"]) ?? 0
            r.todayTokens   = Self.intValue(item["today_tokens"]) ?? 0
            r.todayCost     = Self.doubleValue(item["today_actual_cost"]) ?? 0
            return r
        }
    }

    private func parseTrend(_ raw: Any?) -> [RelayTrendPoint] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let d = item["date"] as? String else { return nil }
            var t = RelayTrendPoint(date: d)
            t.requests   = Self.intValue(item["requests"]) ?? 0
            t.tokens     = Self.intValue(item["total_tokens"]) ?? 0
            t.cost       = Self.doubleValue(item["cost"]) ?? 0
            t.actualCost = Self.doubleValue(item["actual_cost"]) ?? 0
            return t
        }
    }

    private static func intValue(_ v: Any?) -> Int? {
        guard let v else { return nil }
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }

    private static func doubleValue(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// 把嵌套字典摊平：顶层键优先，子字典的键补进空缺。
    /// 网关有的接口把统计包在子对象里，摊平后 `total_requests` 这类键
    /// 无论嵌几层都能命中。
    private static func flatten(_ d: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        var nested: [[String: Any]] = []
        for (k, v) in d {
            if let sub = v as? [String: Any] {
                nested.append(sub)
            } else {
                out[k] = v
            }
        }
        let preferred = ["stats", "summary", "usage", "data", "totals", "total", "today"]
        nested.sort { a, b in
            let ai = preferred.firstIndex { a[$0] != nil } ?? Int.max
            let bi = preferred.firstIndex { b[$0] != nil } ?? Int.max
            return ai < bi
        }
        for sub in nested {
            for (k, v) in flatten(sub) where out[k] == nil { out[k] = v }
        }
        return out
    }

    private static func pretty(_ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: 请求

    /// 探测某个地址是否是本类网关。
    ///
    /// 背景：同一套网关可以挂多个域名，用户必须自己填对。
    /// 但填错时服务端只会回一个含糊的认证失败，
    /// 看起来像「账号加不了」。这里先打公开设置接口，
    /// 能区分「地址不对」和「账号密码不对」两种情况。
    func probeSite(_ raw: String) async -> Result<String, String> {
        let base = apiBase(raw)
        guard let url = URL(string: base + "/settings/public") else {
            return .failure("地址格式不正确：\(raw)")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.timeoutInterval = 20
        r.setValue("1", forHTTPHeaderField: "X-User-UI-Request")
        r.setValue("KyTuT", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard let http = resp as? HTTPURLResponse else {
                return .failure("无响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure("该地址返回 HTTP \(http.statusCode)，不是有效的中转站入口。")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("该地址返回的不是网关数据，请检查站点地址。")
            }
            // 本类网关的公开设置一定是 {code:0, data:{...}}
            if obj["code"] as? Int == 0, obj["data"] is [String: Any] {
                return .success(apiBase(raw).replacingOccurrences(of: "/api/v1", with: ""))
            }
            return .failure("该地址不像中转站网关（缺少 code/data 结构），请检查站点地址。")
        } catch {
            return .failure("无法连接：\(error.localizedDescription)")
        }
    }

    /// 规范化站点地址：补协议、去尾斜杠。
    static func normalizeSite(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func apiBase(_ site: String) -> String {
        // 不再回退到某个具体站点：填错就是填错，不能悄悄连到别处。
        Self.normalizeSite(site) + "/api/v1"
    }

    private func makeRequest(base: String, path: String, method: String, token: String?) throws -> URLRequest {
        guard let url = URL(string: base + path) else {
            throw RelayError.network("无效地址：\(base + path)")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("1", forHTTPHeaderField: "X-User-UI-Request")
        r.setValue("KyTuT", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 45
        if let token {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func post(base: String, path: String, body: [String: Any], token: String?) async throws -> Any {
        var r = try makeRequest(base: base, path: path, method: "POST", token: token)
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(r)
    }

    private func getJSON(base: String, path: String, token: String,
                         extraQuery: [URLQueryItem] = []) async throws -> Any {
        var r = try makeRequest(base: base, path: path, method: "GET", token: token)
        if var comps = URLComponents(url: r.url!, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "timezone",
                                      value: String(TimeZone.current.secondsFromGMT() / 60)))
            items.append(contentsOf: extraQuery)
            comps.queryItems = items
            if let u = comps.url { r.url = u }
        }
        return try await send(r)
    }

    private func send(_ r: URLRequest) async throws -> Any {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: r)
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw RelayError.network("无响应") }
        let text = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RelayError.authFailed(text) }
            throw RelayError.http(http.statusCode, text)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return ["raw": text]
        }
        if let dict = obj as? [String: Any], let code = dict["code"] as? Int {
            if code == 0 { return dict["data"] ?? dict }
            throw RelayError.http(code, (dict["message"] as? String) ?? "unknown")
        }
        return obj
    }
}

// MARK: - 宽松解码

extension RelayAccount {
    init(from dict: [String: Any]) {
        self.init()
        func num(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = dict[k] as? Double { return v }
                if let v = dict[k] as? Int { return Double(v) }
                if let s = dict[k] as? String, let v = Double(s) { return v }
            }
            return nil
        }
        func int(_ keys: [String]) -> Int? {
            for k in keys {
                if let v = dict[k] as? Int { return v }
                if let v = dict[k] as? Double { return Int(v) }
                if let s = dict[k] as? String, let v = Int(s) { return v }
            }
            return nil
        }
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = dict[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        balance = num(["balance", "remaining", "amount", "credit"])
        quota = num(["quota", "total_quota", "limit"])
        usedQuota = num(["used_quota", "usedQuota", "used"])
        todayCost = num(["today_cost", "todayCost", "today_used"])
        totalCost = num(["total_cost", "totalCost", "total_used"])
        todayRequests = int(["today_requests", "todayRequests"])
        totalRequests = int(["total_requests", "totalRequests", "request_count"])
        todayTokens = int(["today_tokens", "todayTokens"])
        totalTokens = int(["total_tokens", "totalTokens"])
        rpm = int(["rpm"])
        tpm = int(["tpm"])
        avgResponseSeconds = num(["avg_response_time", "avgResponseTime"])
        email = str(["email"])
        username = str(["username", "name", "display_name"])
        subscription = str(["subscription", "plan", "group"])
        totalRecharged = num(["total_recharged"])
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balance = try? c.decodeIfPresent(Double.self, forKey: .balance)
        quota = try? c.decodeIfPresent(Double.self, forKey: .quota)
        usedQuota = try? c.decodeIfPresent(Double.self, forKey: .usedQuota)
        todayCost = try? c.decodeIfPresent(Double.self, forKey: .todayCost)
        totalCost = try? c.decodeIfPresent(Double.self, forKey: .totalCost)
        todayRequests = try? c.decodeIfPresent(Int.self, forKey: .todayRequests)
        totalRequests = try? c.decodeIfPresent(Int.self, forKey: .totalRequests)
        todayTokens = try? c.decodeIfPresent(Int.self, forKey: .todayTokens)
        totalTokens = try? c.decodeIfPresent(Int.self, forKey: .totalTokens)
        rpm = try? c.decodeIfPresent(Int.self, forKey: .rpm)
        tpm = try? c.decodeIfPresent(Int.self, forKey: .tpm)
        avgResponseSeconds = try? c.decodeIfPresent(Double.self, forKey: .avgResponseSeconds)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        subscription = try? c.decodeIfPresent(String.self, forKey: .subscription)
        rawText = nil
    }
}

// MARK: - Keychain 小工具

enum Keychain {
    static func set(service: String, account: String, value: String?) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func string(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
