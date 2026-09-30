//
//  GitHubSettingsView.swift
//  KyTuT
//
//  「设置 → GitHub 连接」
//
//  填入个人访问令牌后，AI 即可通过 github 工具直接操作：
//  查看/创建仓库、读写文件、提交、管理 Issue / PR 等。
//  令牌存 Keychain，不落明文。
//

import SwiftUI

struct GitHubSettingsView: View {
    @StateObject private var service = GitHubService.shared

    @State private var tokenInput = ""
    @State private var checking = false
    @State private var showTokenField = false

    var body: some View {
        List {
            // MARK: 连接状态
            Section {
                if service.connected, let acc = service.account {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: acc.avatarURL ?? "")) { img in
                            img.resizable().frame(width: 44, height: 44).clipShape(Circle())
                        } placeholder: {
                            Circle().fill(.quaternary).frame(width: 44, height: 44)
                                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(acc.displayName).font(.headline)
                            Text("@\(acc.login)").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text("公开仓库 \(acc.publicRepos)")
                                if let p = acc.privateRepos { Text("私有 \(p)") }
                            }
                            .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)

                    if !acc.scopes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("令牌权限范围").font(.caption).foregroundStyle(.secondary)
                            Text(acc.scopes.joined(separator: "、"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.gray, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("未连接").font(.headline)
                            Text("填写令牌后 AI 即可操作 GitHub")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let err = service.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("账号")
            }

            // MARK: 令牌
            Section {
                if service.connected {
                    Button("重新验证连接") {
                        Task {
                            checking = true
                            await service.verifyAndLoad()
                            checking = false
                        }
                    }
                    .disabled(checking)

                    Button("更换令牌") {
                        tokenInput = ""
                        showTokenField = true
                    }

                    Button(role: .destructive) {
                        service.disconnect()
                    } label: {
                        Label("断开连接", systemImage: "link.badge.minus")
                    }
                } else {
                    if showTokenField {
                        SecureField("ghp_… 或 github_pat_…", text: $tokenInput)
                            .font(.caption.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            Task { await saveAndVerify() }
                        } label: {
                            HStack {
                                Text("保存并验证")
                                Spacer()
                                if checking { ProgressView().scaleEffect(0.8) }
                            }
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                    } else {
                        Button {
                            showTokenField = true
                        } label: {
                            Label("填写访问令牌", systemImage: "key.fill")
                        }
                    }
                }
            } header: {
                Text("个人访问令牌")
            } footer: {
                Text("在 GitHub → Settings → Developer settings → Personal access tokens 创建。\n勾选所需的权限范围（repo、workflow、gist 等）；令牌能做什么，AI 就能做什么。\n令牌保存在系统 Keychain 中，不会明文写入配置文件。")
            }

            // MARK: AI 能力
            Section {
                capabilityRow("查看仓库与文件", "列出仓库、浏览目录、读取文件内容", "folder.badge.gearshape")
                capabilityRow("读写代码", "创建 / 修改 / 删除文件，提交改动", "square.and.pencil")
                capabilityRow("管理分支与提交", "查看提交历史、创建分支、对比差异", "arrow.triangle.branch")
                capabilityRow("Issue 与 PR", "创建、评论、关闭 Issue 与 Pull Request", "text.bubble")
                capabilityRow("搜索", "搜索仓库、代码、Issues", "magnifyingglass")
            } header: {
                Text("AI 可用能力")
            } footer: {
                Text("连接后，AI 在对话中可直接调用 github 工具完成上述操作，无需你再提供令牌。所有操作使用你的账号身份，请留意权限范围。")
            }
        }
        .navigationTitle("GitHub 连接")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !service.connected { showTokenField = true }
        }
    }

    @ViewBuilder
    private func capabilityRow(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.75), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveAndVerify() async {
        checking = true
        service.setToken(tokenInput)
        let acc = await service.verifyAndLoad()
        checking = false
        if acc != nil {
            tokenInput = ""
            showTokenField = false
        }
    }
}
