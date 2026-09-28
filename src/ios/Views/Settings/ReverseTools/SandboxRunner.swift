//
//  SandboxRunner.swift
//  KyTuT
//
//  逆向工具的沙盒执行通道：负责按需启动 iSH 内核，
//  并以固定会话 ID（reverse-tools）执行 Linux 命令。
//  全局挂载（/var/minis/shared 等）由 ISHExecutionCoordinator
//  在首次 execute 时自动初始化，无需聊天会话。
//

import Foundation

private let logger = AppLogger(category: "Frida")

enum SandboxRunnerError: Error, LocalizedError {
    case bootFailed(Int)
    case notBooted

    var errorDescription: String? {
        switch self {
        case .bootFailed(let code): return "iSH 内核启动失败（code \(code)）"
        case .notBooted: return "iSH 内核未启动"
        }
    }
}

enum SandboxRunner {
    /// 固定会话 ID：不参与聊天的 per-session 路由，
    /// 但复用全局静态挂载（memory/skills/shared）。
    static let sessionId = "reverse-tools"

    static func ensureKernel() throws {
        guard !ISHKernel.shared.isBooted else { return }
        try RootfsManager.shared.installIfNeeded()
        let err = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
        if err < 0 { throw SandboxRunnerError.bootFailed(Int(err)) }
        // 幂等：聊天先启动过则跳过；我们先行启动则补装路径翻译钩子
        MinisFsRouter.shared.installHook()
        RootfsManager.shared.applyDefaultMountOverlay()
        logger.info("沙盒内核已为逆向工具启动")
    }

    /// 执行一条沙盒命令，返回 (输出, 退出码)。
    /// 输出会做终端转义清理（与聊天 shell_execute 相同的净化逻辑）。
    static func run(_ command: String, timeout: TimeInterval = 300,
                    onLine: ((String) -> Void)? = nil) async throws -> (output: String, exitCode: Int) {
        do { try ensureKernel() } catch {
            onLine?("❌ \(error.localizedDescription)")
            throw error
        }
        let result = try await ISHExecutionCoordinator.shared.execute(
            sessionId: sessionId,
            command: command,
            timeout: timeout,
            lineCallback: { line in
                if let onLine { MainActor.assumeIsolated { onLine(line) } }
            },
            pidCallback: { _ in }
        )
        // sanitizeTerminalOutput 是 MainActor 隔离的静态方法，跨 actor 调用需 await
        let clean = await MainActor.run {
            AIChatViewModel.sanitizeTerminalOutput(result.output)
        }
        return (clean, result.exitCode)
    }

    /// 宿主侧共享目录（App Group shared/）对应的沙盒路径。
    /// /var/minis/shared 由静态挂载表映射，任何会话可见。
    static let guestSharedDir = "/var/minis/shared"

    /// 宿主侧 App Group shared 目录绝对路径。
    static var hostSharedDir: URL {
        let dir = AIChatViewModel.minisSharedPersistentDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
