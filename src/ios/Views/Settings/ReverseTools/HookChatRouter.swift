//
//  HookChatRouter.swift
//  KyTuT
//
//  把「让 AI 生成 Hook」接到正常聊天会话里。
//
//  设计意图：Hook 的生成、调整、编译、注入是一个需要来回沟通的过程，
//  不应该塞进一个只能生成死模板的弹窗。这里负责：
//    1. 构造一段带目标 App 上下文的开场消息
//    2. 引导 AI 用 hook_compile / dylib_inject 两个工具完成闭环
//    3. 把本次会话与目标 App 关联，便于注入面板回读结果
//

import Foundation
import UIKit

enum HookChatRouter {

    /// 生成注入面板点「让 AI 生成 Hook」时发往聊天的开场提示。
    /// 这段文本会作为用户消息投递给 AI，AI 据此展开分析并调用工具。
    static func openingPrompt(app: InstalledAppInfo) -> String {
        var lines: [String] = []
        lines.append("帮我为下面这个 App 生成并注入 Hook。")
        lines.append("")
        lines.append("目标 App：\(app.name)")
        lines.append("Bundle ID：\(app.bundleId)")
        lines.append("Bundle 路径：\(app.bundleURL.path)")
        if let ver = Optional(app.version), !ver.isEmpty {
            lines.append("版本：\(ver)")
        }
        lines.append("加密状态：\(app.isEncrypted ? "带 FairPlay 加密（磁盘为密文）" : "已解密（可直接静态分析）")")
        if let exe = app.mainExecutableURL {
            lines.append("主二进制：\(exe.path)")
        }
        lines.append("")
        lines.append("请按这个顺序来做：")
        lines.append("1. 先用已有工具分析目标 App（r2 / binutils / strings），找出关键类与方法")
        lines.append("2. 把你想 Hook 的类名、方法名、Hook 类型和期望效果列出来，等我确认")
        lines.append("3. 我确认后，调用 hook_compile 生成 dylib")
        lines.append("4. 生成成功后调用 dylib_inject 注入，注入模式默认无痕")
        lines.append("")
        lines.append("注意：不要凭空猜测类名与方法名，必须以分析结果为依据。")

        return lines.joined(separator: "\n")
    }

    /// 发起一次 Hook 会话：
    /// 把开场提示写入 UserDefaults 并把内容放进剪贴板，
    /// 然后复用 App 已有的 newChatRequested 通知切到聊天页。
    ///
    /// 之所以不用通知的 userInfo 直接传文本：ContentView 的
    /// handleNewChatRequest() 不接受附带负载，改造它风险高于收益。
    /// 这里改用「剪贴板 + UserDefaults」双通道，用户在输入框粘贴即可，
    /// 同时 AI 侧也能通过 hook.pending.prompt 读到完整上下文。
    static func launchConversation(app: InstalledAppInfo) {
        let prompt = openingPrompt(app: app)

        UserDefaults.standard.set(prompt, forKey: "hook.pending.prompt")
        registerPendingTask(bundleID: app.bundleId)

        // 放进剪贴板，方便直接粘贴
        UIPasteboard.general.string = prompt

        // 切到聊天页
        NotificationCenter.default.post(name: .newChatRequested, object: nil)
    }

    /// AI 侧读取当前待处理的提示词
    static func pendingPrompt() -> String? {
        UserDefaults.standard.string(forKey: "hook.pending.prompt")
    }

    /// 把当前待处理的 Hook 任务登记到 UserDefaults，
    /// 供注入面板轮询「AI 是否已经产出可注入的 dylib」。
    static func registerPendingTask(bundleID: String) {
        UserDefaults.standard.set(bundleID, forKey: "hook.pending.bundleID")
        UserDefaults.standard.set(Date(), forKey: "hook.pending.since")
    }

    static func pendingBundleID() -> String? {
        UserDefaults.standard.string(forKey: "hook.pending.bundleID")
    }

    static func clearPendingTask() {
        UserDefaults.standard.removeObject(forKey: "hook.pending.bundleID")
        UserDefaults.standard.removeObject(forKey: "hook.pending.since")
        UserDefaults.standard.removeObject(forKey: "hook.pending.prompt")
    }

    /// 供 AI 工具在成功产出 dylib 后调用，记录产物路径。
    static func recordProducedDylib(_ path: String, bundleID: String) {
        UserDefaults.standard.set(path, forKey: "hook.produced.\(bundleID)")
        UserDefaults.standard.set(Date(), forKey: "hook.produced.at.\(bundleID)")
    }

    /// 取最近一次 AI 为该 App 产出的 dylib
    static func latestProducedDylib(bundleID: String) -> String? {
        guard let path = UserDefaults.standard.string(forKey: "hook.produced.\(bundleID)"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
