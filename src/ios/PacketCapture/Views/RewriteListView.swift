import SwiftUI
import TunnelServices

struct RewriteListView: View {
    @StateObject private var viewModel = RewriteListViewModel()

    var body: some View {
        List {
            if viewModel.rules.isEmpty {
                EmptyStateView(
                    title: "No Rewrite Rules",
                    systemImage: "arrow.triangle.branch",
                    message: "Tap + to create your first rule."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.rules, id: \.id) { rule in
                    NavigationLink(destination: RewriteEditView(rule: rule) {
                        viewModel.reload()
                    }) {
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled.intValue != 0 },
                                set: { value in
                                    viewModel.setEnabled(rule: rule, enabled: value)
                                }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.name.isEmpty ? "Unnamed Rule" : rule.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(rule.url_pattern.isEmpty ? "(match all URLs)" : rule.url_pattern)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(actionLabel(for: rule.action_type))
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(Capsule())
                        }
                    }
                }
                .onDelete(perform: viewModel.delete)
            }
        }
        .listStyle(.plain)
        .navigationTitle("HTTP Rewrite")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: RewriteEditView(rule: nil) {
                    viewModel.reload()
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            viewModel.reload()
        }
        .onAppear {
            viewModel.reload()
        }
    }

    private func actionLabel(for actionType: String) -> String {
        switch actionType {
        case "modify_req_header":
            return "Req Header"
        case "modify_rsp_header":
            return "Rsp Header"
        case "redirect":
            return "Redirect"
        case "modify_body":
            return "Body"
        case "map_local":
            return "Map Local"
        case "block":
            return "Block"
        default:
            return actionType
        }
    }
}

@MainActor
private final class RewriteListViewModel: ObservableObject {
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
        offsets.forEach { index in
            guard rules.indices.contains(index) else {
                return
            }
            let rule = rules[index]
            try? rule.delete()
        }
        RewriteEngine.shared.notifyRulesChanged()
        reload()
    }
}
