//
//  RelayQuotaView.swift
//  KyTuT
//
//  「设置 → 中转站账户」
//
//  把中转站 dashboard 上的信息（余额 / 今日与累计的请求、消费、Token、
//  性能指标、平均响应）直接显示在 App 里，不必再开浏览器。
//

import SwiftUI

struct RelayQuotaView: View {
    @StateObject private var svc = RelayQuotaService.shared

    @State private var email = ""
    @State private var password = ""
    @State private var siteInput = ""
    @State private var showLogin = false

    var body: some View {
        List {
            // MARK: 站点
            Section {
                HStack {
                    Text("站点")
                    Spacer()
                    TextField("https://example.com", text: $siteInput)
                        .multilineTextAlignment(.trailing)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { svc.siteURL = siteInput }
                }
                Button("保存站点地址") { svc.siteURL = siteInput }
                    .disabled(siteInput.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("中转站")
            } footer: {
                Text("支持自建 Relay 网关（API 前缀 /api/v1）。修改站点后需要重新登录。")
            }

            // MARK: 账号
            Section {
                if svc.loggedIn {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(svc.account?.username ?? svc.account?.email ?? "已登录")
                                .font(.headline)
                            if let s = svc.account?.subscription {
                                Text(s).font(.caption).foregroundStyle(.secondary)
                            }
                            if let t = svc.lastUpdated {
                                Text("更新于 \(Self.timeFmt.string(from: t))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    Button {
                        Task { await svc.refresh() }
                    } label: {
                        HStack {
                            Label("刷新数据", systemImage: "arrow.clockwise")
                            Spacer()
                            if svc.busy { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(svc.busy)

                    Button(role: .destructive) {
                        svc.logout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        Label("登录中转站", systemImage: "person.badge.key")
                    }
                }

                if let err = svc.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("账户")
            } footer: {
                Text("登录仅用于换取访问令牌；密码不写入本地存储，App 只保存刷新令牌（可在网页后台「撤销所有会话」使其失效）。")
            }

            // MARK: 余额
            if svc.loggedIn {
                Section {
                    if let a = svc.account {
                        statCard(icon: "banknote", tint: .green,
                                 title: "余额",
                                 value: a.balance.map { String(format: "$%.2f", $0) } ?? "—")

                        if let t = a.todayCost, t > 0 {
                            statCard(icon: "dollarsign.circle", tint: .purple,
                                     title: "今日消费",
                                     value: String(format: "$%.4f", t))
                        }
                        if let t = a.totalCost, t > 0 {
                            statCard(icon: "sum", tint: .purple,
                                     title: "累计消费",
                                     value: String(format: "$%.2f", t))
                        }
                    } else {
                        Text("暂无余额数据，点「刷新数据」重试")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("余额与消费")
                }
            }

            // MARK: 用量
            if let u = svc.usage, svc.loggedIn {
                Section {
                    statCard(icon: "chart.bar", tint: .orange,
                             title: "今日请求", value: "\(u.todayRequests)",
                             sub: "总计：\(u.totalRequests)")
                    statCard(icon: "cube", tint: .yellow,
                             title: "今日 Token", value: Self.tok(u.todayTokens),
                             sub: "输入 \(Self.tok(u.inputTokens)) / 输出 \(Self.tok(u.outputTokens)) / 缓存 \(Self.tok(u.cachedTokens))")
                    statCard(icon: "internaldrive", tint: .blue,
                             title: "累计 Token", value: Self.tok(u.totalTokens))
                } header: {
                    Text("用量")
                }

                Section {
                    statCard(icon: "bolt", tint: .indigo,
                             title: "性能指标", value: "\(u.rpm) RPM",
                             sub: "\(u.tpm) TPM")
                    statCard(icon: "clock", tint: .red,
                             title: "平均响应",
                             value: String(format: "%.2fs", u.avgResponseSeconds))
                } header: {
                    Text("性能")
                }

                // 原始 JSON 便于排查字段差异
                Section {
                    DisclosureGroup("原始数据") {
                        ScrollView(.horizontal) {
                            Text(u.raw)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    }
                    if let raw = svc.account?.rawText, !raw.isEmpty {
                        DisclosureGroup("账户原始数据") {
                            ScrollView(.horizontal) {
                                Text(raw)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                } header: {
                    Text("诊断")
                }
            }
        }
        .navigationTitle("中转站账户")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) {
            loginSheet
        }
        .onAppear {
            siteInput = svc.siteURL
            if svc.loggedIn && svc.account == nil {
                Task { await svc.refresh() }
            }
        }
    }

    // MARK: - 登录弹窗

    private var loginSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $password)
                } header: {
                    Text("登录信息")
                } footer: {
                    Text("密码仅用于本次登录换取令牌，不会保存到本地。App 只保留刷新令牌。")
                }

                Section {
                    Button {
                        Task {
                            let ok = await svc.login(email: email, password: password)
                            if ok {
                                password = ""
                                showLogin = false
                            }
                        }
                    } label: {
                        HStack {
                            Text("登录")
                            Spacer()
                            if svc.busy { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || svc.busy)
                }
            }
            .navigationTitle("登录中转站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { password = ""; showLogin = false }
                }
            }
        }
    }

    // MARK: - 组件

    @ViewBuilder
    private func statCard(icon: String, tint: Color, title: String,
                          value: String, sub: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold).monospacedDigit())
                if let sub {
                    Text(sub).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func tok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
