//
//  AIChatViewModel+HookTools.swift
//  KyTuT
//
//  Hook 生成与注入的 AI 工具实现。
//
//  配合 AIChatViewModel+ToolDefinitions 中的工具定义：
//    - hook_compile  把 Hook 描述编译成可注入的 dylib（基于内置 FuckEngine 模板）
//    - dylib_inject  把 dylib 注入到目标 App 并返回结果
//
//  这两个工具串起来就是完整闭环：AI 分析 → 生成配置 → 产出 dylib → 询问用户 → 注入。
//

import Foundation

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

        // 自检产物
        let verifyMsg = HookConfigBuilder.verify(dylibPath: path)

        // 记录产出，供注入面板回读
        if let bid = HookChatRouter.pendingBundleID() {
            HookChatRouter.recordProducedDylib(path, bundleID: bid)
        }

        let out = """
        ✅ \(result.message)
        产物路径：\(path)
        自检：\(verifyMsg)

        下一步：确认要把这个动态库注入到哪个 App，然后调用 dylib_inject。
        例：dylib_inject 参数 bundle_id=<目标 bundleId>, dylib_path=\(path), mode=clean
        """
        return (out, true)
    }

    // MARK: - dylib_inject

    /// 把 dylib 注入到目标 App。
    /// 参数：bundle_id、dylib_path、mode（strict / clean）、confirmed
    func executeDylibInjectTool(from json: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool)? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Error: invalid JSON arguments for dylib_inject.", false)
        }

        let bundleID = (args["bundle_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dylibPath = (args["dylib_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modeRaw = (args["mode"] as? String)?.lowercased() ?? "clean"

        guard !bundleID.isEmpty else {
            return ("Error: 'bundle_id' is required.", false)
        }
        guard !dylibPath.isEmpty else {
            return ("Error: 'dylib_path' is required.", false)
        }
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            return ("Error: dylib not found at \(dylibPath). Generate it first with hook_compile.", false)
        }

        let mode: DynamicInjectMode = (modeRaw == "strict") ? .strict : .clean

        // 解析目标 App 信息（需要 bundleURL 与主二进制名）
        let apps = InstalledAppsService.listApps(includeSystem: true)
        guard let app = apps.first(where: { $0.bundleId == bundleID }) else {
            return ("Error: 未找到 bundleId 为 \(bundleID) 的已安装 App。", false)
        }

        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].content = "⏳ 正在注入到 \(app.name)…"
            scrollToBottomSignal.send()
        }

        let outcome: DynamicInjectOutcome = await withCheckedContinuation { cont in
            JailbreakInjector.inject(
                bundleID: app.bundleId,
                bundleURL: app.bundleURL,
                executableName: app.mainExecutableURL?.lastPathComponent,
                dylibPath: dylibPath,
                mode: mode,
                progress: { _ in },
                completion: { cont.resume(returning: $0) }
            )
        }

        // 把日志尾部一并回传，便于 AI 解释失败原因
        let logTail = JailbreakInjector.tailOfLog(lines: 40)

        if outcome.success {
            HookChatRouter.clearPendingTask()
            return ("""
            ✅ 注入成功
            目标：\(app.name)（\(bundleID)）
            模式：\(mode.title)
            dylib：\((dylibPath as NSString).lastPathComponent)

            提示：注入是运行时行为，目标 App 重启后失效。
            """, true)
        } else {
            return ("""
            ❌ 注入失败：\(outcome.message)

            注入日志尾部：
            \(logTail)

            可参考日志判断失败环节（信任缓存通道 / 权限 / 目标进程状态）。
            """, false)
        }
    }
}
