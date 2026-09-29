//
//  AppAnalysisSettingsView.swift
//
//  「设置 → 逆向工具 → 逆向分析」。
//
//  工具链是**内置**的：radare2 / capstone / binutils / file / sqlite 以及
//  r2ghidra 插件都在 rootfs 镜像里预装好（见 deps/prepare_alpine_rootfs.sh），
//  装完 App 即可用，完全离线，本页不提供也不需要任何「安装」动作。
//
//  本页只做两件事：
//    ① 目标 App 管理 —— 枚举已安装 App、读 Bundle / 数据容器、把二进制或
//       任意文件复制到沙盒，交给 AI 做静态分析。
//    ② 分析能力开关 —— 每个能力一个开关，开则该工具对 AI 可见（注册对应的
//       agent 工具），关则 AI 看不到、回落到 App 原生的 strings/hexdump 分析。
//       「随开随关」在这里是纯粹的可见性切换，不触发任何下载或安装。
//
//  动态注入（Frida Gadget）已整体移除：注入后的目标 App 一律闪退，
//  且注入链路本身不具备可维护性。静态分析是本页的完整边界。
//

import SwiftUI

// MARK: - 日志通道
enum AppAnalysisLog {
    static let logger = AppLogger(category: "Reverse")
}

// MARK: - 分析能力开关
/// 一个可开关的静态分析能力。
///
/// `defaultsKey` 是持久化键。`r2`/`ghidra` 沿用历史键名 `frida.deepAnalysis`
/// 以兼容既有用户设置 —— 键名里的 "frida" 只是历史包袱，语义早已是
/// 「深度分析引擎」，换键会让老用户的开关注状态被静默重置。
enum AnalysisCapability: String, CaseIterable, Identifiable {
    /// radare2：反汇编、函数识别、xref、字符串提取。AI 可通过 r2_execute 调用。
    case radare2
    /// r2ghidra 伪代码插件：函数级 C 伪代码（`pdg`）。
    case ghidra
    /// 反汇编引擎（capstone Python 绑定）：AI 在脚本里做指令级解析。
    case capstone
    /// binutils 增强工具集（nm / objdump / readelf / strings）。
    case binutils
    /// Mach-O / 文件格式识别（file、sqlite3 查看数据存储）。
    case fileTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radare2:  return "radare2 反汇编"
        case .ghidra:   return "r2ghidra 伪代码"
        case .capstone: return "capstone 指令引擎"
        case .binutils: return "binutils 工具集"
        case .fileTools: return "文件与数据库识别"
        }
    }

    var subtitle: String {
        switch self {
        case .radare2:  return "函数识别、交叉引用、字符串提取（AI 可调用 r2_execute）"
        case .ghidra:   return "输出函数级 C 伪代码，读懂逻辑最快的方式"
        case .capstone: return "脚本内做指令级反汇编解析"
        case .binutils: return "nm / objdump / readelf / strings 符号与结构"
        case .fileTools: return "file 类型识别、sqlite3 读目标 App 数据库"
        }
    }

    var systemImage: String {
        switch self {
        case .radare2:  return "cpu"
        case .ghidra:   return "curlybraces"
        case .capstone: return "gearshape.2"
        case .binutils: return "wrench.and.screwdriver"
        case .fileTools: return "doc.text.magnifyingglass"
        }
    }

    /// 历史键名兼容：radare2 与 ghidra 共用一个「深度分析引擎」开关。
    var defaultsKey: String {
        switch self {
        case .radare2, .ghidra: return "frida.deepAnalysis"
        case .capstone:         return "reverse.capstone"
        case .binutils:         return "reverse.binutils"
        case .fileTools:        return "reverse.fileTools"
        }
    }

    /// r2ghidra 与 radare2 是同一个开关（ghidra 是 r2 的插件，单独开关没有意义）。
    var isMirroredWithRadare2: Bool { self == .ghidra }
}

// MARK: - 逆向工具设置主页
/// 入口在「设置 → 逆向工具（逆向分析）」。
struct AppAnalysisSettingsView: View {
    @AppStorage("frida.deepAnalysis") private var r2Enabled = false
    @AppStorage("reverse.capstone")  private var capstoneEnabled = false
    @AppStorage("reverse.binutils")  private var binutilsEnabled = false
    @AppStorage("reverse.fileTools") private var fileToolsEnabled = false

    /// 工具链是否已随 rootfs 就位。只做只读探测，绝不触发安装。
    @State private var toolchainStatus: String?
    @State private var probing = false

    var body: some View {
        List {
            // MARK: 目标 App 管理
            Section {
                NavigationLink {
                    FridaAppsView()
                } label: {
                    Label("目标 App 管理", systemImage: "app.badge")
                }
            } header: {
                Text("目标应用")
            } footer: {
                Text("枚举本机已安装的 App，查看 Bundle 与数据容器，把主二进制或任意文件复制到沙盒，交给 AI 用 strings / radare2 做静态分析。")
            }

            // MARK: 分析能力开关
            Section {
                capabilityRow(.radare2)
                capabilityRow(.ghidra)
            } header: {
                Text("深度分析")
            } footer: {
                Text("开启后 AI 获得 r2_execute 工具：可对二进制做函数识别、交叉引用与字符串提取，r2ghidra 插件还能输出函数级 C 伪代码。关闭时 AI 只用 App 原生的 strings/hexdump 做轻量分析，零开销。")
            }

            Section {
                capabilityRow(.capstone)
                capabilityRow(.binutils)
                capabilityRow(.fileTools)
            } header: {
                Text("辅助工具")
            } footer: {
                Text("工具链已内置在 App 中，离线可用，切换开关即时生效，无需联网或安装。")
            }

            // MARK: 工具链自检
            Section {
                Button {
                    probeToolchain()
                } label: {
                    HStack {
                        Label("检测已内置工具", systemImage: "checkmark.shield")
                        Spacer()
                        if probing { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(probing)

                if let toolchainStatus {
                    Text(toolchainStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("工具链状态")
            } footer: {
                Text("radare2、capstone、binutils、file、sqlite3 与 r2ghidra 均随 App 内置，无需安装。此按钮只做一次只读探测，用于确认版本是否正常。")
            }
        }
        .navigationTitle("逆向分析")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 开关行

    @ViewBuilder
    private func capabilityRow(_ cap: AnalysisCapability) -> some View {
        Toggle(isOn: binding(for: cap)) {
            HStack(spacing: 12) {
                Image(systemName: cap.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(cap == .ghidra ? Color.purple : Color.blue, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap.title)
                    Text(cap.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(for cap: AnalysisCapability) -> Binding<Bool> {
        switch cap {
        case .radare2, .ghidra: return $r2Enabled
        case .capstone:         return $capstoneEnabled
        case .binutils:         return $binutilsEnabled
        case .fileTools:        return $fileToolsEnabled
        }
    }

    // MARK: - 工具链自检

    /// 只读探测：把内侧各工具的版本打出来，确认内置工具链完好。
    /// 刻意不做任何安装动作 —— 工具已经随包内置了。
    private func probeToolchain() {
        probing = true
        toolchainStatus = nil
        let cmd = """
        for t in r2 nm objdump readelf strings file sqlite3 python3; do \
          p=$(command -v $t 2>/dev/null); \
          if [ -n "$p" ]; then echo "✓ $t"; else echo "✗ $t 缺失"; fi; \
        done; \
        echo "—"; \
        r2 -v 2>/dev/null | head -1; \
        python3 -c 'import capstone;print("capstone", capstone.__version__)' 2>/dev/null || echo "capstone 模块缺失"; \
        r2 -qc 'Lc' -- 2>/dev/null | grep -i ghidra >/dev/null && echo "r2ghidra 已加载" || echo "r2ghidra 未加载（r2 pdc 仍可用）"
        """
        Task {
            do {
                let (out, _) = try await SandboxRunner.run(cmd, timeout: 90, onLine: nil)
                toolchainStatus = out.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                toolchainStatus = "探测失败：\(error.localizedDescription)"
            }
            probing = false
            AppAnalysisLog.logger.info("工具链自检完成")
        }
    }
}
