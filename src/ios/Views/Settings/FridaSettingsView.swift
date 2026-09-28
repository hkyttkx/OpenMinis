import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Frida 脚本存储
/// 内置 Frida 脚本库：脚本由 AI 生成 → 用户审阅后「内置」入库 → 注入时勾选启用。
/// 存储在 App Group 容器，方便与改造后的目标 App（Gadget 回连）共享。
struct FridaScript: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var desc: String
    var code: String
    var enabled: Bool = false
    var createdAt: Date = Date()
}

enum FridaStore {
    static let logger = AppLogger(category: "Frida")

    static var scriptsDir: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.openminis.app")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FridaScripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { scriptsDir.appendingPathComponent("index.json") }

    static func loadScripts() -> [FridaScript] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([FridaScript].self, from: data)) ?? []
    }

    static func saveScripts(_ scripts: [FridaScript]) {
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    static func addScript(_ script: FridaScript) {
        var all = loadScripts()
        all.append(script)
        saveScripts(all)
        logger.info("Frida 脚本已内置: \(script.name)")
    }

    static func removeScript(_ script: FridaScript) {
        var all = loadScripts()
        all.removeAll { $0.id == script.id }
        saveScripts(all)
        logger.info("Frida 脚本已删除: \(script.name)")
    }

    static func toggleScript(_ script: FridaScript) {
        var all = loadScripts()
        if let idx = all.firstIndex(where: { $0.id == script.id }) {
            all[idx].enabled.toggle()
            saveScripts(all)
        }
    }

    /// 日志通道：Frida 运行输出写入 App 日志系统，带 "Frida" 分类标记，
    /// 在「设置 → 日志」里按分类过滤即可查看。
    static func logRuntime(_ message: String) {
        logger.info(message)
    }

    /// 导出脚本为 .js 文件（分享给他人 / 备份）
    static func exportScript(_ script: FridaScript) -> URL? {
        let url = scriptsDir.appendingPathComponent("\(script.name).js")
        try? script.code.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 读取日志池中 Frida 分类的行。
    /// AppLogger 已将 [Frida] 前缀写入 CrashReporter 日志池，这里按标记过滤。
    static func recentFridaLogLines() -> [String] {
        Array(CrashReporter.shared.logRingSnapshot()
            .filter { $0.contains("[Frida]") }
            .suffix(300))
    }
}

// MARK: - 工具链安装器（App 级单例）
/// 安装任务脱离 Frida 设置页的生命周期：点一次「安装」后返回聊天、
/// 切后台都继续跑。后台存活双保险：
///   ① BackupKeepAlive 静音保活（App 已声明 audio 后台模式，进程保持调度）
///   ② beginBackgroundTask 有限额度兜底（到期且保活仍在 → 重领）
/// 极端内存压力下系统仍可能挂起进程：任务暂停而非终止，回前台续跑。
@MainActor
final class ToolboxInstaller: ObservableObject {
    static let shared = ToolboxInstaller()

    @Published private(set) var busy = false
    @Published private(set) var lines: [String] = []

    private var bgTaskID = UIBackgroundTaskIdentifier.invalid

    func start(deepAnalysis: Bool) {
        guard !busy else { return }   // 防重复点击；进行中的安装不受影响

        busy = true
        lines = []

        // 深度分析开启时额外装 radare2 + r2ghidra（源码编译，一次性）
        let r2Part = deepAnalysis ? """
        echo "[4] 安装 radare2…"; \
        if apk add --no-cache radare2 radare2-dev git cmake make g++ flex bison >/dev/null 2>&1; then \
          echo "  radare2 $(r2 -v 2>/dev/null | head -1)"; \
        else \
          echo "  ⚠️ radare2 安装失败"; \
        fi; \
        echo "[5] 编译 r2ghidra（10~30 分钟，仅首次）…"; \
        if command -v r2pm >/dev/null 2>&1; then \
          r2pm -U >/dev/null 2>&1 || true; \
          r2pm -ci r2ghidra 2>&1 | tail -2 || true; \
          r2 -qc 'Lc' -- 2>/dev/null | grep -i ghidra >/dev/null && echo "r2ghidra ✅" || echo "r2ghidra 未加载（可重试或用内置 pdc）"; \
        else \
          echo "r2pm 不可用，跳过 r2ghidra"; \
        fi
        """ : ""
        // Alpine's package set differs by release/architecture. The old
        // script hid every error and printed TOOLBOX_DONE even without frida.
        // Keep optional analysis packages best-effort, but fail hard when the
        // runtime required by Frida is unavailable.
        let cmd = """
        set -eu
        REP=/etc/apk/repositories
        if ! grep -q '/community' "$REP" 2>/dev/null; then
          C=$(head -1 "$REP" | sed 's|/main$|/community|')
          case "$C" in *community*) echo "$C" >> "$REP";; *) echo 'https://dl-cdn.alpinelinux.org/alpine/v3.21/community' >> "$REP";; esac
        fi
        apk update
        apk add --no-cache python3 py3-pip zip unzip git
        echo "[1] 源就绪 + 基础包完成"
        for p in py3-lief py3-capstone py3-keystone; do
          if apk add --no-cache "$p" >/dev/null 2>&1; then
            echo "  $p ✓"
          else
            echo "  $p ✗（非核心，跳过）"
          fi
        done
        if apk add --no-cache frida-tools py3-frida >/dev/null 2>&1 && command -v frida >/dev/null 2>&1; then
          echo "[3] frida-tools ✓（apk）"
        else
          echo "[3] Alpine 没有可用 frida 包，尝试 pip wheel…"
          python3 -m pip install --no-cache-dir --break-system-packages frida-tools frida
          command -v frida >/dev/null 2>&1 || { echo "[fatal] frida 安装后仍不可执行"; exit 21; }
          echo "[3] frida-tools ✓（pip）"
        fi
        if python3 -m pip install --no-cache-dir --no-deps --break-system-packages objection >/dev/null 2>&1; then
          echo "  objection ✓"
        else
          echo "  objection ✗（非核心，跳过）"
        fi
        echo "frida $(frida --version)"
        \(r2Part)
        echo TOOLBOX_DONE
        """
        // r2ghidra 源码编译耗时 10~30 分钟，开启深度分析时放宽超时
        let timeout: TimeInterval = deepAnalysis ? 2400 : 570

        // 后台双保险：静音保活 + 有限后台任务
        BackupKeepAlive.begin()
        armBackgroundTask()

        Task {
            defer {
                busy = false
                endBackgroundTask()
                BackupKeepAlive.end()
            }
            do {
                // onLine 由 SandboxRunner 在主线程同步回调（其内部
                // MainActor.assumeIsolated），这里同样assume MainActor 追加。
                let onLine: (String) -> Void = { [weak self] line in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.lines.append(String(line.suffix(160)))
                        if self.lines.count > 200 {
                            self.lines.removeFirst(self.lines.count - 200)
                        }
                    }
                }
                let (out, code) = try await SandboxRunner.run(cmd, timeout: timeout, onLine: onLine)
                FridaStore.logger.info("工具链安装退出码 \(code)，输出尾: \(out.suffix(300))")
                if code == 0, out.contains("TOOLBOX_DONE") {
                    lines.append("✅ 安装结束")
                } else {
                    let tail = String(out.split(separator: "\\n").suffix(3).joined(separator: " | "))
                    lines.append("❌ 安装失败（exit \(code)）: \(tail)")
                }
            } catch {
                lines.append("❌ \(error.localizedDescription)")
            }
        }
    }

    /// 领一个有限后台任务；到期时若静音保活仍持有进程 → 重领续命。
    private func armBackgroundTask() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "ToolboxInstall") { [weak self] in
            // 到期回调在主队列；系统挂起前必须结束该任务避免看门狗杀进程。
            MainActor.assumeIsolated {
                guard let self else { return }
                let expiring = self.bgTaskID
                self.bgTaskID = .invalid
                if expiring != .invalid { UIApplication.shared.endBackgroundTask(expiring) }
                if BackupKeepAlive.isActive { self.armBackgroundTask() }
            }
        }
    }

    private func endBackgroundTask() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }
}

// MARK: - Frida 设置主页
/// 入口在「设置 → 逆向工具（Frida）」。
/// 巨魔（TrollStore）模式：先对目标 IPA 注入 FridaGadget.dylib → 重签 → 安装，
/// 目标 App 启动时自动加载勾选的脚本。
struct FridaSettingsView: View {
    @State private var scripts: [FridaScript] = []
    @State private var showAddSheet = false
    @State private var showImporter = false
    @State private var showTargetPicker = false
    @State private var showIPAImporter = false
    @State private var fridaEnabled = UserDefaults.standard.bool(forKey: "frida.masterEnabled")
    @State private var deepAnalysis = UserDefaults.standard.bool(forKey: "frida.deepAnalysis")

    // IPA 导入注入
    @State private var injectBusy = false
    @State private var injectLines: [String] = []
    @State private var injectResult: Result<Void, Error>?

    // 逆向工具链安装（App 级单例：离开本页/切后台安装都继续）
    @ObservedObject private var toolbox = ToolboxInstaller.shared

    var enabledScripts: [FridaScript] { scripts.filter(\.enabled) }

    var body: some View {
        List {
            // MARK: 启用状态
            Section {
                Toggle("启用 Frida", isOn: $fridaEnabled)
                    .onChange(of: fridaEnabled) { on in
                        UserDefaults.standard.set(on, forKey: "frida.masterEnabled")
                        FridaStore.logger.info(on ? "Frida 已启用" : "Frida 已停用")
                    }
            } footer: {
                Text("启用后，通过 Gadget 注入改造的目标 App 将在启动时自动运行已勾选的脚本。TrollStore 模式无需越狱。")
            }

            // MARK: 目标 App
            Section {
                Button {
                    showTargetPicker = true
                } label: {
                    Label("目标 App 管理", systemImage: "app.badge")
                }
                Button {
                    showIPAImporter = true
                } label: {
                    if injectBusy {
                        HStack { ProgressView(); Text("注入中…") }
                    } else {
                        Label("导入 IPA 注入", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(injectBusy || enabledScripts.isEmpty)

                if !injectLines.isEmpty {
                    ForEach(Array(injectLines.suffix(6).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if case .failure(let e)? = injectResult {
                        Text("❌ \(e.localizedDescription)").font(.caption).foregroundStyle(.red)
                    }
                    if case .success? = injectResult {
                        Text("✅ 已调起 TrollStore 安装").font(.caption).foregroundStyle(.green)
                    }
                }
            } header: {
                Text("目标应用")
            } footer: {
                Text("方式一：从已安装且已解密的 App 克隆注入（TrollStore 装的 App 磁盘上即解密）。方式二：导入已砸壳的 IPA。加密的 App Store 包需先砸壳。")
            }

            // MARK: 脚本库
            Section {
                ForEach(scripts) { script in
                    FridaScriptRow(script: script) {
                        FridaStore.toggleScript(script)
                        scripts = FridaStore.loadScripts()
                    } onDelete: {
                        FridaStore.removeScript(script)
                        scripts = FridaStore.loadScripts()
                    }
                }
                .onDelete { offsets in
                    for i in offsets { FridaStore.removeScript(scripts[i]) }
                    scripts = FridaStore.loadScripts()
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("新建脚本", systemImage: "plus.circle.fill")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("导入 .js 文件", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("脚本库 (\(enabledScripts.count)/\(scripts.count) 已启用)")
            } footer: {
                Text("让 AI 在对话中生成脚本 → 审阅后「内置此脚本」。注入时仅运行已勾选的脚本，精准命中目标。")
            }

            // MARK: 沙盒工具链
            Section {
                Toggle("深度分析引擎（radare2 + r2ghidra）", isOn: $deepAnalysis)
                    .onChange(of: deepAnalysis) { on in
                        UserDefaults.standard.set(on, forKey: "frida.deepAnalysis")
                        FridaStore.logger.info(on ? "深度分析引擎已启用" : "深度分析引擎已停用（AI 使用 strings/hexdump 轻量分析）")
                    }

                Button {
                    toolbox.start(deepAnalysis: deepAnalysis)
                } label: {
                    if toolbox.busy {
                        HStack { ProgressView(); Text("后台安装中（可离开本页 / 切后台）…") }
                    } else {
                        Label(deepAnalysis ? "安装逆向工具链（含 r2ghidra 源码编译）" : "安装逆向工具链",
                              systemImage: "wrench.and.screwdriver")
                    }
                }
                .disabled(toolbox.busy)

                if !toolbox.lines.isEmpty {
                    ForEach(Array(toolbox.lines.suffix(8).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("沙盒工具链")
            } footer: {
                Text("关闭时：AI 用 strings/hexdump 做轻量情报分析（默认，零成本）。开启时：安装并使用 radare2 + r2ghidra，AI 可输出函数级 C 伪代码（代码级深挖，首次安装 r2ghidra 需源码编译约 10~30 分钟，一次性）。两种模式都包含 frida-tools、objection、lief、capstone、keystone。点击安装后可返回聊天或切后台，安装继续进行，回到本页查看进度。")
            }

            // MARK: 会话日志
            Section {
                NavigationLink {
                    FridaLogView()
                } label: {
                    Label("Frida 会话日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("日志")
            } footer: {
                Text("本 App 日志（分类 Frida）+ 目标 App 内脚本回写（/var/tmp/kytuT-frida.log）都在这里实时显示。")
            }
        }
        .navigationTitle("Frida")
        .onAppear { scripts = FridaStore.loadScripts() }
        .sheet(isPresented: $showAddSheet) {
            FridaScriptEditView { new in
                FridaStore.addScript(new)
                scripts = FridaStore.loadScripts()
            }
        }
        // UTType.javascript 是 iOS 17+ 才有的符号；用扩展名动态解析保持 iOS 16 兼容
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "js") ?? .plainText]) { result in
            if case .success(let url) = result {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                if let code = try? String(contentsOf: url, encoding: .utf8) {
                    FridaStore.addScript(FridaScript(
                        name: url.deletingPathExtension().lastPathComponent,
                        desc: "导入的脚本",
                        code: code))
                    scripts = FridaStore.loadScripts()
                }
            }
        }
        .fileImporter(isPresented: $showIPAImporter,
                      allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
            if case .success(let url) = result {
                startIPAInject(url)
            }
        }
        .sheet(isPresented: $showTargetPicker) {
            FridaAppsView()
        }
    }

    // MARK: - IPA 导入注入

    private func startIPAInject(_ url: URL) {
        injectBusy = true
        injectLines = []
        injectResult = nil
        let scripts = enabledScripts
        Task {
            do {
                try await IPAInjector.importAndInject(ipaURL: url, scripts: scripts) { line in
                    injectLines.append(line)
                }
                injectResult = .success(())
            } catch {
                injectResult = .failure(error)
                FridaStore.logger.error("IPA 注入失败: \(error.localizedDescription)")
            }
            injectBusy = false
        }
    }
}

// MARK: - 脚本行
private struct FridaScriptRow: View {
    let script: FridaScript
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: script.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(script.enabled ? .green : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name).font(.body.weight(.medium))
                Text(script.desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ShareLink(item: FridaStore.exportScript(script) ?? URL(fileURLWithPath: "/dev/null")) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - 脚本编辑
struct FridaScriptEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""
    @State private var code = "// Frida JS 脚本\n// 提示：在 AI 对话中描述需求，让 AI 生成后粘贴到这里\n"
    let onSave: (FridaScript) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("脚本名称", text: $name)
                TextField("描述（做什么用的）", text: $desc)
                Section("脚本代码") {
                    TextEditor(text: $code)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 260)
                }
            }
            .navigationTitle("新建脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("内置") {
                        onSave(FridaScript(name: name.isEmpty ? "未命名" : name,
                                           desc: desc.isEmpty ? "无描述" : desc,
                                           code: code))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Frida 实时日志
/// 两个来源合并显示：
///  1. 本 App 日志池里 category == "Frida" 的行（注入流程、工具链安装）
///  2. /var/tmp/kytuT-frida.log —— 注入改造后的目标 App 里脚本 kylog() 的回写
///     （Gadget script 模式，目标进程写，本进程有 no-sandbox 权限直读）
struct FridaLogView: View {
    @State private var lines: [String] = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 目标 App 回写日志（每次全量读，尾部截断）。
    private static func targetLogLines() -> [String] {
        guard let text = try? String(contentsOfFile: "/var/tmp/kytuT-frida.log",
                                     encoding: .utf8) else { return [] }
        return Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(300))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if lines.isEmpty {
                    Text("暂无 Frida 日志。\n\n来源一：本 App 的注入 / 工具链操作日志（标记 [Frida]）。\n来源二：被注入目标 App 内脚本的 kylog() 回写（/var/tmp/kytuT-frida.log），注入并启动目标 App 后出现。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Frida 日志")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in
            lines = FridaStore.recentFridaLogLines() + Self.targetLogLines()
        }
    }
}
