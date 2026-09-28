import Foundation

// MARK: - [T-frida-tool] Frida 脚本工具执行
//
// 设计原则（与设置页 FridaSettingsView 的安全边界一致）：
//   AI 只负责「生成」和「列表」，不负责注入。
//   生成的脚本进入脚本库但默认停用（enabled = false），
//   用户在「设置 → Frida → 脚本库」审阅、勾选启用后，
//   才会随 Gadget 注入管线在目标 App 中运行。
extension AIChatViewModel {

    /// 执行 frida_script 工具调用。
    /// 参数契约见 AIChatViewModel+ToolDefinitions.swift 中的工具定义。
    func executeFridaScriptTool(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: invalid arguments for frida_script"
        }

        let action = args["action"] as? String ?? ""

        switch action {
        case "generate":
            let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let desc = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = args["code"] as? String ?? ""

            guard !code.isEmpty else {
                return "Error: 'code' is required for action 'generate'. Provide the complete Frida JS source."
            }
            guard code.contains("send(") || code.contains("console.log(") else {
                return "Error: generated script must include send() or console.log() calls so captured data (keys, IVs, method args, return values) is visible in the Frida session log."
            }

            let script = FridaScript(
                name: name.isEmpty ? "AI 生成脚本 \(Date().formatted(.dateTime.month().day().hour().minute()))" : name,
                desc: desc.isEmpty ? "由 AI 生成的脚本，请审阅后启用" : desc,
                code: code,
                enabled: false  // 关键安全边界：入库默认停用，等用户审阅启用
            )
            FridaStore.addScript(script)
            FridaStore.logRuntime("AI 生成脚本已入库（待审阅）: \(script.name)")

            return """
            脚本已生成并加入脚本库（当前状态：**未启用**）。

            - 名称: \(script.name)
            - 说明: \(script.desc)
            - 代码行数: \(code.components(separatedBy: "\n").count)

            下一步：告诉用户去 [设置 → Frida → 脚本库](minis://settings/frida) 审阅该脚本并勾选启用，
            启用后脚本才会随 Gadget 注入在目标 App 中运行。
            运行输出（send/console.log 的内容）会出现在 [设置 → Frida → 会话日志](minis://settings/frida)，分类标记 [Frida]。
            （给用户的链接必须用 minis://settings/frida，不要用 skills 路径）
            """

        case "list":
            let scripts = FridaStore.loadScripts()
            if scripts.isEmpty {
                return "脚本库为空。用 action='generate' 生成第一个脚本，或在「设置 → Frida」手动新建/导入。"
            }
            var lines = ["脚本库共 \(scripts.count) 个脚本（\(scripts.filter(\.enabled).count) 个已启用）：", ""]
            for (i, s) in scripts.enumerated() {
                lines.append("\(i + 1). [\(s.enabled ? "✅ 已启用" : "⬜️ 未启用")] \(s.name) — \(s.desc)")
            }
            lines.append("")
            lines.append("在 [设置 → Frida → 脚本库](minis://settings/frida) 中切换启用状态。")
            return lines.joined(separator: "\n")

        default:
            return "Error: unknown action '\(action)'. Supported actions: 'generate', 'list'."
        }
    }
}
