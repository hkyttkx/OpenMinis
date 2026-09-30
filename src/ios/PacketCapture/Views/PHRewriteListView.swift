import SwiftUI
import TunnelServices

struct PHRewriteListView: View {
    @StateObject private var viewModel = RewriteListVM()

    var body: some View {
        List {
            if viewModel.rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("暂无重写规则")
                        .font(.headline)
                    Text("点击右上角 + 创建第一条规则")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.rules, id: \.id) { rule in
                    NavigationLink(destination: PHRewriteEditView(rule: rule) { viewModel.reload() }) {
                        ruleRow(rule)
                    }
                }
                .onDelete(perform: viewModel.delete)
            }
        }
        .listStyle(.plain)
        .navigationTitle("HTTP 重写")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: PHRewriteEditView(rule: nil) { viewModel.reload() }) {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear { viewModel.reload() }
    }

    private func ruleRow(_ rule: RewriteRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled.intValue != 0 },
                set: { viewModel.setEnabled(rule: rule, enabled: $0) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                    .font(.subheadline.weight(.semibold))
                Text(rule.url_pattern.isEmpty ? "(匹配所有 URL)" : rule.url_pattern)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(actionLabel(rule.action_type))
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(.tertiarySystemBackground))
                .clipShape(Capsule())
        }
    }

    private func actionLabel(_ type: String) -> String {
        switch type {
        case "modify_req_header": return "请求头"
        case "modify_rsp_header": return "响应头"
        case "redirect": return "重定向"
        case "modify_body": return "Body"
        case "map_local": return "本地映射"
        case "block": return "拦截"
        default: return type
        }
    }
}

@MainActor
private final class RewriteListVM: ObservableObject {
    @Published var rules: [RewriteRule] = []

    func reload() {
        PacketHoundDataStore.shared.configureIfNeeded()
        rules = RewriteRule.findAll(orders: ["priority": false, "id": false])
    }

    func setEnabled(rule: RewriteRule, enabled: Bool) {
        rule.enabled = NSNumber(value: enabled ? 1 : 0)
        try? rule.update()
        RewriteEngine.shared.notifyRulesChanged()
    }

    func delete(at offsets: IndexSet) {
        offsets.forEach { i in
            guard rules.indices.contains(i) else { return }
            try? rules[i].delete()
        }
        RewriteEngine.shared.notifyRulesChanged()
        reload()
    }
}
