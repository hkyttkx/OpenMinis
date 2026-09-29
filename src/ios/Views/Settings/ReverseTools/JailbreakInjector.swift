//
//  JailbreakInjector.swift
//  KyTuT
//
//  动态注入服务（自包含实现，不依赖 RootHelper / InjectService / MachOHelper）
//
//  设计原则：保持与原动态注入实现完全一致的流程与语义 ——
//    准备 dylib → 签名 → 写入 trust cache → root 子进程执行
//    mach 线程注入（task_for_pid + mach_vm_allocate + thread_create_running +
//    远程 dlopen）→ 清理临时文件。
//
//  与原实现的唯一差别是 trust cache 写入通道：
//    原实现依赖 kfd exploit（iOS 16.x 及以下有效），在 iOS 17.x 上会闪退；
//    这里改为优先走 Relaxin / roothide 的 jbserver，其余通道作为兜底。
//
//  两种注入模式（用户在执行前选择）：
//    .strict —— 严格复刻：dylib 先拷入目标 App bundle 同级目录，注入后清理
//    .clean  —— 无痕：dylib 只在本机临时目录，不向目标 App 目录写文件
//

import Foundation
import UIKit

// MARK: - 注入模式

enum DynamicInjectMode: Int, CaseIterable, Identifiable {
    case strict = 0
    case clean = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .strict: return "严格复刻"
        case .clean:  return "无痕模式"
        }
    }

    var subtitle: String {
        switch self {
        case .strict:
            return "dylib 先复制到目标 App 同级目录再注入，兼容性最好；完成后自动清理"
        case .clean:
            return "dylib 只保存在本机临时目录，不向目标 App 写入任何文件，注入后立即清除"
        }
    }

    var systemImage: String {
        switch self {
        case .strict: return "doc.on.doc"
        case .clean:  return "eye.slash"
        }
    }
}

// MARK: - 结果

struct DynamicInjectOutcome {
    var success: Bool
    var message: String
}

// MARK: - 注入服务

enum JailbreakInjector {

    // MARK: 日志

    static var logPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("inject_debug.log").path
    }

    static func readLog() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    static func clearLog() {
        try? FileManager.default.removeItem(atPath: logPath)
    }

    static func appendLog(_ text: String) {
        let fm = FileManager.default
        let data = (text + "\n").data(using: .utf8) ?? Data()
        if fm.fileExists(atPath: logPath) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
            chmod(logPath, 0o644)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    // MARK: 环境

    /// 探测当前设备的注入环境
    static func environmentSummary() -> String {
        var lines: [String] = []
        lines.append("系统：iOS \(UIDevice.current.systemVersion)")

        let jbRoot = ["/var/jb", "/var/LIB", "/var/ulb", "/var/jbroot"]
            .first { FileManager.default.fileExists(atPath: $0) }
        lines.append("越狱根：\(jbRoot ?? "未检测到")")

        let jbLib = ["/var/jb/usr/lib/libjailbreak.dylib",
                     "/usr/lib/libjailbreak.dylib"]
            .first { FileManager.default.fileExists(atPath: $0) }
        lines.append("libjailbreak：\(jbLib ?? "未找到（回落到 jailbreakd / kfd）")")

        // 动态库路径候选（roothide 注入目录）
        let tweakDirs = ["/var/jb/usr/lib/TweakInject",
                         "/var/jb/Library/MobileSubstrate/DynamicLibraries"]
        for d in tweakDirs { lines.append("\(d)：\(FileManager.default.fileExists(atPath: d) ? "存在" : "不存在")") }

        lines.append("EUID：\(geteuid())")
        return lines.joined(separator: "\n")
    }

    // MARK: 主流程

    /// 执行动态注入
    /// - Parameters:
    ///   - bundleID: 目标 App
    ///   - bundleURL: 目标 App 的 .app 目录
    ///   - executableName: 主二进制名（用于定位崩溃报告）
    ///   - dylibPath: 要注入的 dylib
    ///   - mode: 注入模式
    static func inject(bundleID: String,
                       bundleURL: URL,
                       executableName: String?,
                       dylibPath: String,
                       mode: DynamicInjectMode,
                       progress: @escaping (String) -> Void,
                       completion: @escaping (DynamicInjectOutcome) -> Void) {

        let sessionHeader = """

        ============================================================
        [\(timeFormatter.string(from: Date()))] 动态注入开始
          目标 App ：\(bundleID)
          dylib    ：\(dylibPath)
          注入模式 ：\(mode.title)
        ------------------------------------------------------------
        """
        appendLog(sessionHeader)

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            let msg = "dylib 文件不存在"
            appendLog("❌ \(msg)：\(dylibPath)")
            completion(DynamicInjectOutcome(success: false, message: msg))
            return
        }

        // 无痕模式：dylib 固定在我方临时目录
        var effectiveDylib = dylibPath
        if mode == .clean {
            let stageDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("dyninject_stage")
            try? FileManager.default.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
            let staged = (stageDir as NSString).appendingPathComponent((dylibPath as NSString).lastPathComponent)
            try? FileManager.default.removeItem(atPath: staged)
            if (try? FileManager.default.copyItem(atPath: dylibPath, toPath: staged)) != nil {
                effectiveDylib = staged
                appendLog("已暂存 dylib 到 \(staged)")
            } else {
                appendLog("⚠️ 暂存失败，改用原路径")
            }
        }

        progress("准备注入环境…")

        // 确保目标 App 在运行
        var pid = Self.findPID(bundleURL: bundleURL, executableName: executableName)
        if pid <= 0 {
            progress("启动目标 App…")
            appendLog("目标未运行，尝试拉起")
            openApp(bundleID: bundleID)
            pid = Self.waitForPID(bundleURL: bundleURL, executableName: executableName, timeout: 12)
        }

        guard pid > 0 else {
            cleanup(dylib: effectiveDylib, original: dylibPath, mode: mode)
            let msg = "无法获取目标进程（App 未启动或已退出）"
            appendLog("❌ \(msg)")
            completion(DynamicInjectOutcome(success: false, message: msg))
            return
        }

        appendLog("目标 PID = \(pid)")
        progress("执行注入…")

        // 通过 FuckDynamicInjector 执行（内部起 root 子进程，逻辑与原实现一致）
        injectViaEngine(bundleID: bundleID,
                        dylibPath: effectiveDylib,
                        mode: mode,
                        pid: pid,
                        executableName: executableName,
                        progress: progress,
                        completion: { success, message in
            cleanup(dylib: effectiveDylib, original: dylibPath, mode: mode)
            appendLog(success ? "✅ 注入成功：\(message)" : "❌ 注入失败：\(message)")
            completion(DynamicInjectOutcome(success: success, message: message))
        })
    }

    // MARK: 引擎调用

    private static func injectViaEngine(bundleID: String,
                                        dylibPath: String,
                                        mode: DynamicInjectMode,
                                        pid: pid_t,
                                        executableName: String?,
                                        progress: @escaping (String) -> Void,
                                        completion: @escaping (Bool, String) -> Void) {

        // 日志路径通过环境变量传给 root 子进程
        setenv("FUCK_INJECT_LOG_PATH", logPath, 1)

        FuckDynamicInjector.injectDylib(
            dylibPath,
            intoBundleID: bundleID,
            mode: Int32(mode.rawValue),
            progress: { step in
                progress(step)
            },
            completion: { success, message in
                if !success {
                    // 失败时尝试抓目标 App 的崩溃报告
                    captureCrashLog(executableName: executableName, bundleID: bundleID)
                }
                completion(success, message ?? "")
            }
        )
    }

    // MARK: 清理

    private static func cleanup(dylib: String, original: String, mode: DynamicInjectMode) {
        guard mode == .clean, dylib != original else { return }
        try? FileManager.default.removeItem(atPath: dylib)
        let parent = (dylib as NSString).deletingLastPathComponent
        if let items = try? FileManager.default.contentsOfDirectory(atPath: parent), items.isEmpty {
            try? FileManager.default.removeItem(atPath: parent)
        }
        appendLog("已清除临时 dylib")
    }

    // MARK: PID 查找

    private static func findPID(bundleURL: URL, executableName: String?) -> pid_t {
        guard let exeName = executableName else { return -1 }
        let target = bundleURL.appendingPathComponent(exeName).path

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return -1 }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let actual = proc_listallpids(&pids, Int32(count * MemoryLayout<pid_t>.size))
        guard actual > 0 else { return -1 }

        var buf = [CChar](repeating: 0, count: 4096)
        for i in 0..<Int(actual) {
            let p = pids[i]
            guard p > 0 else { continue }
            if proc_pidpath(p, &buf, 4096) > 0 {
                let path = String(cString: buf)
                if path == target { return p }
            }
        }
        return -1
    }

    private static func waitForPID(bundleURL: URL, executableName: String?, timeout: TimeInterval) -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let p = findPID(bundleURL: bundleURL, executableName: executableName)
            if p > 0 { return p }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return -1
    }

    // MARK: 拉起 App

    private static func openApp(bundleID: String) {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return }
        let sel = NSSelectorFromString("defaultWorkspace")
        guard let ws = wsClass.perform(sel)?.takeUnretainedValue() as? NSObject else { return }
        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        guard ws.responds(to: openSel),
              let sig = ws.methodSignature(for: openSel) else { return }
        let inv = NSInvocation(invocationWithMethodSignature: sig)
        inv.target = ws
        inv.selector = openSel
        var bid = bundleID as NSString
        inv.setArgument(&bid, atIndex: 2)
        inv.invoke()
    }

    // MARK: 崩溃报告

    private static func captureCrashLog(executableName: String?, bundleID: String) {
        let dirs = ["/var/mobile/Library/Logs/CrashReporter",
                    "/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs",
                    "/var/root/Library/Logs/CrashReporter"]
        let fm = FileManager.default
        let prefix = executableName ?? bundleID
        let now = Date()

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            var latest: (String, Date)?
            for name in items {
                guard name.contains(prefix), name.hasSuffix(".ips") else { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let mtime = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) < 180 else { continue }
                if latest == nil || mtime > latest!.1 { latest = (full, mtime) }
            }
            guard let hit = latest,
                  let content = try? String(contentsOfFile: hit.0, encoding: .utf8) else { continue }

            let excerpt = String(content.prefix(4096))
            appendLog("""

            ---------- 目标进程崩溃报告 ----------
            文件：\(hit.0)
            \(excerpt)
            -------------------------------------
            """)
            return
        }
        appendLog("[Crash] 未找到 \(prefix) 的近期崩溃报告")
    }
}

// MARK: - 底层 C 接口声明

@_silgen_name("proc_listallpids")
private func proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32
