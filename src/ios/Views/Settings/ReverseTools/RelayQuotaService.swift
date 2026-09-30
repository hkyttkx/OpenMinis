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
    var todayRequests = 0
    var totalRequests = 0
    var todayCost: Double = 0
    var totalCost: Double = 0
    var todayTokens = 0
    var totalTokens = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var rpm = 0
    var tpm = 0
    var avgResponseSeconds: Double = 0
    var raw = ""
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
        case .authFailed(let m): return "认证失败：\(m)"
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
            var usage = RelayUsage()
            if let u = try await getJSON(base: base, path: "/usage", token: token) as? [String: Any] {
                usage = parseUsage(u)
            }

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
        var u = RelayUsage()
        func int(_ keys: [String]) -> Int? {
            for k in keys {
                if let v = d[k] as? Int { return v }
                if let v = d[k] as? Double { return Int(v) }
                if let s = d[k] as? String, let v = Int(s) { return v }
            }
            return nil
        }
        func dbl(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = d[k] as? Double { return v }
                if let v = d[k] as? Int { return Double(v) }
                if let s = d[k] as? String, let v = Double(s) { return v }
            }
            return nil
        }
        u.todayRequests = int(["today_requests", "todayRequests", "today_request_count"]) ?? 0
        u.totalRequests = int(["total_requests", "totalRequests", "request_count"]) ?? 0
        u.todayCost = dbl(["today_cost", "todayCost"]) ?? 0
        u.totalCost = dbl(["total_cost", "totalCost"]) ?? 0
        u.todayTokens = int(["today_tokens", "todayTokens"]) ?? 0
        u.totalTokens = int(["total_tokens", "totalTokens"]) ?? 0
        u.inputTokens = int(["input_tokens", "prompt_tokens"]) ?? 0
        u.outputTokens = int(["output_tokens", "completion_tokens"]) ?? 0
        u.cachedTokens = int(["cached_tokens", "cache_tokens"]) ?? 0
        u.rpm = int(["rpm"]) ?? 0
        u.tpm = int(["tpm"]) ?? 0
        u.avgResponseSeconds = dbl(["avg_response_time", "avgResponseTime", "average_response_time"]) ?? 0
        u.raw = Self.pretty(d)
        return u
    }

    private static func pretty(_ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: 请求

    private func apiBase(_ site: String) -> String {
        var s = site.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "https://1for.cc" }
        if s.hasSuffix("/") { s.removeLast() }
        return s + "/api/v1"
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

    private func getJSON(base: String, path: String, token: String) async throws -> Any {
        var r = try makeRequest(base: base, path: path, method: "GET", token: token)
        if var comps = URLComponents(url: r.url!, resolvingAgainstBaseURL: false) {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "timezone",
                                      value: String(TimeZone.current.secondsFromGMT() / 60)))
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
