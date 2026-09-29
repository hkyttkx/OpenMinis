import Foundation

// MARK: - [T-r2-tool] radare2 静态分析工具执行
//
// 深度分析引擎（radare2 + r2ghidra）的 AI 入口：把 r2 命令拼进沙盒 shell
// 执行管线，输出流式回传到工具卡片。
//
// 与已移除的 Frida 注入无关 —— 这里只有静态分析，不加载目标进程。
extension AIChatViewModel {

    /// 执行 r2_execute 工具调用。
    /// 参数契约见 AIChatViewModel+ToolDefinitions.swift 中的工具定义。
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
            return ("radare2 未安装。请到 [设置 → 逆向分析 → 沙盒工具链](minis://settings/frida) 点击「安装逆向工具链」（需开启深度分析引擎）。", false)
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
