import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Frida 脚本存储
/// Frida 脚本库：脚本由 AI 生成 → 用户审阅后入库 → 导出给外部注入器。
/// OpenMinis 不修改目标 App；外部注入器负责 Gadget、签名和安装。
struct FridaScript: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var desc: String
    var code: String
    var enabled: Bool = false
    var createdAt: Date = Date()
}

enum FridaExportError: LocalizedError {
    case noEnabledScripts

    var errorDescription: String? {
        switch self {
        case .noEnabledScripts: return "没有已启用的 Frida 脚本可导出"
        }
    }
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

    /// 导出脚本为 .js 文件（分享给他人 / 备份）。
    static func exportScript(_ script: FridaScript) -> URL? {
        let url = scriptsDir.appendingPathComponent("\(safeFileName(script.name)).js")
        try? script.code.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 导出给外部 TrollStore/巨魔注入器使用的完整包。
    /// 这里不绑定 Bundle ID，也不修改任何目标 App；外部注入器负责
    /// 注入 Gadget、签名和安装，loader 只负责统一脚本执行与日志回写。
    @MainActor
    static func exportEnabledPackage() throws -> URL {
        let enabled = loadScripts().filter(\.enabled)
        guard !enabled.isEmpty else { throw FridaExportError.noEnabledScripts }

        let packageDir = scriptsDir.appendingPathComponent("OpenMinis-Frida-Package", isDirectory: true)
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir.appendingPathComponent("scripts", isDirectory: true), withIntermediateDirectories: true)

        var entries: [[String: Any]] = []
        for (index, script) in enabled.enumerated() {
            let fileName = String(format: "%02d-%@.js", index + 1, safeFileName(script.name))
            let data = Data(script.code.utf8)
            try data.write(to: packageDir.appendingPathComponent("scripts").appendingPathComponent(fileName), options: .atomic)
            entries.append([
                "name": script.name,
                "description": script.desc,
                "file": "scripts/\(fileName)",
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ])
        }

        let loader = buildExternalLoader(scripts: enabled)
        try Data(loader.utf8).write(to: packageDir.appendingPathComponent("frida-loader.js"), options: .atomic)
        let config = """
{
  "interaction": {
    "type": "script",
    "path": "frida-loader.js",
    "on_change": "reload",
    "on_load": "resume"
  }
}
"""
        try Data(config.utf8).write(to: packageDir.appendingPathComponent("FridaGadget.config"), options: .atomic)

        let manifest: [String: Any] = [
            "format": 1,
            "generatedBy": "OpenMinis",
            "targetBundleId": NSNull(),
            "scripts": entries,
            "logPath": "/var/tmp/kytuT-frida.log",
            "note": "Bundle ID intentionally omitted. Use this package with any compatible external injector."
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: packageDir.appendingPathComponent("manifest.json"), options: .atomic)

        let readme = """
OpenMinis Frida 外部注入包

1. 使用外部巨魔/TrollStore 注入器将 FridaGadget.dylib 注入目标 App。
2. 将 FridaGadget.config、frida-loader.js 和 scripts/ 放到注入器要求的位置。
3. 由外部注入器负责 Mach-O 修改、重签和安装。
4. 启动目标 App 后，在 OpenMinis → 设置 → Frida → 会话日志查看：
   /var/tmp/kytuT-frida.log

此包不绑定 Bundle ID，也不会由 OpenMinis 修改或安装目标 App。
"""
        try Data(readme.utf8).write(to: packageDir.appendingPathComponent("README.txt"), options: .atomic)

        let zipURL = scriptsDir.appendingPathComponent("OpenMinis-Frida-Package.zip")
        try? FileManager.default.removeItem(at: zipURL)
        let files = try recursivePackageFiles(packageDir)
        let zipData = SkillStore.buildZipArchive(files: files)
        try zipData.write(to: zipURL, options: .atomic)
        return zipURL
    }

    private static func buildExternalLoader(scripts: [FridaScript]) -> String {
        var js = """
        (function () {
          var logFile = null;
          try { logFile = new File("/var/tmp/kytuT-frida.log", "a"); } catch (_) {}
          function writeLog(value) {
            var line = new Date().toISOString() + " " + value;
            try { if (logFile) { logFile.write(line + "\\n"); logFile.flush(); } } catch (_) {}
            try { console.log(line); } catch (_) {}
          }
          globalThis.kylog = function (value) { writeLog(String(value)); };
          globalThis.console = globalThis.console || {};
          var originalLog = globalThis.console.log;
          globalThis.console.log = function () {
            try { writeLog("[console] " + Array.prototype.slice.call(arguments).join(" ")); } catch (_) {}
            if (originalLog) { try { originalLog.apply(globalThis.console, arguments); } catch (_) {} }
          };
          globalThis.send = (function (original) {
            return function (message, data) {
              try { writeLog("[send] " + JSON.stringify(message)); } catch (_) { writeLog("[send]"); }
              if (original) { try { return original(message, data); } catch (_) {} }
            };
          })(globalThis.send);
          writeLog("[OpenMinis] Gadget loader started; scripts=\(scripts.count)");
        })();
        setTimeout(function () {
        """
        for script in scripts {
            let label = script.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
            js += "\n// script: \(label)\n(function () { try {\n\(script.code)\n} catch (e) { kylog(\"[script error] \(label): \" + e); } })();\n"
        }
        js += "\n}, 250);\n"
        return js
    }

    private static func recursivePackageFiles(_ root: URL) throws -> [(relativePath: String, data: Data)] {
        let base = root.deletingLastPathComponent()
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(String, Data)] = []
        for case let url as URL in iterator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files.append((url.path.replacingOccurrences(of: base.path + "/", with: ""), try Data(contentsOf: url)))
        }
        return files
    }

    private static func safeFileName(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        return cleaned.isEmpty ? "script" : String(cleaned.prefix(80))
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
/// OpenMinis 只负责脚本生成、校验、导出和日志回读；外部巨魔注入器负责 Gadget、签名和安装。
struct FridaSettingsView: View {
    @State private var scripts: [FridaScript] = []
    @State private var showAddSheet = false
    @State private var showImporter = false
    @State private var fridaEnabled = UserDefaults.standard.bool(forKey: "frida.masterEnabled")
    @State private var deepAnalysis = UserDefaults.standard.bool(forKey: "frida.deepAnalysis")
    @State private var exportURL: URL?
    @State private var exportError: String?

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
                Text("启用 Frida 只控制脚本与日志能力；目标 App 的 Gadget 注入、重签和安装由外部巨魔注入器完成。")
            }

            // MARK: 设备 App 读取
            Section {
                NavigationLink {
                    FridaAppsView()
                } label: {
                    Label("读取手机上的 App", systemImage: "app.badge")
                }
            } footer: {
                Text("仅读取已安装 App 的 Bundle、数据容器和路径信息。注入、重签、打包由外部巨魔注入器完成。")
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
                Button {
                    do {
                        exportURL = try FridaStore.exportEnabledPackage()
                        exportError = nil
                    } catch {
                        exportError = error.localizedDescription
                    }
                } label: {
                    Label("导出外部注入包（\(enabledScripts.count) 个脚本）", systemImage: "shippingbox")
                }
                .disabled(enabledScripts.isEmpty)
                if let exportError {
                    Text("❌ \(exportError)").font(.caption).foregroundStyle(.red)
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享最新注入包", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("脚本库 (\(enabledScripts.count)/\(scripts.count) 已启用)")
            } footer: {
                Text("脚本不绑定 Bundle ID。启用后导出外部注入包，由你的巨魔注入器负责 Gadget、重签和安装。")
            }

            // MARK: 内置深度分析
            Section {
                Toggle("深度分析引擎（内置 radare2）", isOn: $deepAnalysis)
                    .onChange(of: deepAnalysis) { on in
                        UserDefaults.standard.set(on, forKey: "frida.deepAnalysis")
                        FridaStore.logger.info(on ? "内置 radare2 深度分析已启用" : "深度分析已关闭，使用轻量分析")
                    }
                Label("radare2 随 iOS IPA 的 Alpine rootfs 内置，设备端不下载、不编译。开启后 AI 可调用 r2 做函数级分析；关闭时保持轻量 strings/hexdump 路径。", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("沙盒工具链")
            } footer: {
                Text("当前版本内置 radare2 与 pdc 反编译器。r2ghidra 不在设备上现场编译，避免网络、make 和 musl/aarch64 构建失败。")
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
///  1. 本 App 日志池里 category == "Frida" 的行（脚本、导出和分析状态）
///  2. /var/tmp/kytuT-frida.log —— 外部注入目标 App 后，loader 回写的
///     kylog、console.log 和 send 内容（本 App 有 no-sandbox 权限直读）
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
                    Text("暂无 Frida 日志。\n\n来源一：本 App 的脚本、导出和分析日志（标记 [Frida]）。\n来源二：外部注入目标 App 后，loader 回写到 /var/tmp/kytuT-frida.log 的 kylog、console.log 和 send 内容。")
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
