//
//  AIChatViewModel+HookTools.swift
//  KyTuT
//
//  Hook 生成与注入的 AI 工具实现。
//
//  联动机制：
//    - hook_compile  把 Hook 描述编译成可注入的 dylib（基于内置 AVCodec 模板）
//    - dylib_inject  通过 URL Scheme 唤醒独立的「kyTuT 注入器」自动执行全系统注入
//                    并实时读取全系统共享日志（/var/mobile/Documents/inject_debug.log）
//

import Foundation
import UIKit

extension AIChatViewModel {

    // MARK: - hook_compile

    /// 把 Hook 配置编译成 dylib。
    /// 参数：hooks（JSON 数组字符串）、name（产物名）、hook_delay（可选）
    func executeHookCompileTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for hook_compile.", false)
        }

        let hooksJSON = (args["hooks"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hooksJSON.isEmpty else {
            return ("Error: 'hooks' is required. Pass a JSON array of hook objects.", false)
        }

        let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "HookDylib"
        let hookDelay = (args["hook_delay"] as? Double)
            ?? Double((args["hook_delay"] as? String) ?? "")
            ?? 3.0

        // 解析 hooks
        guard let hooksData = hooksJSON.data(using: .utf8) else {
            return ("Error: cannot encode 'hooks'.", false)
        }

        struct RawHook: Decodable {
            var className: String
            var methodName: String
            var isClassMethod: Bool?
            var kind: String?
            var hookType: String?
            var returnValue: String?
            var property: String?
            var argumentOverrides: [String: String]?
            var delay: Double?
            var enabled: Bool?
        }

        let rawHooks: [RawHook]
        do {
            rawHooks = try JSONDecoder().decode([RawHook].self, from: hooksData)
        } catch {
            return ("Error: 'hooks' is not a valid hook array: \(error.localizedDescription)\nExpected each item to have className and methodName.", false)
        }

        guard !rawHooks.isEmpty else {
            return ("Error: 'hooks' is empty. Provide at least one hook.", false)
        }

        // 映射为构建器模型
        let kindMap: [String: HookConfigBuilder.HookKind] = [
            "methodSwizzle": .methodSwizzle,
            "flexOverride": .flexOverride,
            "modifyProperty": .modifyProperty,
            "returnConstant": .returnConstant,
            "blockMethod": .blockMethod,
            "logMethod": .logMethod,
        ]

        var hooks: [HookConfigBuilder.Hook] = []
        for (i, r) in rawHooks.enumerated() {
            let kindRaw = r.kind ?? r.hookType ?? "logMethod"
            guard let kind = kindMap[kindRaw] else {
                return ("Error: hook #\(i + 1) has unknown hookType '\(kindRaw)'. Valid values: \(kindMap.keys.sorted().joined(separator: ", ")).", false)
            }
            hooks.append(HookConfigBuilder.Hook(
                className: r.className,
                methodName: r.methodName,
                isClassMethod: r.isClassMethod ?? false,
                kind: kind,
                returnValue: r.returnValue,
                property: r.property,
                argumentOverrides: r.argumentOverrides,
                delay: r.delay,
                enabled: r.enabled ?? true
            ))
        }

        // 更新卡片
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ 正在生成动态库…\n\(hooks.count) 条 Hook"
            scrollToBottomSignal.send()
        }

        let result = HookConfigBuilder.build(hooks: hooks, name: name, hookDelay: hookDelay)

        guard result.success, let path = result.dylibPath else {
            return ("Error: \(result.message)", false)
        }

        // 自动将编译产物同步一份到宿主公共 Documents/DynamicLibraries 目录，供独立注入器直接秒选
        let pubDir = URL(fileURLWithPath: "/var/mobile/Documents/DynamicLibraries")
        try? FileManager.default.createDirectory(at: pubDir, withIntermediateDirectories: true)
        let pubDest = pubDir.appendingPathComponent((path as NSString).lastPathComponent)
        try? FileManager.default.removeItem(at: pubDest)
        try? FileManager.default.copyItem(atPath: path, toPath: pubDest.path)

        // 自检产物
        let verifyMsg = HookConfigBuilder.verify(dylibPath: path)

        let dylibName = (path as NSString).lastPathComponent
        let out = """
        ✅ \(result.message)
        产物路径：\(path)
        自检：\(verifyMsg)

        提示：已同步至公共动态库目录，你可以直接在聊天中让我调用 dylib_inject 注入，或点击下方唤醒独立注入器：
        👉 [唤醒 kyTuT 注入器执行注入](kytut-inject://inject?bundleId=\(HookChatRouter.pendingBundleID() ?? "")&dylib=\(dylibName))
        """
        return (out, true)
    }

    // MARK: - dylib_inject (一键唤醒独立注入器)

    /// 把 dylib 注入到目标 App。
    /// 机制：优先通过 URL Scheme 唤醒独立的「kyTuT 注入器」执行注入
    func executeDylibInjectTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for dylib_inject.", false)
        }

        let bundleID = (args["bundle_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dylibPath = (args["dylib_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !bundleID.isEmpty else {
            return ("Error: 'bundle_id' is required.", false)
        }
        guard !dylibPath.isEmpty else {
            return ("Error: 'dylib_path' is required.", false)
        }

        let dylibName = (dylibPath as NSString).lastPathComponent

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ 正在唤醒 kyTuT 注入器对 \(bundleID) 进行注入…"
            scrollToBottomSignal.send()
        }

        // 构造一键联动唤醒 URL: kytut-inject://inject?bundleId=xxx&dylib=xxx
        let schemeStr = "kytut-inject://inject?bundleId=\(bundleID)&dylib=\(dylibName)"
        guard let schemeURL = URL(string: schemeStr) else {
            return ("Error: 无效的联动协议 URL", false)
        }

        // 异步调起独立注入器
        await MainActor.run {
            UIApplication.shared.open(schemeURL, options: [:], completionHandler: nil)
        }

        // 等待 2 秒后读取共享日志
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let logTail = Self.readInjectLogTail(lines: 30)

        return ("""
        🚀 已向 kyTuT 注入器发送注入指令！
        目标：\(bundleID)
        插件：\(dylibName)

        全系统共享注入日志（最新记录）：
        \(logTail)

        提示：如未自动切回，请点击：[打开 kyTuT 注入器](kytut-inject://open) 查看注入详情。
        """, true)
    }
}

// MARK: - 全系统共享注入日志读取

extension AIChatViewModel {

    /// 读取注入日志末尾若干行（优先读取全系统共享日志 /var/mobile/Documents/inject_debug.log）
    static func readInjectLogTail(lines: Int = 40) -> String {
        let sharedPath = "/var/mobile/Documents/inject_debug.log"
        if let content = try? String(contentsOfFile: sharedPath, encoding: .utf8) {
            let all = content.components(separatedBy: "\n")
            return all.suffix(lines).joined(separator: "\n")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let path = docs?.appendingPathComponent("inject_debug.log").path,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "（注入日志为空）"
        }
        let all = content.components(separatedBy: "\n")
        return all.suffix(lines).joined(separator: "\n")
    }
}
