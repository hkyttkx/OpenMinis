import SwiftUI
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

    // IPA 导入注入
    @State private var injectBusy = false
    @State private var injectLines: [String] = []
    @State private var injectResult: Result<Void, Error>?

    // 逆向工具链安装
    @State private var toolboxBusy = false
    @State private var toolboxLines: [String] = []

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
                Button {
                    installToolbox()
                } label: {
                    if toolboxBusy {
                        HStack { ProgressView(); Text("安装中（数分钟）…") }
                    } else {
                        Label("安装逆向工具链", systemImage: "wrench.and.screwdriver")
                    }
                }
                .disabled(toolboxBusy)

                if !toolboxLines.isEmpty {
                    ForEach(Array(toolboxLines.suffix(8).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("沙盒工具链")
            } footer: {
                Text("在 Linux 沙盒安装 frida-tools、objection、lief、capstone、keystone。装好后 AI 可用 shell_execute 直接调用（Mach-O 分析 / 字节修补 / 脚本注入）。")
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

    // MARK: - 工具链安装

    private func installToolbox() {
        toolboxBusy = true
        toolboxLines = []
        let cmd = """
        apk add --no-cache python3 py3-pip zip unzip git >/dev/null 2>&1; \
        echo "[1/3] 基础包完成"; \
        apk add py3-lief py3-capstone 2>/dev/null || pip3 install --no-cache-dir lief capstone keystone-engine 2>&1 | tail -2; \
        echo "[2/3] Mach-O 库完成"; \
        pip3 install --no-cache-dir frida-tools objection 2>&1 | tail -2 || \
        pip3 install --no-cache-dir --break-system-packages frida-tools objection 2>&1 | tail -2; \
        echo "[3/3] frida-tools + objection 完成"; \
        python3 -c "import lief; print('lief', lief.__version__)" 2>&1; \
        frida --version 2>&1; \
        echo TOOLBOX_DONE
        """
        Task {
            do {
                let (out, _) = try await SandboxRunner.run(cmd, timeout: 570) { line in
                    toolboxLines.append(String(line.suffix(160)))
                }
                FridaStore.logger.info("工具链安装输出尾: \(out.suffix(300))")
                if !out.contains("TOOLBOX_DONE") {
                    toolboxLines.append("⚠️ 安装流程异常中断，可重试")
                }
            } catch {
                toolboxLines.append("❌ \(error.localizedDescription)")
            }
            toolboxBusy = false
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
