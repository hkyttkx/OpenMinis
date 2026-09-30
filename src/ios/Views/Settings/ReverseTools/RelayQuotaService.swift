//
//  RelayQuotaService.swift
//  KyTuT
//
//  中转站（Relay）账户与余额查询。
//
//  站点接口契约（以 1for.cc 这类自研 Relay 网关为准）：
//    API 前缀          /api/v1
//    登录              POST /auth/login        {email, password} → {access_token, refresh_token, expires_in, user}
//    刷新              POST /auth/refresh      {refresh_token}    → 新 token
//    当前用户/余额     GET  /auth/me           → {balance, quota, ...}
//    用量              GET  /usage
//    API 密钥          GET  /keys
//    订阅              GET  /subscriptions/active
//    公开设置          GET  /settings/public   （无需认证）
//
//    用户侧请求需带 `X-User-UI-Request: 1`，否则可能被拒绝。
//
//  凭据策略（用户选择）：
//    登录时输入的密码只用于换取 token，不落盘；
//    Keychain 只保存 refresh_token，后续自动刷新。
//    用户可在网页后台「撤销所有会话」使本地令牌立即失效。
//

import Foundation
import Security

// MARK: - 模型

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

    // 兼容多种命名：不同实现里字段名可能不同
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
    var todayRequests: Int = 0
    var totalRequests: Int = 0
    var todayCost: Double = 0
    var totalCost: Double = 0
    var todayTokens: Int = 0
    var totalTokens: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedTokens: Int = 0
    var rpm: Int = 0
    var tpm: Int = 0
    var avgResponseSeconds: Double = 0
    var raw: String = ""
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
        case .notConfigured: return "尚未配置中转站地址。"
        case .notLoggedIn:   return "尚未登录中转站，请先在设置里登录。"
        case .authFailed(let m): return "登录失败：\(m)"
        case .http(let c, let m):
            let s = m.count > 200 ? String(m.prefix(200)) : m
            return "中转站返回 \(c)：\(s)"
        case .decode(let m): return "解析响应失败：\(m)"
        case .network(let m): return "网络错误：\(m)"
        }
    }
}

// MARK: - 服务

@MainActor
final class RelayQuotaService: ObservableObject {

    static let shared = RelayQuotaService()

    @Published private(set) var loggedIn = false
    @Published private(set) var account: RelayAccount?
    @Published private(set) var usage: RelayUsage?
    @Published var lastError: String?
    @Published var busy = false
    @Published private(set) var lastUpdated: Date?

    /// 站点地址（可改）
    @Published var siteURL: String {
        didSet { UserDefaults.standard.set(siteURL, forKey: Self.siteKey) }
    }

    private static let siteKey = "relay.siteURL"
    private static let userKey = "relay.accountCache"

    private let tokenService = "com.openminis.app.relay"
    private let refreshAccount = "refresh-token"

    private init() {
        siteURL = UserDefaults.standard.string(forKey: Self.siteKey) ?? "https://1for.cc"
        loggedIn = (refreshToken?.isEmpty == false)
        if let d = UserDefaults.standard.data(forKey: Self.userKey),
           let a = try? JSONDecoder().decode(RelayAccount.self, from: d) {
            account = a
        }
    }

    // MARK: 凭据（Keychain）

    private var refreshToken: String? {
        Keychain.string(service: tokenService, account: refreshAccount)
    }

    private func setRefreshToken(_ t: String?) {
        Keychain.set(service: tokenService, account: refreshAccount, value: t)
    }

    /// 内存中的短期 access token，不落盘
    private var accessToken: String?
    private var accessExpiry: Date = .distantPast

    // MARK: 登录

    /// 用邮箱密码登录。密码仅用于本次请求，不写入任何持久化存储。
    func login(email: String, password: String) async -> Bool {
        busy = true
        defer { busy = false }
        lastError = nil

        do {
            let body: [String: Any] = ["email": email, "password": password]
            let json = try await post(path: "/auth/login", body: body, auth: false)

            guard let obj = json as? [String: Any] else {
                throw RelayError.decode("登录响应格式异常")
            }
            if let at = obj["access_token"] as? String {
                accessToken = at
                accessExpiry = Date().addingTimeInterval((obj["expires_in"] as? Double ?? 3600) - 60)
            }
            if let rt = obj["refresh_token"] as? String {
                setRefreshToken(rt)
            }
            // 响应里可能直接带 user 信息
            if let u = obj["user"] as? [String: Any] {
                cacheAccount(from: u)
            }
            loggedIn = true

            // 立刻拉一次余额与用量
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func logout() {
        setRefreshToken(nil)
        accessToken = nil
        accessExpiry = .distantPast
        loggedIn = false
        account = nil
        usage = nil
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }

    // MARK: 刷新

    /// 拉取最新的余额与用量
    func refresh() async {
        guard refreshToken != nil || accessToken != nil else {
            lastError = RelayError.notLoggedIn.errorDescription
            return
        }
        busy = true
        defer { busy = false }
        lastError = nil

        do {
            try await ensureAccessToken()

            if let me = try await getJSON(path: "/auth/me") as? [String: Any] {
                cacheAccount(from: me)
            }
            if let u = try await getJSON(path: "/usage") as? [String: Any] {
                usage = parseUsage(u)
            }
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 保证有一个有效的 access token
    private func ensureAccessToken() async throws {
        if let t = accessToken, Date() < accessExpiry, !t.isEmpty { return }
        guard let rt = refreshToken, !rt.isEmpty else { throw RelayError.notLoggedIn }

        let json = try await post(path: "/auth/refresh",
                                  body: ["refresh_token": rt],
                                  auth: false)
        guard let obj = json as? [String: Any],
              let at = obj["access_token"] as? String else {
            throw RelayError.authFailed("刷新令牌无效，请重新登录")
        }
        accessToken = at
        accessExpiry = Date().addingTimeInterval((obj["expires_in"] as? Double ?? 3600) - 60)
        if let newRT = obj["refresh_token"] as? String {
            setRefreshToken(newRT)
        }
    }

    // MARK: 解析

    private func cacheAccount(from dict: [String: Any]) {
        var a = RelayAccount(from: dict)
        a.rawText = Self.pretty(dict)
        account = a
        if let d = try? JSONEncoder().encode(a) {
            UserDefaults.standard.set(d, forKey: Self.userKey)
        }
    }

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

    private var apiBase: String {
        var s = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        return s + "/api/v1"
    }

    private func makeRequest(path: String, method: String, auth: Bool) throws -> URLRequest {
        guard let url = URL(string: apiBase + path) else {
            throw RelayError.network("无效地址：\(apiBase + path)")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("1", forHTTPHeaderField: "X-User-UI-Request")
        r.setValue("KyTuT", forHTTPHeaderField: "User-Agent")
        // 站点会按 timezone 参数做分组统计，缺失时部分字段为空
        r.timeoutInterval = 45
        if auth {
            guard let t = accessToken else { throw RelayError.notLoggedIn }
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func post(path: String, body: [String: Any], auth: Bool) async throws -> Any {
        var r = try makeRequest(path: path, method: "POST", auth: auth)
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(r)
    }

    private func getJSON(path: String) async throws -> Any {
        var r = try makeRequest(path: path, method: "GET", auth: true)
        var comps = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "timezone",
                                  value: String(TimeZone.current.secondsFromGMT() / 60)))
        comps?.queryItems = items
        if let u = comps?.url { r.url = u }
        return try await send(r)
    }

    /// 统一发送并解包 {code, message, data} 信封
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
            // 非 JSON 响应，原样返回文本
            return ["raw": text]
        }
        // 信封：{code: 0, data: {...}}
        if let dict = obj as? [String: Any], let code = dict["code"] as? Int {
            if code == 0 {
                return dict["data"] ?? dict
            }
            throw RelayError.http(code, (dict["message"] as? String) ?? "unknown")
        }
        return obj
    }
}

// MARK: - RelayAccount 的宽松解码

extension RelayAccount {
    /// 从任意字典里尽力提取字段（不同实现的命名差异很大）
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

    /// 宽松解码（用于缓存恢复）
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
