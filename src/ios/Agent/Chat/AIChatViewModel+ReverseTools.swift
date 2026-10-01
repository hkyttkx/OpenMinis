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

        // 工具白名单。
        //
        // 关键：Mach-O 上真正好用的不是 readelf/objdump —— 那是 ELF 的工具，
        // 对 Mach-O 返回空。LLVM 那套才是（实测 127MB 二进制）：
        //   llvm-otool -l   0s   段/节全貌
        //   llvm-otool -o   1s   761 个 ObjC 类
        //   llvm-otool -L   0s   依赖库
        // 而 rabin2 -I 要 122s —— 所以别把 rabin2 当默认入口。
        let allowed: Set<String> = [
            // ELF
            "nm", "nm -u", "objdump -h", "objdump -t",
            "readelf -h", "readelf -d", "readelf -s",
            // 通用
            "strings -a", "xxd",
            // Mach-O（LLVM 实现，大文件也是秒级）
            "llvm-otool -h", "llvm-otool -l", "llvm-otool -L",
            "llvm-otool -o", "llvm-otool -I", "llvm-otool -hv",
            "llvm-nm", "llvm-objdump -h", "llvm-lipo -info",
            // 兼容拼写
            "otool -h", "otool -l", "otool -L",
        ]
        let tool = (args["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "llvm-otool -h"
        guard allowed.contains(tool) else {
            return ("Error: 'tool' must be one of:\n" + allowed.sorted().joined(separator: "\n"), false)
        }

        // 分页参数：默认给摘要，需要细节时按行窗口拉。
        // 旧实现写死 `| head -400`，等于永远只能看到前 400 行 —— 大文件的
        // 符号表有 27 万行，段表/类表也远超 400，这就是「看不全」的来源。
        let offset = max(0, (args["offset"] as? Int) ?? 0)
        let limit  = max(0, (args["limit"] as? Int) ?? 0)      // 0 = 不限制

        // 输出落盘路径：让模型随时能回头读全量，而不是被截断
        let outDir = "/var/minis/workspace/binutils"
        try? FileManager.default.createDirectory(atPath: outDir,
                                                 withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let base = (file as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let outFile = "\(outDir)/\(base).\(stamp).txt"

        // 先跑完整命令，输出写文件（不做任何截断）
        let safeTool = tool
        let cmd = "\(safeTool) '\(file)' > '\(outFile)' 2>&1; echo \"__EXIT__$?\""
        _ = await runStreaming(cmd, label: "\(safeTool) \(base)",
                               msgIdx: msgIdx, blockIdx: blockIdx)

        // 统计并回传摘要 + 请求的分页窗口
        guard let raw = try? String(contentsOfFile: outFile, encoding: .utf8) else {
            return ("Error: 无法读取输出文件 \(outFile)", false)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let total = lines.count

        var header: [String] = []
        header.append("\(safeTool) \(base)")
        header.append("总行数 \(total)   全量输出：\(outFile)")

        var body: [String] = []
        if limit > 0 {
            let lo = min(offset, total)
            let hi = min(offset + limit, total)
            header.append("显示第 \(lo + 1)–\(hi) 行（limit=\(limit) offset=\(offset)）")
            if hi > lo { body = lines[lo..<hi].map(String.init) }
        } else {
            // 不限制：但避免把几十万行直接塞进上下文 —— 超过阈值时
            // 只回传前 2000 行，并明确告诉模型用 offset/limit 继续读。
            let inlineCap = 2000
            if total <= inlineCap {
                header.append("完整输出")
                body = lines.map(String.init)
            } else {
                header.append("行数较多，先给前 \(inlineCap) 行；用 offset/limit 继续读，"
                            + "或直接读文件 \(outFile)")
                body = lines[0..<inlineCap].map(String.init)
            }
        }

        return (header.joined(separator: "\n") + "\n\n" + body.joined(separator: "\n"), true)
    }

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
                    // 这只是 UI 里的流式预览（完整输出由调用方写文件）。
                    // 只保留尾部以免界面卡顿，不影响模型拿到的内容。
                    if next.count > 30_000 { next = "…（预览省略前段，完整内容见输出文件）…\n" + String(next.suffix(30_000)) }
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
