//
//  RelayQuotaView.swift
//  KyTuT
//
//  多账号中转站余额 / 用量 dashboard。
//

import SwiftUI

struct RelayQuotaView: View {
    @StateObject private var svc = RelayQuotaService.shared
    @State private var showAdd = false
    @State private var refreshAll = false

    var body: some View {
        List {
            // MARK: 账号列表
            Section {
                if svc.accounts.isEmpty {
                    Text("还没有中转站账号")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(svc.accounts) { entry in
                        Button {
                            svc.selectedId = entry.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.id == svc.selectedId
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(entry.id == svc.selectedId ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayLabel).foregroundStyle(.primary)
                                    Text("\(entry.siteShort) · \(entry.email)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(entry.balanceText)
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { svc.removeAccount(entry.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { svc.logout(entry.id) } label: {
                                Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .tint(.orange)
                        }
                    }
                }

                Button {
                    showAdd = true
                } label: {
                    Label("添加中转站账号", systemImage: "plus.circle")
                }

                Button {
                    Task { await svc.refresh() }
                } label: {
                    HStack {
                        Label("刷新全部账号", systemImage: "arrow.clockwise")
                        Spacer()
                        if !svc.refreshing.isEmpty { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(svc.refreshing.count > 0)
            } header: {
                Text("账号（\(svc.accounts.count)）")
            } footer: {
                Text("每个账号独立保存令牌与余额。向左滑动可退出或删除；点击账号查看完整 dashboard。")
            }

            // MARK: 当前账号 dashboard
            if let id = svc.selectedId, let entry = svc.entry(id) {
                Section {
                    accountDetail(entry: entry, data: svc.data[id])
                } header: {
                    Text("\(entry.displayLabel) · Dashboard")
                }
            }

            if let err = svc.lastError {
                Section { Text(err).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle("中转站账户")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) { AddRelayAccountView() }
        .onAppear {
            Task { await svc.refresh() }
        }
    }

    @ViewBuilder
    private func accountDetail(entry: RelayAccountEntry, data: RelayQuotaService.RelayData?) -> some View {
        if let data {
            let a = data.account
            let u = data.usage
            dashboardRow(icon: "banknote", tint: .green, title: "余额",
                         value: a.balance.map { String(format: "$%.2f", $0) } ?? "—",
                         sub: a.totalRecharged.map { String(format: "累计充值 $%.2f", $0) })
            dashboardRow(icon: "key.fill", tint: .blue, title: "账户",
                         value: a.email ?? a.username ?? entry.email,
                         sub: entry.siteShort)

            // 用量汇总：服务端 today_* 在当天无用量时恒为 0，因此累计值才是
            // 真正有信息量的那一组，放前面。
            dashboardRow(icon: "chart.bar", tint: .orange, title: "累计请求",
                         value: fmtInt(u.totalRequests),
                         sub: "今日 \(fmtInt(u.todayRequests))")
            dashboardRow(icon: "dollarsign.circle", tint: .purple, title: "累计消费",
                         value: String(format: "$%.4f", u.totalActualCost > 0 ? u.totalActualCost : u.totalCost),
                         sub: String(format: "名义 $%.4f · 今日 $%.4f", u.totalCost, u.todayCost))
            dashboardRow(icon: "cube", tint: .yellow, title: "累计 Token",
                         value: fmtInt(u.totalTokens),
                         sub: "输入 \(fmtInt(u.inputTokens)) / 输出 \(fmtInt(u.outputTokens)) / 缓存读 \(fmtInt(u.cachedTokens))")
            if u.totalAPIKeys > 0 {
                dashboardRow(icon: "key.horizontal", tint: .teal, title: "API Key",
                             value: "\(u.totalAPIKeys)",
                             sub: "启用中 \(u.activeAPIKeys)")
            }
            dashboardRow(icon: "bolt", tint: .mint, title: "性能",
                         value: "\(u.rpm) RPM · \(u.tpm) TPM",
                         sub: "服务端按当前时刻统计，无流量时为 0")
            dashboardRow(icon: "clock", tint: .red, title: "平均响应",
                         value: String(format: "%.2fs", u.avgResponseSeconds))

            // 分组与趋势
            if !u.byPlatform.isEmpty {
                NavigationLink { RelayGroupListView(title: "按平台", rows: u.byPlatform) } label: {
                    Label("按平台（\(u.byPlatform.count)）", systemImage: "square.stack.3d.up")
                }
            }
            if !u.byModel.isEmpty {
                NavigationLink { RelayGroupListView(title: "按模型", rows: u.byModel) } label: {
                    Label("按模型（\(u.byModel.count)）", systemImage: "cpu")
                }
            }
            if !u.byEndpoint.isEmpty {
                NavigationLink { RelayGroupListView(title: "按端点", rows: u.byEndpoint) } label: {
                    Label("按端点（\(u.byEndpoint.count)）", systemImage: "arrow.triangle.branch")
                }
            }
            if !u.trend.isEmpty {
                NavigationLink { RelayTrendView(points: u.trend) } label: {
                    Label("每日趋势（\(u.trend.count) 天）", systemImage: "chart.xyaxis.line")
                }
            }

            NavigationLink {
                RelayRawDataView(title: entry.displayLabel, text: rawDataText(account: a, usage: u))
            } label: {
                Label("查看原始数据", systemImage: "curlybraces")
            }
        } else {
            Text(svc.isLoggedIn(entry.id) ? "正在加载…" : "该账号尚未登录")
                .font(.caption).foregroundStyle(.secondary)
            if !svc.isLoggedIn(entry.id) {
                NavigationLink("登录该账号") { RelayLoginView(accountId: entry.id) }
            }
        }
    }

    @ViewBuilder
    /// 大数字缩写：676 → "676"，1.72 亿 → "172.1M"
    private func fmtInt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func dashboardRow(icon: String, tint: Color, title: String, value: String, sub: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold).monospacedDigit())
                if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    /// 「查看原始数据」正文。
    /// 优先展示统计接口的原始响应（这才是请求数/消费/Token 的来源），
    /// 后面附上 /auth/me —— 之前只显示 me，所以看到的 JSON 里根本没有统计字段，
    /// 容易被误判成「接口没返回」。
    private func rawDataText(account a: RelayAccount, usage u: RelayUsage) -> String {
        var parts: [String] = []
        if !u.raw.isEmpty { parts.append("=== 统计接口 ===\n" + u.raw) }
        if let me = a.rawText, !me.isEmpty { parts.append("=== /auth/me ===\n" + me) }
        return parts.isEmpty ? "（尚无数据，请先刷新）" : parts.joined(separator: "\n\n")
    }

    private func tok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - 添加账号

private struct AddRelayAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var svc = RelayQuotaService.shared
    @State private var site = "https://1for.cc"
    @State private var email = ""
    @State private var password = ""
    @State private var label = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("站点") {
                    TextField("https://1for.cc", text: $site)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("账户") {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("密码", text: $password)
                    TextField("显示名称（可选）", text: $label)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Text("登录并添加")
                            Spacer()
                            if busy { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(site.isEmpty || email.isEmpty || password.isEmpty || busy)
                }
            }
            .navigationTitle("添加中转站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func add() async {
        busy = true; error = nil
        svc.addAccount(siteURL: site, email: email, label: label)
        guard let id = svc.selectedId else { busy = false; return }
        let ok = await svc.login(accountId: id, email: email, password: password)
        busy = false
        if ok { password = ""; dismiss() }
        else { error = svc.lastError ?? "登录失败" }
    }
}

// MARK: - 已有账号登录

private struct RelayLoginView: View {
    let accountId: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var svc = RelayQuotaService.shared
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                SecureField("密码", text: $password)
                Button("登录") {
                    Task {
                        guard let e = svc.entry(accountId) else { return }
                        busy = true
                        if await svc.login(accountId: accountId, email: e.email, password: password) {
                            dismiss()
                        }
                        busy = false
                    }
                }
                .disabled(password.isEmpty || busy)
            } header: { Text(svc.entry(accountId)?.email ?? "账户") }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 原始数据查看页（完整、可滚动、可复制、可搜索）

struct RelayRawDataView: View {
    let title: String
    let text: String

    @State private var search = ""
    @State private var copied = false

    private var pretty: String {
        // 尝试格式化 JSON，失败则原样
        guard let d = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: out, encoding: .utf8) else { return text }
        return s
    }

    private var lines: [String] { pretty.components(separatedBy: "\n") }

    private var filtered: [(Int, String)] {
        if search.isEmpty { return lines.enumerated().map { ($0.offset, $0.element) } }
        let kw = search.lowercased()
        return lines.enumerated().filter { $0.element.lowercased().contains(kw) }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("\(lines.count) 行 · \(pretty.count) 字符")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = pretty
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered, id: \.0) { idx, line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 32, alignment: .trailing)
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("原始数据")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索字段")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: pretty) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

}

// MARK: - 分组列表（平台 / 模型 / 端点）

/// 三个分组接口返回的结构一致，只是名称键不同，所以共用一个页面。
private struct RelayGroupListView: View {
    let title: String
    let rows: [RelayGroupRow]

    var body: some View {
        List {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.name).font(.body.weight(.medium))
                    HStack(spacing: 10) {
                        Text("\(fmt(r.requests)) 次").font(.caption).foregroundStyle(.blue)
                        Text(fmt(r.tokens) + " tok").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "$%.4f", r.actualCost > 0 ? r.actualCost : r.cost))
                            .font(.caption.monospacedDigit()).foregroundStyle(.green)
                    }
                    if r.requests > 0, r.tokens > 0 {
                        let perReq = Double(r.tokens) / Double(max(r.requests, 1))
                        Text("平均 \(Int(perReq)) tok/次")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - 每日趋势

private struct RelayTrendView: View {
    let points: [RelayTrendPoint]

    private var maxTokens: Int { points.map(\.tokens).max() ?? 1 }

    var body: some View {
        List {
            Section {
                ForEach(points.reversed()) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.date).font(.caption.monospacedDigit())
                            Spacer()
                            Text(String(format: "$%.4f", p.actualCost)).font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        // 用条宽表示当日 token 量级，避免引入图表依赖
                        GeometryReader { geo in
                            let ratio = maxTokens > 0 ? Double(p.tokens) / Double(maxTokens) : 0
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 6)
                        HStack(spacing: 10) {
                            Text("\(fmt(p.requests)) 次").font(.caption2).foregroundStyle(.blue)
                            Text(fmt(p.tokens) + " tok").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("越新的在上")
            }
        }
        .navigationTitle("每日趋势")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

