import SwiftUI
import TunnelServices

private enum RewriteMatchType: String, CaseIterable, Identifiable {
    case glob = "glob"
    case regex = "regex"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glob:
            return "Glob"
        case .regex:
            return "Regex"
        }
    }
}

private enum RewriteActionType: String, CaseIterable, Identifiable {
    case modifyRequestHeader = "modify_req_header"
    case modifyResponseHeader = "modify_rsp_header"
    case redirect = "redirect"
    case modifyBody = "modify_body"
    case mapLocal = "map_local"
    case block = "block"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modifyRequestHeader:
            return "修改请求头"
        case .modifyResponseHeader:
            return "修改响应头"
        case .redirect:
            return "重定向"
        case .modifyBody:
            return "修改Body"
        case .mapLocal:
            return "Map Local"
        case .block:
            return "拦截"
        }
    }
}

private struct HeaderItem: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct RewriteEditView: View {
    let rule: RewriteRule?
    let onSave: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var didLoad = false
    @State private var ruleName = ""
    @State private var urlPattern = ""
    @State private var matchType: RewriteMatchType = .glob
    @State private var actionType: RewriteActionType = .modifyRequestHeader
    @State private var priorityText = "0"

    @State private var addHeaders: [HeaderItem] = [HeaderItem(key: "", value: "")]
    @State private var replaceHeaders: [HeaderItem] = [HeaderItem(key: "", value: "")]
    @State private var removeHeaders = ""

    @State private var redirectURL = ""

    @State private var bodyFindText = ""
    @State private var bodyReplaceText = ""
    @State private var bodyTarget = "response"

    @State private var blockStatusCode = "403"
    @State private var blockBody = "Blocked"

    @State private var localMapPath = ""

    @State private var showError = false
    @State private var errorMessage = ""

    init(rule: RewriteRule?, onSave: (() -> Void)? = nil) {
        self.rule = rule
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Basic") {
                TextField("Rule Name", text: $ruleName)
                TextField("URL Pattern", text: $urlPattern)
                Picker("Match Type", selection: $matchType) {
                    ForEach(RewriteMatchType.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Picker("Action", selection: $actionType) {
                    ForEach(RewriteActionType.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField("Priority", text: $priorityText)
                    .keyboardType(.numberPad)
            }

            actionConfigSection

            Section {
                Button("Save") {
                    saveRule()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(rule == nil ? "New Rule" : "Edit Rule")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadInitialValuesIfNeeded()
        }
        .alert("Save Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private var actionConfigSection: some View {
        switch actionType {
        case .modifyRequestHeader, .modifyResponseHeader:
            Section("Add Header") {
                headerEditor(items: $addHeaders)
            }
            Section("Replace Header") {
                headerEditor(items: $replaceHeaders)
            }
            Section("Remove Header") {
                TextField("Cookie, Authorization", text: $removeHeaders)
            }

        case .redirect:
            Section("Redirect") {
                TextField("https://new-url.com/path", text: $redirectURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

        case .modifyBody:
            Section("Body Rewrite") {
                TextField("Find", text: $bodyFindText)
                TextField("Replace", text: $bodyReplaceText)
                Picker("Target", selection: $bodyTarget) {
                    Text("Request").tag("request")
                    Text("Response").tag("response")
                }
                .pickerStyle(.segmented)
            }

        case .mapLocal:
            Section("Local Mapping") {
                TextField("Local file path", text: $localMapPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

        case .block:
            Section("Block") {
                TextField("Status Code", text: $blockStatusCode)
                    .keyboardType(.numberPad)
                TextEditor(text: $blockBody)
                    .frame(minHeight: 100)
            }
        }
    }

    private func headerEditor(items: Binding<[HeaderItem]>) -> some View {
        VStack(spacing: 8) {
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField("Key", text: items[index].key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Value", text: items[index].value)
                    Button(role: .destructive) {
                        if items.wrappedValue.count > 1 {
                            items.wrappedValue.remove(at: index)
                        } else {
                            items.wrappedValue[index] = HeaderItem(key: "", value: "")
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }

            Button {
                items.wrappedValue.append(HeaderItem(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadInitialValuesIfNeeded() {
        guard !didLoad else {
            return
        }
        didLoad = true

        guard let rule else {
            return
        }

        ruleName = rule.name
        urlPattern = rule.url_pattern
        matchType = RewriteMatchType(rawValue: rule.match_type) ?? .glob
        actionType = RewriteActionType(rawValue: rule.action_type) ?? .modifyRequestHeader
        priorityText = "\(rule.priority.intValue)"

        let config = parseConfig(rule.action_config)

        addHeaders = parseHeaderItems(config["add"])
        replaceHeaders = parseHeaderItems(config["replace"])

        if let removeItems = config["remove"] as? [String] {
            removeHeaders = removeItems.joined(separator: ", ")
        }

        redirectURL = config["url"] as? String ?? ""
        bodyFindText = config["find"] as? String ?? ""
        bodyReplaceText = config["replace"] as? String ?? ""
        bodyTarget = config["target"] as? String ?? "response"
        blockStatusCode = "\(config["status_code"] as? Int ?? 403)"
        blockBody = config["body"] as? String ?? "Blocked"
        localMapPath = config["path"] as? String ?? ""

        if addHeaders.isEmpty {
            addHeaders = [HeaderItem(key: "", value: "")]
        }
        if replaceHeaders.isEmpty {
            replaceHeaders = [HeaderItem(key: "", value: "")]
        }
    }

    private func saveRule() {
        PacketHoundDataStore.shared.configureIfNeeded()

        let targetRule = rule ?? RewriteRule()
        targetRule.name = ruleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed Rule" : ruleName
        targetRule.url_pattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        targetRule.match_type = matchType.rawValue
        targetRule.action_type = actionType.rawValue
        targetRule.priority = NSNumber(value: Int(priorityText) ?? 0)
        targetRule.action_config = buildActionConfigJSON()
        if rule == nil {
            targetRule.enabled = 1
        }

        do {
            try targetRule.save()
            RewriteEngine.shared.notifyRulesChanged()
            onSave?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func parseConfig(_ jsonString: String) -> [String: Any] {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            return [:]
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            return [:]
        }

        return dict
    }

    private func parseHeaderItems(_ value: Any?) -> [HeaderItem] {
        guard let map = value as? [String: Any], !map.isEmpty else {
            return []
        }

        return map.keys.sorted().map { key in
            HeaderItem(key: key, value: "\(map[key] ?? "")")
        }
    }

    private func buildActionConfigJSON() -> String {
        var config: [String: Any] = [:]

        switch actionType {
        case .modifyRequestHeader, .modifyResponseHeader:
            let add = headerDictionary(from: addHeaders)
            let replace = headerDictionary(from: replaceHeaders)
            let remove = removeHeaders
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !add.isEmpty {
                config["add"] = add
            }
            if !replace.isEmpty {
                config["replace"] = replace
            }
            if !remove.isEmpty {
                config["remove"] = remove
            }

        case .redirect:
            config["url"] = redirectURL

        case .modifyBody:
            config["find"] = bodyFindText
            config["replace"] = bodyReplaceText
            config["target"] = bodyTarget

        case .mapLocal:
            config["path"] = localMapPath

        case .block:
            config["status_code"] = Int(blockStatusCode) ?? 403
            config["body"] = blockBody
        }

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: []) else {
            return "{}"
        }

        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func headerDictionary(from items: [HeaderItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }
            result[key] = item.value
        }
        return result
    }
}
