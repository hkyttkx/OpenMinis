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
            // 账号从未产生过请求时，所有统计天然是 0。
            // 之前这种界面和「接口没接上」长得一模一样，用户无法分辨，
            // 所以这里显式说明一次。
            if u.totalRequests == 0 && u.trend.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("该账号暂无用量记录").font(.caption.weight(.medium))
                        Text("登录正常，接口也已连通——只是这个站上还没有产生过请求。\n首次调用模型后，这里的请求数、Token、消费和图表会自动出现。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

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

            // ── 模型分布（环形图 + 表格），对齐站点原版 dashboard ──
            if !u.byModel.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("模型分布").font(.headline)

                    RelayDonutChart(
                        slices: donutSlices(u.byModel.map { ($0.name, $0.actualCost > 0 ? $0.actualCost : $0.cost) },
                                            palette: Self.modelPalette),
                        centerTitle: "实际消费",
                        centerValue: String(format: "$%.2f", u.totalActualCost > 0 ? u.totalActualCost : u.totalCost)
                    )

                    // 表头
                    HStack {
                        Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                        Text("请求").frame(width: 52, alignment: .trailing)
                        Text("Token").frame(width: 62, alignment: .trailing)
                        Text("实际").frame(width: 66, alignment: .trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)

                    Divider()

                    ForEach(u.byModel) { m in
                        HStack {
                            Text(m.name)
                                .font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(m.requests)").font(.caption.monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                            Text(fmtCompact(m.tokens)).font(.caption.monospacedDigit())
                                .frame(width: 62, alignment: .trailing)
                            Text(String(format: "$%.4f", m.actualCost > 0 ? m.actualCost : m.cost))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                                .frame(width: 66, alignment: .trailing)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // ── Token 使用趋势（折线图）──
            if u.trend.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Token 使用趋势").font(.headline)
                    RelayLineChart(
                        points: u.trend.map { RelayLineChart.Point(label: shortDate($0.date), value: Double($0.tokens)) },
                        tint: .blue,
                        unit: "tok"
                    )
                    // 同一条趋势里再给一条消费线
                    Text("消费趋势").font(.subheadline).foregroundStyle(.secondary)
                    RelayLineChart(
                        points: u.trend.map { RelayLineChart.Point(label: shortDate($0.date), value: $0.actualCost) },
                        tint: .green,
                        unit: "USD"
                    )
                }
                .padding(.vertical, 4)
            }

            // ── 平台 / 端点：仍是列表，但用条形 ──
            if !u.byPlatform.isEmpty {
                NavigationLink { RelayGroupListView(title: "按平台", rows: u.byPlatform) } label: {
                    Label("按平台（\(u.byPlatform.count)）", systemImage: "square.stack.3d.up")
                }
            }
            if !u.byEndpoint.isEmpty {
                NavigationLink { RelayGroupListView(title: "按端点", rows: u.byEndpoint) } label: {
                    Label("按端点（\(u.byEndpoint.count)）", systemImage: "arrow.triangle.branch")
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

    /// 模型 / 平台配色的固定调色板，保证同一模型每次颜色一致
    static let modelPalette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .yellow, .mint, .red
    ]

    /// 把 (名称, 数值) 列表转成环形图切片；数值为 0 的丢弃，超过 8 项合并为「其它」
    private func donutSlices(_ items: [(String, Double)], palette: [Color]) -> [RelayDonutChart.Slice] {
        let positive = items.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        var out: [RelayDonutChart.Slice] = []
        for (i, item) in positive.prefix(8).enumerated() {
            out.append(RelayDonutChart.Slice(name: item.0,
                                             value: item.1,
                                             color: palette[i % palette.count]))
        }
        if positive.count > 8 {
            let rest = positive.dropFirst(8).reduce(0.0) { $0 + $1.1 }
            out.append(RelayDonutChart.Slice(name: "其它 \(positive.count - 8) 项",
                                             value: rest,
                                             color: .gray))
        }
        return out
    }

    /// "2026-09-30" → "09-30"
    private func shortDate(_ s: String) -> String {
        let parts = s.split(separator: "-")
        guard parts.count == 3 else { return s }
        return "\(parts[1])-\(parts[2])"
    }

    /// 1.72 亿 → "172.1M"
    private func fmtCompact(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

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
    @State private var site = ""
    @State private var siteChecked = false
    @State private var detectedGateway: RelayGateway?
    @State private var email = ""
    @State private var password = ""
    @State private var label = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("请输入站点地址，如 https://api.example.com", text: $site)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onChange(of: site) { _ in siteChecked = false }
                    Button {
                        Task { await checkSite() }
                    } label: {
                        HStack {
                            Text("检测站点")
                            Spacer()
                            if siteChecked {
                                Text(detectedGateway?.displayName ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(site.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                } header: {
                    Text("站点")
                } footer: {
                    Text("每个中转站有自己的地址（同一套网关也会挂不同域名）。这里填的是你要登录的那个站，不是通用的默认值。")
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

    private func checkSite() async {
        busy = true; error = nil
        switch await svc.detectGateway(site) {
        case .success(let r):
            site = r.site
            detectedGateway = r.gateway
            siteChecked = true
        case .failure(let why):
            siteChecked = false
            detectedGateway = nil
            error = why.message
        }
        busy = false
    }

    private func add() async {
        busy = true; error = nil

        // 先确认站点是有效网关，再落库。
        // 旧实现直接把账号写进列表就去登录，登录失败时那条坏记录会留在
        // 账号列表里，看起来像「加不了账号」——其实是一个永远刷不出数据的
        // 空账号。
        var gw: RelayGateway = detectedGateway ?? RelayGateway.v1
        switch await svc.detectGateway(site) {
        case .failure(let why):
            busy = false
            error = why.message + "\n（未添加任何账号）"
            return
        case .success(let r):
            site = r.site
            gw = r.gateway
            detectedGateway = gw
        }

        svc.addAccount(siteURL: site, email: email, label: label, gateway: gw)
        guard let id = svc.selectedId else { busy = false; return }
        let ok = await svc.login(accountId: id, email: email, password: password)
        busy = false
        if ok {
            password = ""
            dismiss()
        } else {
            // 登录失败 → 回滚这条记录，别留下空壳
            let reason = svc.lastError ?? "登录失败"
            svc.removeAccount(id)
            error = reason + "\n（已回滚，账号未添加）"
        }
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


// MARK: - 环形图（模型 / 平台分布）

/// 用扇形拼出的环形图。不引入 Charts 框架保持依赖最小，
/// 也避免把大块数据绑进 View 触发类型检查超时。
struct RelayDonutChart: View {
    struct Slice: Identifiable {
        var id: String { name }
        let name: String
        let value: Double
        let color: Color
    }
    let slices: [Slice]
    let centerTitle: String
    let centerValue: String

    private var total: Double { max(slices.reduce(0) { $0 + $1.value }, 0.0000001) }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                ForEach(Array(slices.enumerated()), id: \.offset) { idx, _ in
                    let a = segment(idx)
                    Circle()
                        .trim(from: a.start, to: a.end)
                        .stroke(slices[idx].color,
                                style: StrokeStyle(lineWidth: 26, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 2) {
                    Text(centerValue).font(.headline.monospacedDigit())
                    Text(centerTitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 148, height: 148)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(slices.enumerated()), id: \.offset) { _, sl in
                    HStack(spacing: 7) {
                        Circle().fill(sl.color).frame(width: 9, height: 9)
                        Text(sl.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f%%", sl.value / total * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func segment(_ idx: Int) -> (start: CGFloat, end: CGFloat) {
        var acc: Double = 0
        for i in 0..<idx { acc += slices[i].value }
        let start = acc / total
        let end = (acc + slices[idx].value) / total
        return (CGFloat(start), CGFloat(end))
    }
}

// MARK: - 折线图（趋势）

struct RelayLineChart: View {
    struct Point: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
    }
    let points: [Point]
    let tint: Color
    let unit: String

    private var maxValue: Double { max(points.map(\.value).max() ?? 1, 0.0000001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let n = max(points.count - 1, 1)
                ZStack {
                    ForEach(0..<4, id: \.self) { i in
                        let y = h * CGFloat(i) / 3
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for (i, pt) in points.enumerated() {
                            p.addLine(to: CGPoint(x: w * CGFloat(i) / CGFloat(n),
                                                  y: h - h * CGFloat(pt.value / maxValue)))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(tint.opacity(0.15))
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let c = CGPoint(x: w * CGFloat(i) / CGFloat(n),
                                            y: h - h * CGFloat(pt.value / maxValue))
                            if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    ForEach(Array(points.enumerated()), id: \.offset) { i, pt in
                        Circle().fill(tint).frame(width: 5, height: 5)
                            .position(x: w * CGFloat(i) / CGFloat(n),
                                      y: h - h * CGFloat(pt.value / maxValue))
                    }
                }
            }
            .frame(height: 128)

            HStack {
                Text(points.first?.label ?? "").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(points.last?.label ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            if let peak = points.map(\.value).max() {
                Text("峰值 " + fmtBig(peak) + (unit.isEmpty ? "" : " " + unit))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func fmtBig(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
