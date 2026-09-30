import SwiftUI
import TunnelServices

private enum RWMatchType: String, CaseIterable, Identifiable {
    case glob, regex
    var id: String { rawValue }
    var title: String { rawValue == "glob" ? "Glob" : "Regex" }
}

private enum RWActionType: String, CaseIterable, Identifiable {
    case modifyRequestHeader = "modify_req_header"
    case modifyResponseHeader = "modify_rsp_header"
    case redirect
    case modifyBody = "modify_body"
    case block

    var id: String { rawValue }
    var title: String {
        switch self {
        case .modifyRequestHeader: return "修改请求头"
        case .modifyResponseHeader: return "修改响应头"
        case .redirect: return "重定向"
        case .modifyBody: return "修改 Body"
        case .block: return "拦截"
        }
    }
}

private struct HeaderItem: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct PHRewriteEditView: View {
    let rule: RewriteRule?
    let onSave: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var didLoad = false
    @State private var ruleName = ""
    @State private var urlPattern = ""
    @State private var matchType: RWMatchType = .glob
    @State private var actionType: RWActionType = .modifyRequestHeader
    @State private var priorityText = "0"

    @State private var addHeaders: [HeaderItem] = [HeaderItem(key: "", value: "")]
    @State private var replaceHeaders: [HeaderItem] = [HeaderItem(key: "", value: "")]
    @State private var removeHeaders = ""

    @State private var redirectURL = ""
    @State private var bodyFind = ""
    @State private var bodyReplace = ""
    @State private var bodyTarget = "response"
    @State private var blockStatus = "403"
    @State private var blockBody = "Blocked"

    @State private var showError = false
    @State private var errorMessage = ""

    init(rule: RewriteRule?, onSave: (() -> Void)? = nil) {
        self.rule = rule
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 基本信息
                cardSection(title: "基本信息") {
                    inputField(label: "规则名称", placeholder: "例: 去广告", text: $ruleName)
                    inputField(label: "URL 匹配", placeholder: "*.example.com/*", text: $urlPattern, mono: true)
                    segmentRow(label: "匹配方式") {
                        Picker("", selection: $matchType) {
                            ForEach(RWMatchType.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    menuRow(label: "动作类型", selection: actionType.title) {
                        ForEach(RWActionType.allCases) { type in
                            Button(type.title) { actionType = type }
                        }
                    }
                    inputField(label: "优先级", placeholder: "0", text: $priorityText, keyboard: .numberPad)
                }

                // 动作配置
                actionConfigSection

                // 保存按钮
                Button(action: saveRule) {
                    Text("保存规则")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(rule == nil ? "新建规则" : "编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadIfNeeded() }
        .alert("保存失败", isPresented: $showError) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 动作配置区域

    @ViewBuilder
    private var actionConfigSection: some View {
        switch actionType {
        case .modifyRequestHeader, .modifyResponseHeader:
            cardSection(title: "添加 Header") { headerEditor($addHeaders) }
            cardSection(title: "替换 Header") { headerEditor($replaceHeaders) }
            cardSection(title: "删除 Header") {
                inputField(label: "Header 名", placeholder: "Cookie, Authorization", text: $removeHeaders, mono: true)
            }
        case .redirect:
            cardSection(title: "重定向") {
                inputField(label: "目标 URL", placeholder: "https://new-url.com/path", text: $redirectURL, mono: true)
            }
        case .modifyBody:
            cardSection(title: "Body 替换") {
                inputField(label: "查找内容", placeholder: "要查找的文本", text: $bodyFind)
                inputField(label: "替换为", placeholder: "替换后的文本", text: $bodyReplace)
                segmentRow(label: "目标") {
                    Picker("", selection: $bodyTarget) {
                        Text("请求").tag("request")
                        Text("响应").tag("response")
                    }
                    .pickerStyle(.segmented)
                }
            }
        case .block:
            cardSection(title: "拦截设置") {
                inputField(label: "状态码", placeholder: "403", text: $blockStatus, keyboard: .numberPad)
                VStack(alignment: .leading, spacing: 6) {
                    Text("响应内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $blockBody)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(minHeight: 80)
                        .padding(8)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    // MARK: - 通用 UI 组件

    private func cardSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            VStack(spacing: 12) {
                content()
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func inputField(label: String, placeholder: String, text: Binding<String>, mono: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func segmentRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func menuRow<Content: View>(label: String, selection: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Menu {
                content()
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .font(.subheadline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Header 编辑器

    private func headerEditor(_ items: Binding<[HeaderItem]>) -> some View {
        VStack(spacing: 8) {
            ForEach(items.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("Key", text: items[i].key)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    TextField("Value", text: items[i].value)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button {
                        if items.wrappedValue.count > 1 { items.wrappedValue.remove(at: i) }
                        else { items.wrappedValue[i] = HeaderItem(key: "", value: "") }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                items.wrappedValue.append(HeaderItem(key: "", value: ""))
            } label: {
                Label("添加一行", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 数据加载与保存

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let rule else { return }

        ruleName = rule.name
        urlPattern = rule.url_pattern
        matchType = RWMatchType(rawValue: rule.match_type) ?? .glob
        actionType = RWActionType(rawValue: rule.action_type) ?? .modifyRequestHeader
        priorityText = "\(rule.priority.intValue)"

        let cfg = parseJSON(rule.action_config)
        addHeaders = parseHeaderItems(cfg["add"]); if addHeaders.isEmpty { addHeaders = [HeaderItem(key: "", value: "")] }
        replaceHeaders = parseHeaderItems(cfg["replace"]); if replaceHeaders.isEmpty { replaceHeaders = [HeaderItem(key: "", value: "")] }
        if let rm = cfg["remove"] as? [String] { removeHeaders = rm.joined(separator: ", ") }
        redirectURL = cfg["url"] as? String ?? ""
        bodyFind = cfg["find"] as? String ?? ""
        bodyReplace = cfg["replace"] as? String ?? ""
        bodyTarget = cfg["target"] as? String ?? "response"
        blockStatus = "\(cfg["status_code"] as? Int ?? 403)"
        blockBody = cfg["body"] as? String ?? "Blocked"
    }

    private func saveRule() {
        PacketHoundDataStore.shared.configureIfNeeded()
        let target = rule ?? RewriteRule()
        target.name = ruleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名规则" : ruleName
        target.url_pattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        target.match_type = matchType.rawValue
        target.action_type = actionType.rawValue
        target.priority = NSNumber(value: Int(priorityText) ?? 0)
        target.action_config = buildConfigJSON()
        if rule == nil { target.enabled = 1 }

        do {
            try target.save()
            RewriteEngine.shared.notifyRulesChanged()
            onSave?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func buildConfigJSON() -> String {
        var cfg: [String: Any] = [:]
        switch actionType {
        case .modifyRequestHeader, .modifyResponseHeader:
            let add = headerDict(addHeaders); if !add.isEmpty { cfg["add"] = add }
            let rep = headerDict(replaceHeaders); if !rep.isEmpty { cfg["replace"] = rep }
            let rm = removeHeaders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !rm.isEmpty { cfg["remove"] = rm }
        case .redirect:
            cfg["url"] = redirectURL
        case .modifyBody:
            cfg["find"] = bodyFind; cfg["replace"] = bodyReplace; cfg["target"] = bodyTarget
        case .block:
            cfg["status_code"] = Int(blockStatus) ?? 403; cfg["body"] = blockBody
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cfg) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func headerDict(_ items: [HeaderItem]) -> [String: String] {
        var r: [String: String] = [:]
        for item in items {
            let k = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { r[k] = item.value }
        }
        return r
    }

    private func parseJSON(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8), !d.isEmpty,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private func parseHeaderItems(_ v: Any?) -> [HeaderItem] {
        guard let m = v as? [String: Any], !m.isEmpty else { return [] }
        return m.keys.sorted().map { HeaderItem(key: $0, value: "\(m[$0] ?? "")") }
    }
}
