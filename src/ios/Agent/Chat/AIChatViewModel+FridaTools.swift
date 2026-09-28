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

    // MARK: - [T-r2-tool] radare2 静态分析工具
    //
    // 与 frida_script 平级的独立工具：拼装 `r2 -q -c <commands> <file>`
    // 命令行，复用 executeCommand 执行管线（输出流式回传到工具卡片）。
    // 无内置提示词 —— 工具注册与否由「深度分析引擎」开关决定，
    // 怎么用完全由模型根据对话上下文自主判断。
    func executeR2Tool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let commands = (args["commands"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !commands.isEmpty else {
            return ("Error: 'commands' is required for r2_execute. Provide the radare2 command string (e.g. 'aaa; afl').", false)
        }
        var file = (args["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !file.isEmpty {
            // minis:// URL → Linux 路径（与其他工具的路径处理一致）
            if file.hasPrefix("minis://") { file = file.replacingOccurrences(of: "minis://", with: "/var/minis/") }
            // 防注入：路径里不允许出现引号/分号/反引号
            if file.contains(where: { "\"';`".contains($0) }) {
                return ("Error: invalid characters in 'file' path.", false)
            }
        }

        // 命令串转义：r2 -c 参数用单引号包裹，命令里的单引号转成 '\'' 
        let escaped = commands.replacingOccurrences(of: "'", with: "'\\''")
        let filePart = file.isEmpty ? "" : " '\(file)'"
        let cmd = "r2 -q -e scr.color=0 -e bin.relocs.apply=true -c '\(escaped)'\(filePart)"

        // 先检查 r2 是否已安装（工具链未装时给出明确指引）
        let check = try? await executeCommand("command -v r2 >/dev/null 2>&1 && echo R2_OK || echo R2_MISSING", timeout: 30) { _ in }
        if check?.output.contains("R2_MISSING") == true {
            return ("radare2 未安装。请到 [设置 → Frida → 沙盒工具链](minis://settings/frida) 点击「安装逆向工具链」（需开启深度分析引擎）。", false)
        }

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ r2 分析中…\n$ \(cmd.prefix(200))"
            scrollToBottomSignal.send()
        }

        do {
            var lineBuffer: [String] = []
            var lastFlush = Date.distantPast
            let kMaxDisplay = 30_000
            let result: CommandResult = try await executeCommand(cmd, timeout: 600) { [weak self] line in
                guard let self else { return }
                lineBuffer.append(line)
                if Date().timeIntervalSince(lastFlush) >= 0.2 {
                    let joined = lineBuffer.joined(separator: "\n")
                    lineBuffer.removeAll()
                    lastFlush = Date()
                    if msgIdx < self.messages.count, blockIdx < self.messages[msgIdx].blocks.count {
                        let current = self.messages[msgIdx].blocks[blockIdx].content
                        var newContent = current.hasSuffix("…") || current.contains("r2 分析中") ? joined : current + "\n" + joined
                        if newContent.count > kMaxDisplay {
                            newContent = "…[output truncated]…\n" + String(newContent.suffix(kMaxDisplay))
                        }
                        self.messages[msgIdx].blocks[blockIdx].content = newContent
                        self.scrollToBottomSignal.send()
                    }
                }
            }
            // 兜底 flush
            if !lineBuffer.isEmpty, msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                let joined = lineBuffer.joined(separator: "\n")
                let current = messages[msgIdx].blocks[blockIdx].content
                messages[msgIdx].blocks[blockIdx].content = current + "\n" + joined
            }
            return (result.output, result.exitCode == 0)
        } catch {
            return ("Error: r2 execution failed — \(error.localizedDescription)", false)
        }
    }
}
