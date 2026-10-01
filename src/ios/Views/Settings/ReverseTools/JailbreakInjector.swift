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
import UniformTypeIdentifiers
import CoreLocation

// MARK: - 注入模式

/// 注入通道。不同越狱/系统组合下可用的通道不同，所以做成可选的：
/// 用户可指定，也可以让系统按顺序挨个试。
///
///   auto      依次尝试下面全部（默认，最省事）
///   elevate   先提权到 root 再注入（roothide 官方接口，最强）
///   roothide  roothide jbserver 加 trust cache
///   jailbreakd 走 jailbreakd XPC（Dopamine 系）
///   kfd       kfd 内核利用（iOS 16.x 及以下）
enum DynamicInjectChannel: Int, CaseIterable, Identifiable {
    case auto = 0
    case elevate = 1
    case roothide = 2
    case jailbreakd = 3
    case kfd = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto:       return "自动（挨个尝试）"
        case .elevate:    return "提权到 root"
        case .roothide:   return "roothide jbserver"
        case .jailbreakd: return "jailbreakd XPC"
        case .kfd:        return "kfd 内核利用"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:
            return "按 提权 → roothide → jailbreakd → kfd 的顺序依次尝试，任一成功即停止"
        case .elevate:
            return "用 libjailbreak 的官方接口取得 root 凭据，之后整条流程以 root 运行。成功则前面那些权限问题都不存在"
        case .roothide:
            return "调用 jbclient_trust_file_by_path 等接口加信任。Relaxin / roothide 越狱适用"
        case .jailbreakd:
            return "向 jailbreakd 发 XPC 请求写 trust cache。Dopamine 系越狱适用"
        case .kfd:
            return "走内核漏洞写 trust cache。仅 iOS 16.x 及以下有效，17 以上已被修补"
        }
    }

    var systemImage: String {
        switch self {
        case .auto:       return "wand.and.stars"
        case .elevate:    return "lock.open.fill"
        case .roothide:   return "shield.lefthalf.filled"
        case .jailbreakd: return "arrow.triangle.branch"
        case .kfd:        return "bolt.fill"
        }
    }
}

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

    // MARK: 环境探测

    /// 通过 libjailbreak 的 jbclient 接口查询真实越狱根。
    /// roothide 使用随机路径，字面量 /var/jb 在多环境下并不存在，必须走接口查询。
    /// 注意：第三方 App 进程通常拿不到 launchd 的 xpc_bootstrap_pipe，
    /// 因此这里查不到属正常现象 —— 注入由 root 子进程完成，环境判定也以子进程为准。
    /// 用户自定义的越狱根（设置里手填），存 UserDefaults。
    /// roothide 的根是随机名（`.jbroot-<32位十六进制>`），自动探测不一定命中，
    /// 因此允许手动指定，优先级最高。
    static let customRootDefaultsKey = "reverse.hostAccess.jbroot"

    static var customJailbreakRoot: String {
        get { UserDefaults.standard.string(forKey: customRootDefaultsKey) ?? "" }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { UserDefaults.standard.removeObject(forKey: customRootDefaultsKey) }
            else { UserDefaults.standard.set(t, forKey: customRootDefaultsKey) }
        }
    }

    /// 扫描 roothide 的随机越狱根。
    /// roothide 把根目录放在 App 安装包目录下，名字形如 `.jbroot-A1B99E8FE8B71244`
    /// （该目录本身就在 /var/containers/Bundle/Application 里，本进程可读）。
    /// 最近一次扫描到的根，供 dlopen 构造候选路径复用。
    private(set) static var lastScannedRoot: String?

    /// 判断候选目录是否是「完整」的越狱根。
    ///
    /// 必须校验：Relaxin/roothide 会在多个位置各放一份同名的
    /// `.jbroot-<hex>`，内容却不同（实测本机）：
    ///   /var/containers/Bundle/Application/.jbroot-XXX/     完整
    ///   /var/mobile/Containers/Shared/AppGroup/.jbroot-XXX/ 只有 var/ 与 .jbroot
    /// 只按名字取第一个，会拿到那份不完整的镜像，随后
    /// basebin/libjailbreak.dylib 找不到，libjailbreak 加载失败。
    private static func isCompleteJailbreakRoot(_ path: String) -> Bool {
        let fm = FileManager.default
        let marks = [
            "/basebin/libjailbreak.dylib",
            "/usr/lib/libjailbreak.dylib",
            "/basebin/jailbreakd",
            "/usr/bin/jbctl",
        ]
        return marks.contains { fm.fileExists(atPath: path + $0) }
    }

    static func scanRoothideRoot() -> String? {
        // 顺序有意为之：App 安装目录下那份是完整的，优先；
        // AppGroup 那份常是部分镜像，放最后。
        let parents = [
            "/var/containers/Bundle/Application",
            "/var/mobile/Containers/Bundle/Application",
            "/var/mobile/Containers/Shared/AppGroup",
        ]
        var firstIncomplete: String?

        for parent in parents {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: parent) else { continue }

            // 1) roothide 标准命名
            for name in items.filter({ $0.hasPrefix(".jbroot-") }).sorted() {
                let p = parent + "/" + name
                if isCompleteJailbreakRoot(p) {
                    lastScannedRoot = p
                    return p
                }
                if firstIncomplete == nil { firstIncomplete = p }
            }
            // 2) 兜底：其它隐藏目录
            for name in items where name.hasPrefix(".") && !name.hasPrefix(".jbroot-") {
                let p = parent + "/" + name
                if isCompleteJailbreakRoot(p) {
                    lastScannedRoot = p
                    return p
                }
            }
        }
        // 3) 只有不完整的镜像时也返回，交给上层多候选去试
        lastScannedRoot = firstIncomplete
        return firstIncomplete
    }

    /// 解析真实越狱根。顺序：
    ///   1. 用户在设置里手填的路径（最高优先级，文件存在才用）
    ///   2. libjailbreak 的 jbclient 接口（子进程里通常可用）
    ///   3. 扫描 roothide 随机根
    ///   4. 字面量 /var/jb —— 兜底
    static func resolveJailbreakRoot() -> String? {
        let custom = customJailbreakRoot
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            return custom
        }

        // libjailbreak 的真实位置（实测）：
        //   <root>/basebin/libjailbreak.dylib  ← roothide 主要放这里
        //   <root>/usr/lib/libjailbreak.dylib
        // 而不是字面量 /var/jb/usr/lib。先把已知根拼进去再试。
        var candidates: [String] = []
        for base in [custom, lastScannedRoot].compactMap({ $0 }) where !base.isEmpty {
            candidates.append(base + "/basebin/libjailbreak.dylib")
            candidates.append(base + "/usr/lib/libjailbreak.dylib")
        }
        candidates += [
            "/var/jb/basebin/libjailbreak.dylib",
            "/var/jb/usr/lib/libjailbreak.dylib",
            "/usr/lib/libjailbreak.dylib",
        ]
        for path in candidates {
            guard let h = dlopen(path, RTLD_NOW) else { continue }
            defer { dlclose(h) }

            typealias GetRootFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
            if let sym = dlsym(h, "jbclient_get_jbroot") {
                let fn = unsafeBitCast(sym, to: GetRootFn.self)
                if let p = fn(), let s = String(validatingUTF8: p), !s.isEmpty,
                   FileManager.default.fileExists(atPath: s) {
                    return s
                }
            }
            typealias JbrootFn = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
            if let sym = dlsym(h, "jbroot") {
                let fn = unsafeBitCast(sym, to: JbrootFn.self)
                if let p = "/".withCString({ fn($0) }), let s = String(validatingUTF8: p),
                   !s.isEmpty, FileManager.default.fileExists(atPath: s) {
                    return s
                }
            }
        }

        if let scanned = scanRoothideRoot() { return scanned }

        if FileManager.default.fileExists(atPath: "/var/jb") { return "/var/jb" }
        return nil
    }

    /// 通过 jbclient_roothide_jailbroken 判断越狱状态
    static func isRoothideJailbroken() -> Bool? {
        // 不要再写死 /var/jb —— roothide 的 libjailbreak 实际在
        // <root>/basebin/ 与 <root>/usr/lib/，<root> 是随机名。
        // 复用 resolveJailbreakRoot 的探测结果来拼候选路径。
        var candidates: [String] = []
        if let root = lastScannedRoot, !root.isEmpty {
            candidates.append(root + "/basebin/libjailbreak.dylib")
            candidates.append(root + "/usr/lib/libjailbreak.dylib")
        }
        let custom = customJailbreakRoot
        if !custom.isEmpty {
            candidates.append(custom + "/basebin/libjailbreak.dylib")
            candidates.append(custom + "/usr/lib/libjailbreak.dylib")
        }
        candidates += [
            "/var/jb/basebin/libjailbreak.dylib",
            "/var/jb/usr/lib/libjailbreak.dylib",
            "/usr/lib/libjailbreak.dylib",
        ]
        for path in candidates {
            guard let h = dlopen(path, RTLD_NOW) else { continue }
            defer { dlclose(h) }
            typealias Fn = @convention(c) () -> Bool
            if let sym = dlsym(h, "jbclient_roothide_jailbroken") {
                return unsafeBitCast(sym, to: Fn.self)()
            }
        }
        return nil
    }

    /// 探测当前设备的注入环境（供 UI 展示）
    static func environmentSummary() -> String {
        var lines: [String] = []
        lines.append("系统：iOS \(UIDevice.current.systemVersion)")
        lines.append("当前身份：EUID \(geteuid())")

        if let jailbroken = isRoothideJailbroken() {
            lines.append("roothide 越狱：\(jailbroken ? "是" : "否")")
        } else {
            lines.append("roothide 越狱：接口不可用（本进程无 launchd 通道，属正常）")
        }

        if let root = resolveJailbreakRoot(), !root.isEmpty {
            lines.append("越狱根：\(root)")
        } else {
            lines.append("越狱根：本进程无法查询（注入子进程会重新探测）")
        }

        // 用真实越狱根拼候选，而不是写死 /var/jb
        var libCandidates: [String] = []
        if let root = resolveJailbreakRoot(), !root.isEmpty {
            libCandidates.append(root + "/basebin/libjailbreak.dylib")
            libCandidates.append(root + "/usr/lib/libjailbreak.dylib")
        }
        libCandidates += ["/var/jb/usr/lib/libjailbreak.dylib", "/usr/lib/libjailbreak.dylib"]
        let libOK = libCandidates.contains { FileManager.default.fileExists(atPath: $0) }
        lines.append("libjailbreak：\(libOK ? "存在" : "本进程不可见")")

        // 内置的注入辅助工具
        let tools = ["opainject", "ldid", "ct_bypass", "FuckKfdHelper", "FuckEngine.dylib"]
        var found: [String] = []
        var missing: [String] = []
        for t in tools {
            if Bundle.main.path(forResource: t, ofType: nil) != nil { found.append(t) }
            else { missing.append(t) }
        }
        lines.append("已内置工具：\(found.joined(separator: "、"))")
        if !missing.isEmpty {
            lines.append("缺失工具：\(missing.joined(separator: "、"))")
        }

        lines.append("")
        lines.append("说明：第三方 App 进程默认无越狱通道，环境信息为空不代表越狱未生效。")
        lines.append("注入由 root 子进程执行，其环境判定与通道结果会写入注入日志。")
        return lines.joined(separator: "\n")
    }

    // MARK: dylib 导入

    /// 把用户从「文件」App 选择的 dylib 导入到本机管理目录，返回落盘路径。
    static func importDylib(from url: URL) throws -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicLibraries")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = url.lastPathComponent
        let dest = dir.appendingPathComponent(name)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        chmod(dest.path, 0o755)
        return dest.path
    }

    /// 列出本机已导入的 dylib
    static func listImportedDylibs() -> [String] {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicLibraries")
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.filter { $0.pathExtension == "dylib" }.map(\.path).sorted()
    }

    // MARK: 主流程

    /// 执行动态注入。
    ///
    /// 线程模型：这个方法从 SwiftUI 视图的主线程调用（调用方直接在 completion
    /// 里改 @State），但流程里有**两处长时间阻塞**：
    ///   1. `openApp` 用 LSApplicationWorkspace 把目标 App 拉到前台 —— 我们这个
    ///      App 会被切到后台；
    ///   2. `waitForPID` 在主线程上 `Thread.sleep(0.3)` 轮询最多 12 秒。
    /// 两者叠加的结果：用户切回本 App 时主线程仍卡在轮询里，界面完全无响应，
    /// 表现为「返回后就卡死」。日志也正好停在「目标未运行，尝试拉起」那两行。
    ///
    /// 因此把整个阻塞流程放到后台队列，progress / completion 统一回主线程，
    /// 调用方无需改动。
    static func inject(bundleID: String,
                       bundleURL: URL,
                       executableName: String?,
                       dylibPath: String,
                       mode: DynamicInjectMode,
                       
                       progress: @escaping (String) -> Void,
                       completion: @escaping (DynamicInjectOutcome) -> Void) {

        // 回调统一回主线程（调用方在主线程改 @State）
        let reportProgress: (String) -> Void = { step in
            DispatchQueue.main.async { progress(step) }
        }
        let finish: (DynamicInjectOutcome) -> Void = { outcome in
            DispatchQueue.main.async { completion(outcome) }
        }

        appendLog("""

        ============================================================
        [\(timeFormatter.string(from: Date()))] 动态注入开始
          目标 App ：\(bundleID)
          dylib    ：\(dylibPath)
          注入模式 ：\(mode.title)
        ------------------------------------------------------------
        """)

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            let msg = "dylib 文件不存在"
            appendLog("❌ \(msg)：\(dylibPath)")
            finish(DynamicInjectOutcome(success: false, message: msg))
            return
        }

        // ↓↓↓ 以下全部在后台线程执行，避免阻塞主线程 ↓↓↓
        //
        // 同时必须申请「后台执行断言」。
        //
        // 实测症状：点注入 → 系统把目标 App 拉起来 → 本 App 退到后台 →
        // **用户不手动切回来，注入就完全停住**。原因是 iOS 在 App 进入后台
        // 约 30 秒后把它**挂起**，被挂起的进程是「冻结」而不是「取消」——
        // 代码停在原地不动，既不报错也不前进。
        //
        // 注入恰好天生要跨前后台：拉起目标必然把自己挤到后台。
        // 所以这里必须拿一个 assertion，否则用户必须一直盯着本 App。
        // 注入开始前，先让本 App 变成「可后台运行」。
        //
        // 为什么不能用 beginBackgroundTask：
        //   它的语义是「我有事要收尾，给我几十秒」，到期必须 endBackgroundTask，
        //   否则系统直接杀进程。而注入要拉起目标 App 并把我们挤到后台，
        //   整个流程动辄十几秒到几十秒 —— 用它会正好撞上超时被杀。
        //
        // 改用持续型后台能力：注入期间打开「后台位置更新」。
        //   UIBackgroundModes 已声明 location，allowsBackgroundLocationUpdates
        //   一旦置位，系统就允许 App 在后台持续运行（配合定时的 requestLocation）。
        //   用完在 completion 里关掉，不让它长期开着耗电。
        let bgKeeper = InjectBackgroundKeeper()
        bgKeeper.start()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { bgKeeper.stop() }

            var effectiveDylib = dylibPath
            if mode == .clean {
                // 暂存目录必须放在「其他用户可读」的位置。
                //
                // 原来用 NSTemporaryDirectory()（App 私有 tmp）：目标 App 以
                // mobile(501) 运行，即使拿到 sandbox extension，路径本身是
                // 0600 的私有容器目录也穿不进去 —— dlopen 会失败。
                //
                // 改用 App Group 共享容器（已声明 group.com.openminis.app）：
                // 目录权限天然可放 o+x/o+r，配合下面的 chmod，目标进程能读。
                let stageDir: String
                if let group = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.openminis.app") {
                    stageDir = group.appendingPathComponent("dyninject_stage").path
                } else {
                    // 没有 App Group 时退回 Documents（至少不在 0600 的 tmp 下）
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    stageDir = docs.appendingPathComponent("dyninject_stage").path
                }

                try? FileManager.default.createDirectory(atPath: stageDir,
                                                         withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o755])

                let staged = (stageDir as NSString)
                    .appendingPathComponent((dylibPath as NSString).lastPathComponent)
                try? FileManager.default.removeItem(atPath: staged)

                if (try? FileManager.default.copyItem(atPath: dylibPath, toPath: staged)) != nil {
                    // 目标进程要能读：文件 o+r、目录 o+x，缺一不可
                    try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                           ofItemAtPath: staged)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: stageDir)
                    effectiveDylib = staged
                    appendLog("已暂存 dylib 到共享目录（目标进程可读）：\(staged)")
                } else {
                    appendLog("⚠️ 暂存失败，改用原路径")
                }
            }

            reportProgress("准备注入环境…")

            // 只做一次「顺手」的 PID 探测，纯信息用途。
            //
            // 关键：不要在这里卡住或提前失败。
            // FuckDynamicInjector.cliInjectWithDylibPath 内部已经有一套
            // 完整的拉起流程（实测可用）：
            //     FuckOpenApp(目标) → 等 1.5s → FuckOpenApp(自己) → 轮询查 PID
            // 而且它是按 bundleID 查进程的。
            //
            // 我们这里改成「按可执行文件路径查」，且目标由 launchd 拉起时
            // /private/var 与 /var 的写法不一致 —— 于是经常查不到。
            // 之前一查不到就 return，把后面那套能用的流程整个掐掉了，
            // 表现为「20 秒未见进程，注入失败」，其实注入器还没跑。
            let pre = findPID(bundleURL: bundleURL, executableName: executableName)
            if pre > 0 {
                appendLog("目标已在运行，PID = \(pre)")
            } else {
                appendLog("目标当前未运行；交由注入器自行拉起（它内部会处理前后台切换与重试）")
            }
            reportProgress("执行注入…")

            setenv("FUCK_INJECT_LOG_PATH", logPath, 1)

            // 通道通过环境变量传下去：OC 侧读 FUCK_INJECT_CHANNEL 决定策略，
            // 避免为此改动 injectDylib 的既有签名（它会牵动整个调用链）。
            // Swift 的 String 没有 utf8String（那是 ObjC 的 NSString），
            // 要用 withCString 取出 C 字符串指针。

            FuckDynamicInjector.injectDylib(
                effectiveDylib,
                intoBundleID: bundleID,
                mode: Int32(mode.rawValue),
                progress: { step in reportProgress(step) },
                completion: { success, message in
                    if !success {
                        captureCrashLog(executableName: executableName, bundleID: bundleID)
                    }
                    cleanup(dylib: effectiveDylib, original: dylibPath, mode: mode)
                    appendLog(success ? "✅ 注入成功：\(message ?? "")" : "❌ 注入失败：\(message ?? "")")
                    finish(DynamicInjectOutcome(success: success, message: message ?? ""))
                }
            )
        }
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
        let bufSize: Int32 = Int32(count) * Int32(MemoryLayout<pid_t>.size)
        let actual = pids.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_listallpids(ptr.baseAddress, bufSize)
        }
        guard actual > 0 else { return -1 }

        // PROC_PIDPATHINFO_MAXSIZE = 4096，正好等于这个缓冲长度
        var buf = [CChar](repeating: 0, count: 4096)
        for i in 0..<Int(actual) {
            let p = pids[i]
            guard p > 0 else { continue }
            let ok = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
                proc_pidpath(p, bp.baseAddress, UInt32(bp.count))
            }
            // 比对归一化后的路径：/private/var 与 /var 是同一条路径的两种写法，
            // 直接字符串相等会漏掉刚启动、由 launchd 拉起的进程。
            guard ok > 0 else { continue }
            let got = String(cString: buf)
            if got == target
                || got.hasPrefix("/private" + target)
                || target.hasPrefix("/private" + got)
                || got.replacingOccurrences(of: "/private/var/", with: "/var/") == target { return p }
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

    /// 拉起目标 App。
    ///
    /// 注意：主注入路径**不再使用**这个函数。FuckDynamicInjector 内部有
    /// 一套更完整的 OC 实现（包含前后台切换），见
    /// cliInjectWithDylibPath 里的 SPAWN 段。保留此实现仅供单独调用。
    ///
    /// 必须在主线程调用：LSApplicationWorkspace 是 SpringBoard 侧的私有 API，
    /// 从后台队列调用时它会静默失败（返回成功但不真的拉起），
    /// 于是随后的 waitForPID 一直等不到进程，最终报「无法获取目标进程」。
    /// 这里用 sync 回主线程，等调用真正完成再返回。
    @discardableResult
    private static func openApp(bundleID: String) -> Bool {
        var ok = false
        let work = {
            guard let wsClass = NSClassFromString("LSApplicationWorkspace") as AnyObject? else { return }
            let wsSel = NSSelectorFromString("defaultWorkspace")
            guard wsClass.responds(to: wsSel) else { return }
            guard let wsAny = wsClass.perform(wsSel)?.takeUnretainedValue() else { return }

            let openSel = NSSelectorFromString("openApplicationWithBundleID:")
            guard let ws = wsAny as? NSObject, ws.responds(to: openSel) else { return }
            _ = ws.perform(openSel, with: bundleID as NSString)
            ok = true
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.sync(execute: work) }
        return ok
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
                      now.timeIntervalSince(mtime) < 300 else { continue }
                if latest == nil || mtime > latest!.1 { latest = (full, mtime) }
            }
            guard let hit = latest,
                  let content = try? String(contentsOfFile: hit.0, encoding: .utf8) else { continue }

            appendLog("""

            ---------- 目标进程崩溃报告 ----------
            文件：\(hit.0)
            \(String(content.prefix(4096)))
            -------------------------------------
            """)
            return
        }
        appendLog("[Crash] 未找到 \(prefix) 的近期崩溃报告（可能未闪退，或报告目录不可读）")
    }
}

// MARK: - 底层 C 接口声明

@_silgen_name("proc_listallpids")
private func proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

// MARK: - 注入期间的持续后台保活

/// 注入流程需要跨前后台（拉起目标 App 会把自己挤到后台），
/// 期间必须让本 App 保持可运行，否则代码被冻结在中途、
/// 表现为「必须切回前台才继续执行」。
///
/// 这里用持续型后台能力（location），而不是 beginBackgroundTask：
/// 后者是「几十秒的收尾窗口」，超期不释放会被系统杀进程，
/// 正好与注入的时长特征冲突。
///
/// 用完必须 stop()，避免长期占用位置后台。
final class InjectBackgroundKeeper: @unchecked Sendable {

    private var manager: CLLocationManager?
    private var timer: Timer?

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let m = CLLocationManager()
            // 不改变用户授权状态，只在已有授权的前提下临时启用后台更新
            m.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            m.distanceFilter = 3000
            m.allowsBackgroundLocationUpdates = true
            m.showsBackgroundLocationIndicator = false
            m.pausesLocationUpdatesAutomatically = false
            self.manager = m
            m.startUpdatingLocation()

            // 定期 ping 一次，维持后台运行资格
            self.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.manager?.requestLocation()
            }
            if let t = self.timer {
                RunLoop.main.add(t, forMode: .common)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.manager?.stopUpdatingLocation()
            self.manager?.allowsBackgroundLocationUpdates = false
            self.manager = nil
        }
    }

    deinit {
        timer?.invalidate()
        manager?.stopUpdatingLocation()
        manager?.allowsBackgroundLocationUpdates = false
    }
}
