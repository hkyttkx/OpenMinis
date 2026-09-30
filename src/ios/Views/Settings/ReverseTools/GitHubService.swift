//
//  GitHubService.swift
//  KyTuT
//
//  GitHub 连接与操作。
//
//  设计：
//    - 令牌存 Keychain（不落 UserDefaults 明文）
//    - 提供账号查询、仓库列表、文件读写、提交等能力
//    - AI 通过 github 工具直接调用，无需用户每次提供令牌
//

import Foundation

// MARK: - 账号

struct GitHubAccount: Codable, Equatable {
    var login: String
    var name: String?
    var avatarURL: String?
    var publicRepos: Int
    var privateRepos: Int?
    var scopes: [String]

    var displayName: String { (name?.isEmpty == false ? name! : login) }
}

// MARK: - 仓库

/// 只实现解码：该类只用于接收 GitHub API 响应，从不编码回请求体。
/// 声明为 Codable 会强制同时满足 Encodable，而自定义的 init(from:)
/// 不会自动获得 encode(to:)，会报「does not conform to Encodable」。
struct GitHubRepo: Decodable, Identifiable, Hashable {
    var id: Int
    var fullName: String
    var name: String
    var ownerLogin: String
    var isPrivate: Bool
    var defaultBranch: String
    var description: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case owner
    }
    struct Owner: Codable { var login: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        fullName = try c.decode(String.self, forKey: .fullName)
        name = try c.decode(String.self, forKey: .name)
        isPrivate = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
        defaultBranch = (try? c.decode(String.self, forKey: .defaultBranch)) ?? "main"
        description = try? c.decode(String.self, forKey: .description)
        ownerLogin = (try? c.decode(Owner.self, forKey: .owner))?.login ?? fullName.split(separator: "/").first.map(String.init) ?? ""
    }
}

// MARK: - 文件条目

struct GitHubFileEntry: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    var sha: String
    var size: Int?
    var type: String
    var downloadURL: String?

    var id: String { sha + "|" + path }
    var isDirectory: Bool { type == "dir" }

    enum CodingKeys: String, CodingKey {
        case name, path, sha, size, type
        case downloadURL = "download_url"
    }
}

// MARK: - 错误

enum GitHubError: Error, LocalizedError {
    case notConnected
    case invalidToken
    case http(Int, String)
    case decode(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接 GitHub。请到「设置 → GitHub 连接」填写个人访问令牌。"
        case .invalidToken:
            return "GitHub 令牌无效或已过期，请在设置中重新填写。"
        case .http(let code, let msg):
            let short = msg.count > 300 ? String(msg.prefix(300)) : msg
            return "GitHub 返回 \(code)：\(short)"
        case .decode(let m):
            return "解析响应失败：\(m)"
        case .network(let m):
            return "网络错误：\(m)"
        }
    }
}

// MARK: - 服务

@MainActor
final class GitHubService: ObservableObject {

    static let shared = GitHubService()

    @Published private(set) var account: GitHubAccount?
    @Published private(set) var connected = false
    @Published var lastError: String?

    private let tokenService = "com.openminis.app.github"
    private let tokenAccount = "personal-access-token"
    private let accountCacheKey = "github.accountCache"

    private init() {
        if let cached = UserDefaults.standard.data(forKey: accountCacheKey),
           let acc = try? JSONDecoder().decode(GitHubAccount.self, from: cached) {
            account = acc
            connected = true
        }
    }

    // MARK: 令牌（Keychain）

    var token: String? {
        Keychain.string(service: tokenService, account: tokenAccount)
    }

    func setToken(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(service: tokenService, account: tokenAccount, value: t.isEmpty ? nil : t)
        if t.isEmpty {
            account = nil
            connected = false
            UserDefaults.standard.removeObject(forKey: accountCacheKey)
        }
    }

    func disconnect() {
        setToken("")
        lastError = nil
    }

    // MARK: 连接验证

    @discardableResult
    func verifyAndLoad() async -> GitHubAccount? {
        guard let t = token, !t.isEmpty else {
            connected = false
            account = nil
            lastError = GitHubError.notConnected.errorDescription
            return nil
        }
        do {
            let (data, resp) = try await rawRequest(method: "GET", path: "/user", token: t)
            guard let http = resp as? HTTPURLResponse else { throw GitHubError.network("无响应") }
            if http.statusCode == 401 { throw GitHubError.invalidToken }
            guard http.statusCode == 200 else {
                throw GitHubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            struct RawUser: Decodable {
                var login: String
                var name: String?
                var avatar_url: String?
                var public_repos: Int
                var total_private_repos: Int?
            }
            let u = try JSONDecoder().decode(RawUser.self, from: data)
            let scopeHeader = (http.value(forHTTPHeaderField: "x-oauth-scopes") ?? "")
            let scopes = scopeHeader.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let acc = GitHubAccount(login: u.login, name: u.name, avatarURL: u.avatar_url,
                                    publicRepos: u.public_repos,
                                    privateRepos: u.total_private_repos, scopes: scopes)
            account = acc
            connected = true
            lastError = nil
            if let d = try? JSONEncoder().encode(acc) {
                UserDefaults.standard.set(d, forKey: accountCacheKey)
            }
            return acc
        } catch {
            lastError = error.localizedDescription
            connected = false
            return nil
        }
    }

    // MARK: 底层请求

    private func rawRequest(method: String,
                            path: String,
                            token: String? = nil,
                            body: [String: Any]? = nil,
                            accept: String = "application/vnd.github+json") async throws -> (Data, URLResponse) {
        guard let t = token ?? self.token, !t.isEmpty else { throw GitHubError.notConnected }
        guard let url = URL(string: path.hasPrefix("http") ? path : "https://api.github.com" + path) else {
            throw GitHubError.network("无效 URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("KyTuT", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 60
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
    }

    func request<T: Decodable>(_ type: T.Type,
                               method: String = "GET",
                               path: String,
                               body: [String: Any]? = nil,
                               accept: String = "application/vnd.github+json") async throws -> T {
        let (data, resp) = try await rawRequest(method: method, path: path, body: body, accept: accept)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.network("无响应") }
        if http.statusCode == 401 { throw GitHubError.invalidToken }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decode(error.localizedDescription)
        }
    }

    /// 原始文本响应（读文件内容）
    func requestRaw(method: String = "GET", path: String, body: [String: Any]? = nil) async throws -> String {
        let (data, resp) = try await rawRequest(method: method, path: path, body: body,
                                                accept: "application/vnd.github.raw")
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.network("无响应") }
        if http.statusCode == 401 { throw GitHubError.invalidToken }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 无解析的请求（需要看响应头 / 状态码时用）
    @discardableResult
    func plainRequest(method: String, path: String, body: [String: Any]? = nil) async throws -> (Int, String) {
        let (data, resp) = try await rawRequest(method: method, path: path, body: body)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.network("无响应") }
        if http.statusCode == 401 { throw GitHubError.invalidToken }
        return (http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
}
