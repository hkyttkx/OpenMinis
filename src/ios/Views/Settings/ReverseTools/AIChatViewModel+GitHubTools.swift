//
//  AIChatViewModel+GitHubTools.swift
//  KyTuT
//
//  AI 工具：github
//  通过 GitHubService 直接操作 GitHub，无需用户每次提供令牌。
//
//  支持的 action（全部走 REST v3，按需返回精简结果，便于模型阅读）：
//     whoami              当前账号与令牌权限
//     list_repos          列出仓库（可指定 owner）
//     get_repo            仓库详情
//     list_files          列目录
//     read_file           读文件内容
//     write_file          创建/更新文件并提交
//     delete_file         删除文件
//     list_commits        提交历史
//     create_branch       从某提交创建分支
//     list_issues         列 Issue
//     create_issue        创建 Issue
//     comment_issue       评论 Issue / PR
//     search              搜索仓库 / 代码 / Issues
//     api                 直接调用任意 GitHub API 路径（逃生舱）
//

import Foundation

extension AIChatViewModel {

    // MARK: - 入口

    func executeGitHubTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for github.", false)
        }

        let action = (args["action"] as? String)?.lowercased() ?? ""
        guard !action.isEmpty else {
            return ("""
            Error: 'action' is required.

            Available actions:
              whoami / list_repos / get_repo / list_files / read_file
              write_file / delete_file / list_commits / create_branch
              list_issues / create_issue / comment_issue / search / api
            """, false)
        }

        let svc = await MainActor.run { GitHubService.shared }
        let connected = await MainActor.run { svc.connected }
        guard connected else {
            return (GitHubError.notConnected.errorDescription ?? "未连接 GitHub", false)
        }

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ GitHub: \(action)…"
            scrollToBottomSignal.send()
        }

        do {
            let out = try await performGitHub(action: action, args: args, svc: svc)
            return (out.text, out.success)
        } catch {
            return ("Error: \(error.localizedDescription)", false)
        }
    }

    // MARK: - 分发

    private func performGitHub(action: String, args: [String: Any], svc: GitHubService) async throws -> (text: String, success: Bool) {
        func str(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func need(_ k: String) throws -> String {
            guard let v = str(k), !v.isEmpty else {
                throw NSError(domain: "github", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "缺少参数 '\(k)'"])
            }
            return v
        }

        switch action {

        // ── 账号 ──
        case "whoami":
            let acc = await svc.verifyAndLoad()
            guard let a = acc else { throw GitHubError.invalidToken }
            var lines = ["已连接：\(a.displayName) (@\(a.login))",
                         "公开仓库：\(a.publicRepos)"]
            if let p = a.privateRepos { lines.append("私有仓库：\(p)") }
            lines.append("令牌权限：\(a.scopes.isEmpty ? "（未返回，可能是 fine-grained token）" : a.scopes.joined(separator: ", "))")
            return (lines.joined(separator: "\n"), true)

        // ── 仓库 ──
        case "list_repos":
            let owner = str("owner")
            let limit = (args["limit"] as? Int) ?? 30
            let path = owner.map { "/users/\($0)/repos?per_page=\(limit)&sort=updated" }
                       ?? "/user/repos?per_page=\(min(limit, 100))&sort=updated"
            let repos: [GitHubRepo] = try await svc.request([GitHubRepo].self, path: path)
            guard !repos.isEmpty else { return ("没有找到仓库。", true) }
            let body = repos.map { r -> String in
                let lock = r.isPrivate ? "🔒" : "  "
                let desc = (r.description?.isEmpty == false) ? "  — \(r.description!.prefix(70))" : ""
                return "\(lock) \(r.fullName)  [\(r.defaultBranch)]\(desc)"
            }.joined(separator: "\n")
            return ("共 \(repos.count) 个仓库：\n\n\(body)", true)

        case "get_repo":
            let repo = try need("repo")
            let r: GitHubRepo = try await svc.request(GitHubRepo.self, path: "/repos/\(repo)")
            return ("""
            \(r.fullName)\(r.isPrivate ? "（私有）" : "")
            默认分支：\(r.defaultBranch)
            描述：\(r.description ?? "无")
            """, true)

        // ── 文件 ──
        case "list_files":
            let repo = try need("repo")
            let path = str("path") ?? ""
            let ref = str("ref")
            var api = "/repos/\(repo)/contents/\(path)"
            if let ref { api += "?ref=\(ref)" }

            // 目录返回数组，文件返回对象：用原始请求区分
            let (status, raw) = try await svc.plainRequest(method: "GET", path: api)
            guard (200..<300).contains(status) else {
                throw GitHubError.http(status, raw)
            }
            let jd = raw.data(using: .utf8) ?? Data()
            if let arr = try? JSONDecoder().decode([GitHubFileEntry].self, from: jd) {
                let body = arr.map { e -> String in
                    let icon = e.isDirectory ? "📁" : "📄"
                    let size = e.size.map { "  \($0)B" } ?? ""
                    return "\(icon) \(e.path)\(size)"
                }.joined(separator: "\n")
                return ("\(repo)/\(path.isEmpty ? "" : path) 共 \(arr.count) 项：\n\n\(body)", true)
            }
            if let one = try? JSONDecoder().decode(GitHubFileEntry.self, from: jd) {
                return ("这是一个文件：\(one.path)（\(one.size ?? 0) 字节）。用 read_file 读取内容。", true)
            }
            return ("无法解析目录内容：\(raw.prefix(300))", false)

        case "read_file":
            let repo = try need("repo")
            let path = try need("path")
            let ref = str("ref")
            var contentPath = "/repos/\(repo)/contents/\(path)"
            if let ref { contentPath += "?ref=\(ref)" }
            let text = try await svc.requestRaw(path: contentPath)
            let truncated = text.count > 60_000 ? String(text.prefix(60_000)) + "\n\n…（已截断，原文 \(text.count) 字符）" : text
            return ("\(repo)/\(path)：\n\n\(truncated)", true)

        case "write_file":
            let repo = try need("repo")
            let path = try need("path")
            let content = (args["content"] as? String) ?? ""
            guard !content.isEmpty else {
                throw NSError(domain: "github", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "缺少参数 'content'"])
            }
            let message = str("message") ?? "Update \(path) via KyTuT"
            let branch = str("branch")

            // 先取现有 sha（更新时必须提供）
            var body: [String: Any] = [
                "message": message,
                "content": Data(content.utf8).base64EncodedString(),
            ]
            if let branch { body["branch"] = branch }
            if let existing = try? await svc.plainRequest(method: "GET",
                                                          path: "/repos/\(repo)/contents/\(path)" + (branch.map { "?ref=\($0)" } ?? "")),
               existing.0 == 200,
               let jd = existing.1.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
               let sha = obj["sha"] as? String {
                body["sha"] = sha
            }

            let (status, raw) = try await svc.plainRequest(method: "PUT",
                                                           path: "/repos/\(repo)/contents/\(path)",
                                                           body: body)
            guard (200..<300).contains(status) else { throw GitHubError.http(status, raw) }
            var sha = "?"
            if let jd = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
               let c = obj["commit"] as? [String: Any],
               let s = c["sha"] as? String { sha = String(s.prefix(10)) }
            return ("✅ 已提交 \(repo)/\(path)（commit \(sha)）\n消息：\(message)", true)

        case "delete_file":
            let repo = try need("repo")
            let path = try need("path")
            let message = str("message") ?? "Delete \(path) via KyTuT"

            let (gStatus, gRaw) = try await svc.plainRequest(method: "GET", path: "/repos/\(repo)/contents/\(path)")
            guard gStatus == 200, let jd = gRaw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
                  let sha = obj["sha"] as? String else {
                throw NSError(domain: "github", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "文件不存在或无法读取其 sha"])
            }
            var body: [String: Any] = ["message": message, "sha": sha]
            if let b = str("branch") { body["branch"] = b }
            let (status, raw) = try await svc.plainRequest(method: "DELETE",
                                                           path: "/repos/\(repo)/contents/\(path)",
                                                           body: body)
            guard (200..<300).contains(status) else { throw GitHubError.http(status, raw) }
            return ("✅ 已删除 \(repo)/\(path)", true)

        // ── 提交与分支 ──
        case "list_commits":
            let repo = try need("repo")
            let limit = (args["limit"] as? Int) ?? 20
            let branch = str("branch")
            var p = "/repos/\(repo)/commits?per_page=\(min(limit, 100))"
            if let branch { p += "&sha=\(branch)" }
            struct C: Decodable {
                var sha: String
                var commit: Inner
                struct Inner: Decodable { var message: String; var author: A; struct A: Decodable { var name: String; var date: String } }
            }
            let commits: [C] = try await svc.request([C].self, path: p)
            let body = commits.map { c -> String in
                let title = c.commit.message.split(separator: "\n").first.map(String.init) ?? ""
                return "\(c.sha.prefix(10))  \(c.commit.author.date)  \(title.prefix(80))"
            }.joined(separator: "\n")
            return ("最近 \(commits.count) 次提交：\n\n\(body)", true)

        case "create_branch":
            let repo = try need("repo")
            let branch = try need("branch")
            let from = str("from") ?? "main"
            // 取源分支的 sha
            let (s, raw) = try await svc.plainRequest(method: "GET", path: "/repos/\(repo)/git/ref/heads/\(from)")
            guard s == 200, let jd = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
                  let o = obj["object"] as? [String: Any], let sha = o["sha"] as? String else {
                throw NSError(domain: "github", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取分支 \(from) 的提交"])
            }
            let (cs, craw) = try await svc.plainRequest(method: "POST",
                                                        path: "/repos/\(repo)/git/refs",
                                                        body: ["ref": "refs/heads/\(branch)", "sha": sha])
            guard (200..<300).contains(cs) else { throw GitHubError.http(cs, craw) }
            return ("✅ 已从 \(from) 创建分支 \(branch)（基于 \(sha.prefix(10))）", true)

        // ── Issue / PR ──
        case "list_issues":
            let repo = try need("repo")
            let limit = (args["limit"] as? Int) ?? 20
            let state = str("state") ?? "open"
            struct I: Decodable {
                var number: Int
                var title: String
                var state: String
                var html_url: String
                var user: U
                struct U: Decodable { var login: String }
            }
            let issues: [I] = try await svc.request([I].self,
                                                    path: "/repos/\(repo)/issues?state=\(state)&per_page=\(min(limit, 100))")
            let body = issues.map { "#\($0.number) [\($0.state)] \($0.title)  — @\($0.user.login)" }
                .joined(separator: "\n")
            return ("\(repo) 的 \(state) Issue（\(issues.count) 条）：\n\n\(body)", true)

        case "create_issue":
            let repo = try need("repo")
            let title = try need("title")
            var body: [String: Any] = ["title": title]
            if let b = str("body") { body["body"] = b }
            let (status, raw) = try await svc.plainRequest(method: "POST", path: "/repos/\(repo)/issues", body: body)
            guard (200..<300).contains(status) else { throw GitHubError.http(status, raw) }
            var url = ""
            if let jd = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
               let u = obj["html_url"] as? String { url = u }
            return ("✅ 已创建 Issue：\(title)\n\(url)", true)

        case "comment_issue":
            let repo = try need("repo")
            let number = args["number"] as? Int ?? Int(str("number") ?? "") ?? 0
            guard number > 0 else {
                throw NSError(domain: "github", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "缺少或无效的参数 'number'"])
            }
            let body = try need("body")
            let (status, raw) = try await svc.plainRequest(method: "POST",
                                                           path: "/repos/\(repo)/issues/\(number)/comments",
                                                           body: ["body": body])
            guard (200..<300).contains(status) else { throw GitHubError.http(status, raw) }
            return ("✅ 已在 #\(number) 发表评论", true)

        // ── 搜索 ──
        case "search":
            let q = try need("query")
            let kind = str("kind") ?? "repositories"
            struct S: Decodable {
                var total_count: Int
                var items: [Item]
                struct Item: Decodable {
                    var full_name: String?
                    var path: String?
                    var html_url: String?
                    var description: String?
                    var title: String?
                    var number: Int?
                }
            }
            var escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            escaped = escaped.replacingOccurrences(of: "+", with: "%2B")
            let s: S = try await svc.request(S.self, path: "/search/\(kind)?q=\(escaped)&per_page=20")
            let lines = s.items.prefix(20).map { it -> String in
                if let fn = it.full_name {
                    return "\(fn)  — \((it.description ?? "").prefix(60))"
                }
                if let t = it.title {
                    return "#\(it.number ?? 0) \(t)"
                }
                return (it.path ?? it.html_url ?? "?")
            }.joined(separator: "\n")
            return ("搜索「\(q)」（\(kind)）命中 \(s.total_count) 条：\n\n\(lines)", true)

        // ── 逃生舱 ──
        case "api":
            let method = (str("method") ?? "GET").uppercased()
            let path = try need("path")
            var body: [String: Any]?
            if let rawBody = str("body") {
                body = try? JSONSerialization.jsonObject(with: Data(rawBody.utf8)) as? [String: Any]
            }
            let (status, raw) = try await svc.plainRequest(method: method, path: path, body: body)
            let text = raw.count > 20_000 ? String(raw.prefix(20_000)) + "\n…（已截断）" : raw
            return ("HTTP \(status)\n\n\(text)", (200..<300).contains(status))

        default:
            return ("Error: 未知的 action '\(action)'。可用值见工具说明。", false)
        }
    }
}
