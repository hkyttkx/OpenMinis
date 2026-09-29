//
//  AppAnalysisSettingsView.swift
//
//  「设置 → 逆向工具 → 逆向分析」。
//
//  本页只保留两条能力：
//    ① 目标 App 管理 —— 枚举已安装 App、读 Bundle / 数据容器、把二进制
//       与文件复制到沙盒，供 AI 用 strings / radare2 做静态分析。
//    ② 深度分析引擎 —— 沙盒内安装 radare2 + r2ghidra，AI 可输出函数级
//       C 伪代码。
//
//  动态注入（Frida Gadget）已整体移除：注入后的目标 App 一律闪退，
//  且注入链路本身不具备可维护性。静态分析 + 沙盒工具链是本页的完整边界。
//

import SwiftUI

// MARK: - 工具链安装器（App 级单例）
/// 安装任务脱离本页的生命周期：点一次「安装」后返回聊天、切后台都继续跑。
/// 后台存活双保险：
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
        ; \
        echo "[4] 安装 radare2…"; \
        apk add --no-cache radare2 radare2-dev git cmake make g++ flex bison >/dev/null 2>&1 \
          && echo "  radare2 $(r2 -v 2>/dev/null | head -1)" || echo "  ⚠️ radare2 安装失败"; \
        echo "[5] 编译 r2ghidra（10~30 分钟，仅首次）…"; \
        r2pm -U >/dev/null 2>&1; r2pm -ci r2ghidra 2>&1 | tail -2; \
        r2 -qc 'Lc' -- 2>/dev/null | grep -i ghidra >/dev/null && echo "r2ghidra ✅" || echo "r2ghidra 未加载（可重试或用内置 pdc）"
        """ : ""
        // community 源修复：py3-lief/py3-capstone/py3-keystone/radare2
        // 全在 community 仓库，不启用就回落 pip 源码编译（musl 上必失败）。
        let cmd = """
        REP=/etc/apk/repositories; \
        if ! grep -q '/community' $REP 2>/dev/null; then \
          C=$(head -1 $REP | sed 's|/main$|/community|'); \
          case "$C" in *community*) echo "$C" >> $REP;; *) echo 'https://dl-cdn.alpinelinux.org/alpine/v3.21/community' >> $REP;; esac; \
        fi; \
        apk update >/dev/null 2>&1; \
        apk add --no-cache python3 py3-pip zip unzip git >/dev/null 2>&1; \
        echo "[1] 源就绪 + 基础包完成"; \
        apk add --no-cache py3-lief py3-capstone py3-keystone >/dev/null 2>&1 \
          && echo "[2] Mach-O 库（lief/capstone/keystone）✓" || \
          { for p in py3-lief py3-capstone py3-keystone; do apk add --no-cache $p >/dev/null 2>&1 \
            && echo "  $p ✓" || echo "  $p ✗（非核心）"; done; }; \
        apk add --no-cache radare2 >/dev/null 2>&1 \
          && echo "[3] radare2 基础包 ✓" || echo "[3] radare2 基础包 ✗（检查网络后重试）"; \
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
                // MainActor.assumeIsolated），这里同样 assume MainActor 追加。
                let onLine: (String) -> Void = { [weak self] line in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.lines.append(String(line.suffix(160)))
                        if self.lines.count > 200 {
                            self.lines.removeFirst(self.lines.count - 200)
                        }
                    }
                }
                let (out, _) = try await SandboxRunner.run(cmd, timeout: timeout, onLine: onLine)
                AppAnalysisLog.logger.info("工具链安装输出尾: \(out.suffix(300))")
                lines.append(out.contains("TOOLBOX_DONE") ? "✅ 安装结束" : "⚠️ 安装流程异常中断，可重试")
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

// MARK: - 日志通道
enum AppAnalysisLog {
    static let logger = AppLogger(category: "Reverse")
}

// MARK: - 逆向工具设置主页
/// 入口在「设置 → 逆向工具（逆向分析）」。
struct AppAnalysisSettingsView: View {
    @State private var deepAnalysis = UserDefaults.standard.bool(forKey: "frida.deepAnalysis")

    private var toolbox: ToolboxInstaller { ToolboxInstaller.shared }

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

            // MARK: 沙盒工具链
            Section {
                Toggle("深度分析引擎（radare2 + r2ghidra）", isOn: $deepAnalysis)
                    .onChange(of: deepAnalysis) { on in
                        UserDefaults.standard.set(on, forKey: "frida.deepAnalysis")
                        AppAnalysisLog.logger.info(on ? "深度分析引擎已启用" : "深度分析引擎已停用（AI 使用 strings/hexdump 轻量分析）")
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
                Text("关闭时：AI 用 strings/hexdump 做轻量情报分析（默认，零成本）。开启时：安装并使用 radare2 + r2ghidra，AI 可输出函数级 C 伪代码（代码级深挖，首次安装 r2ghidra 需源码编译约 10~30 分钟，一次性）。两种模式都包含 lief、capstone、keystone。点击安装后可返回聊天或切后台，安装继续进行，回到本页查看进度。")
            }
        }
        .navigationTitle("逆向分析")
        .navigationBarTitleDisplayMode(.inline)
    }
}
