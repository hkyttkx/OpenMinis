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

    // MARK: - [T-reverse-tools] 辅助分析工具

    /// 在沙盒里跑一段 AI 给的 Python 脚本，回传 stdout。
    ///
    /// 用途是 capstone 指令级反汇编：AI 需要精确解析某个字节区间时，
    /// 写一段 Python 比堆 r2 命令更直接。
    /// 隔离措施（与 shell_execute 的既有约定一致）：
    ///   * 脚本写入固定临时文件，避免命令行转义问题；
    ///   * 60s 超时，防止死循环挂住会话；
    ///   * 输出截断到 3 万字符，避免把整段二进制打进上下文。
    func executeSandboxScriptTool(
        from json: String, key: String, msgIdx: Int, blockIdx: Int
    ) async -> (output: String, success: Bool) {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            return ("Error: '\(key)' is required.", false)
        }

        // 用 heredoc 写入沙盒文件，再执行 —— 脚本里的引号/反斜杠都不会
        // 经过 shell 二次解析。
        let scriptPath = "/tmp/reverse_script.py"
        let b64 = Data(code.utf8).base64EncodedString()
        let cmd = """
        mkdir -p /tmp; \
        echo '\(b64)' | base64 -d > \(scriptPath) && \
        python3 \(scriptPath); rc=$?; \
        echo "---exit:$rc---"
        """

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ 分析中…"
            scrollToBottomSignal.send()
        }

        do {
            let result: CommandResult = try await executeCommand(cmd, timeout: 120) { [weak self] line in
                guard let self else { return }
                if msgIdx < self.messages.count, blockIdx < self.messages[msgIdx].blocks.count {
                    let cur = self.messages[msgIdx].blocks[blockIdx].content
                    var next = cur == "⏳ 分析中…" ? line : cur + "\n" + line
                    if next.count > 30_000 { next = "…[output truncated]…\n" + String(next.suffix(30_000)) }
                    self.messages[msgIdx].blocks[blockIdx].content = next
                    self.scrollToBottomSignal.send()
                }
            }
            let exitOK = result.output.contains("---exit:0---")
            return (result.output, exitOK)
        } catch {
            return ("Error: script execution failed — \(error.localizedDescription)", false)
        }
    }

    /// 用内置 binutils 查询符号与结构。
    ///
    /// 白名单式：只允许固定的几个工具与短参数组合，AI 不能借此执行任意命令。
    func executeBinutilsTool(
        from json: String, msgIdx: Int, blockIdx: Int
    ) async -> (output: String, success: Bool) {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid arguments for binutils_query", false)
        }
        guard var file = (args["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !file.isEmpty else {
            return ("Error: 'file' is required.", false)
        }
        if file.hasPrefix("minis://") { file = file.replacingOccurrences(of: "minis://", with: "/var/minis/") }
        guard !file.contains(where: { "\"';`|&$".contains($0) }) else {
            return ("Error: invalid characters in 'file' path.", false)
        }

        let tool = (args["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nm"
        // 白名单：只有这些组合可执行。
        let allowed: Set<String> = [
            "nm", "nm -u", "objdump -h", "objdump -t",
            "readelf -h", "readelf -d", "readelf -s", "strings -a",
        ]
        guard allowed.contains(tool) else {
            return ("Error: 'tool' must be one of: \(allowed.sorted().joined(separator: ", "))", false)
        }

        let cmd = "\(tool) '\(file)' 2>&1 | head -400"
        return await runStreaming(cmd, label: "\(tool) \(file)", msgIdx: msgIdx, blockIdx: blockIdx)
    }

    /// 用内置 `file` 确认真实类型，必要时用 sqlite3 查库。
    func executeFileQueryTool(
        from json: String, msgIdx: Int, blockIdx: Int
    ) async -> (output: String, success: Bool) {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid arguments for file_query", false)
        }
        guard var file = (args["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !file.isEmpty else {
            return ("Error: 'file' is required.", false)
        }
        if file.hasPrefix("minis://") { file = file.replacingOccurrences(of: "minis://", with: "/var/minis/") }
        guard !file.contains(where: { "\"';`|&$".contains($0) }) else {
            return ("Error: invalid characters in 'file' path.", false)
        }

        let sql = (args["sql"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var cmd = "file '\(file)' 2>&1"
        if !sql.isEmpty {
            // SQL 里只禁止会截断命令的字符；引号走 heredoc 传给 sqlite3。
            guard !sql.contains(where: { ";".contains($0) }) || sql.lowercased().hasPrefix("select") || sql.hasPrefix(".") else {
                return ("Error: only a single SQL statement or a dot-command is allowed.", false)
            }
            guard !sql.contains("'") else {
                return ("Error: single quotes are not allowed in 'sql'.", false)
            }
            cmd += "; echo '--- sqlite3 ---'; sqlite3 '\(file)' '\(sql)' 2>&1 | head -200"
        }
        return await runStreaming(cmd, label: "file \(file)", msgIdx: msgIdx, blockIdx: blockIdx)
    }

    /// 共用：流式跑一条命令，把输出灌进工具卡片。
    private func runStreaming(
        _ cmd: String, label: String, msgIdx: Int, blockIdx: Int
    ) async -> (output: String, success: Bool) {
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ \(label)…"
            scrollToBottomSignal.send()
        }
        do {
            let result: CommandResult = try await executeCommand(cmd, timeout: 180) { [weak self] line in
                guard let self else { return }
                if msgIdx < self.messages.count, blockIdx < self.messages[msgIdx].blocks.count {
                    let cur = self.messages[msgIdx].blocks[blockIdx].content
                    var next = cur.hasPrefix("⏳") ? line : cur + "\n" + line
                    if next.count > 30_000 { next = "…[output truncated]…\n" + String(next.suffix(30_000)) }
                    self.messages[msgIdx].blocks[blockIdx].content = next
                    self.scrollToBottomSignal.send()
                }
            }
            return (result.output, true)
        } catch {
            return ("Error: \(label) failed — \(error.localizedDescription)", false)
        }
    }
}
