//
//  HostAccessManager.swift
//  KyTuT
//
//  宿主文件访问控制。
//
//  模型（直读，不做 fakefs 挂载）：
//    参考实现（AppFetchHelper）从不挂载 —— App 凭 entitlements 的
//    no-sandbox / storage.AppBundles 权限直接用 NSFileManager 读写宿主。
//    bind mount 只是给 iSH 沙盒用的通道，App 自身读取不需要它。
//
//  控制粒度（用户完全可控）：
//    1. 全局总开关 level：off / ask / auto
//    2. 每个位置独立开关：打开/关闭某一项
//    3. 每个位置独立权限：只读 / 读写
//    4. 系统关键路径强制只读，不可绕过
//    5. 写操作可要求逐次确认（askWrite）
//

import Foundation
import UIKit
import SwiftUI

// MARK: - 访问级别

enum HostAccessLevel: String, CaseIterable, Identifiable {
    case off
    case ask
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:  return "全部关闭"
        case .ask:  return "逐项授权"
        case .auto: return "授权项自动放行"
        }
    }

    var subtitle: String {
        switch self {
        case .off:  return "AI 无法访问任何宿主文件，只能用已复制到沙盒的内容"
        case .ask:  return "AI 访问未授权位置时弹窗确认；已授权位置直接可用"
        case .auto: return "已打开开关的位置全部直接可用，不再询问"
        }
    }

    var systemImage: String {
        switch self {
        case .off:  return "lock.fill"
        case .ask:  return "hand.raised.fill"
        case .auto: return "bolt.horizontal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .off:  return .gray
        case .ask:  return .orange
        case .auto: return .green
        }
    }
}

// MARK: - 挂载权限

enum HostMountPermission: String, CaseIterable, Identifiable {
    case readOnly
    case readWrite

    var id: String { rawValue }
    var title: String { self == .readOnly ? "只读" : "读写" }
    var detail: String {
        self == .readOnly ? "AI 只能读取，无法修改或删除"
                          : "AI 可写入、修改、删除该位置内的文件"
    }
}

// MARK: - 宿主位置

struct HostLocation: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let hostPath: String
    let title: String
    let detail: String
    /// 是否允许切换为读写（所有位置都可，由用户决定）
    let allowsWrite: Bool
    /// 写入是否需要逐次弹窗确认。
    /// 只有「整个文件系统」这类全盘权限才需要；普通 App 目录不打扰。
    var requiresWriteConfirmation: Bool = false

    var guestPath: String { "/var/minis/workspace/host/\(key)" }
    var isSystemPath: Bool { !allowsWrite }

    static let builtins: [HostLocation] = [
        HostLocation(key: "apps",
                     hostPath: "/var/containers/Bundle/Application",
                     title: "已安装 App",
                     detail: "所有 App 的安装包，含主二进制与 Frameworks",
                     allowsWrite: true),
        HostLocation(key: "containers",
                     hostPath: "/var/mobile/Containers/Data/Application",
                     title: "App 数据容器",
                     detail: "各 App 的 Documents / Library / tmp",
                     allowsWrite: true),
        HostLocation(key: "shared",
                     hostPath: "/var/mobile/Containers/Shared/AppGroup",
                     title: "App 共享容器",
                     detail: "App Group 共享目录",
                     allowsWrite: true),
        HostLocation(key: "media",
                     hostPath: "/var/mobile/Media",
                     title: "用户媒体目录",
                     detail: "照片、下载、文档等用户数据",
                     allowsWrite: true),
        HostLocation(key: "jb",
                     hostPath: "/var/jb",
                     title: "越狱根",
                     detail: "越狱环境文件（roothide 下为随机路径，可在下方自定义覆盖）",
                     allowsWrite: true,
                     requiresWriteConfirmation: true),
        HostLocation(key: "root",
                     hostPath: "/",
                     title: "整个文件系统",
                     detail: "根目录，含系统文件。开启读写后 AI 每次改动都会弹窗确认",
                     allowsWrite: true,
                     requiresWriteConfirmation: true),
    ]
}

// MARK: - 弹窗请求

struct HostMountRequest: Identifiable {
    let id = UUID()
    let location: HostLocation
    let requester: String
    /// 请求的权限（AI 请求写时用于提示）
    let wantsWrite: Bool
}

// MARK: - 管理器

@MainActor
final class HostAccessManager: ObservableObject {

    static let shared = HostAccessManager()

    @Published var level: HostAccessLevel = .ask {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey)
        }
    }
    private var didFinishInit = false

    /// 已授权的位置（key → 权限）
    @Published private(set) var mounted: [String: HostMountPermission] = [:]

    /// 全局：写操作是否逐次确认
    @Published var confirmWrites: Bool = true {
        didSet { UserDefaults.standard.set(confirmWrites, forKey: Self.confirmKey) }
    }

    @Published var lastError: String?
    @Published var pendingRequest: HostMountRequest?

    private static let levelKey = "reverse.hostAccess.level"
    private static let grantsKey = "reverse.hostAccess.grants"
    private static let confirmKey = "reverse.hostAccess.confirmWrites"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.levelKey) ?? HostAccessLevel.ask.rawValue
        level = HostAccessLevel(rawValue: raw) ?? .ask

        if let d = UserDefaults.standard.dictionary(forKey: Self.grantsKey) as? [String: String] {
            mounted = d.compactMapValues { HostMountPermission(rawValue: $0) }
        }
        if UserDefaults.standard.object(forKey: Self.confirmKey) != nil {
            confirmWrites = UserDefaults.standard.bool(forKey: Self.confirmKey)
        }
        didFinishInit = true
    }

    private func persistGrants() {
        UserDefaults.standard.set(mounted.mapValues { $0.rawValue }, forKey: Self.grantsKey)
    }

    // MARK: 开关

    func setLevel(_ new: HostAccessLevel) {
        level = new
        if new == .off {
            mounted.removeAll()
            persistGrants()
        }
    }

    func isAllowed(_ loc: HostLocation) -> Bool {
        guard level != .off else { return false }
        return mounted[loc.key] != nil
    }

    func isMounted(_ loc: HostLocation) -> Bool { mounted[loc.key] != nil }

    func permission(_ loc: HostLocation) -> HostMountPermission? { mounted[loc.key] }

    /// 打开某一项（用户手动或经弹窗批准）
    @discardableResult
    func grant(_ loc: HostLocation, permission: HostMountPermission? = nil) -> Bool {
        guard level != .off else {
            lastError = "宿主访问已全部关闭"
            return false
        }
        var path = loc.hostPath
        if loc.key == "jb", let real = JailbreakInjector.resolveJailbreakRoot(), !real.isEmpty {
            path = real
        }
        guard FileManager.default.fileExists(atPath: path) else {
            lastError = "路径不存在：\(path)"
            return false
        }
        // 默认只读：由用户在设置里决定是否放开为读写。
        // 所有位置都支持切换（不再有强制只读），但默认保持安全。
        let perm = permission ?? .readOnly
        mounted[loc.key] = perm
        persistGrants()
        lastError = nil
        return true
    }

    func revoke(_ loc: HostLocation) {
        mounted.removeValue(forKey: loc.key)
        persistGrants()
    }

    func revokeAll() {
        mounted.removeAll()
        persistGrants()
    }

    /// 用户自定义位置（可任意填宿主路径）。持久化在 UserDefaults。
    static let customDefaultsKey = "reverse.hostAccess.customLocations"

    /// 读取用户自定义的位置
    static func customLocations() -> [HostLocation] {
        guard let arr = UserDefaults.standard.array(forKey: customDefaultsKey) as? [[String: String]] else {
            return []
        }
        return arr.compactMap { d in
            guard let key = d["key"], let path = d["path"] else { return nil }
            let title = d["title"] ?? (path as NSString).lastPathComponent
            return HostLocation(key: "custom:" + key,
                                hostPath: path,
                                title: title,
                                detail: "自定义位置",
                                allowsWrite: true)
        }
    }

    /// 新增一个自定义位置。key 用路径归一化后的稳定串，保证幂等。
    @discardableResult
    static func addCustomLocation(path: String, title: String? = nil) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        var arr = (UserDefaults.standard.array(forKey: customDefaultsKey) as? [[String: String]]) ?? []
        let key = p.replacingOccurrences(of: "/", with: "_")
        guard !arr.contains(where: { $0["key"] == key }) else { return false }
        arr.append(["key": key, "path": p, "title": title ?? (p as NSString).lastPathComponent])
        UserDefaults.standard.set(arr, forKey: customDefaultsKey)
        return true
    }

    static func removeCustomLocation(key: String) {
        var arr = (UserDefaults.standard.array(forKey: customDefaultsKey) as? [[String: String]]) ?? []
        arr.removeAll { $0["key"] == key }
        UserDefaults.standard.set(arr, forKey: customDefaultsKey)
    }

    /// 全部可选位置 = 内置 + 自定义
    static var allLocations: [HostLocation] { HostLocation.builtins + customLocations() }

    /// 全盘访问是否已开启（对应内置的 root 位置）。
    var isFullDiskEnabled: Bool { mounted["root"] != nil }

    /// 打开/关闭全盘访问。这是「一个开关管全部」的入口：
    /// 开启后 AI 可读写任意宿主路径（含越狱目录），
    /// 每个写操作是否弹窗确认由 `confirmWrites` 决定。
    func setFullDisk(_ on: Bool, permission: HostMountPermission = .readWrite) {
        guard let root = HostLocation.builtins.first(where: { $0.key == "root" }) else { return }
        if on { _ = grant(root, permission: permission) } else { revoke(root) }
    }

    /// 一键授权：把全部可选位置（内置 + 自定义）一次性打开。
    /// 存在的位置直接授权成功；不存在的跳过并汇总，不阻断其它项。
    @discardableResult
    func grantAll(permission: HostMountPermission = .readWrite) -> (granted: Int, skipped: [String]) {
        guard level != .off else {
            lastError = "宿主访问已全部关闭，请先切换总开关"
            return (0, [])
        }
        var granted = 0
        var skipped: [String] = []
        for loc in Self.allLocations {
            if grant(loc, permission: permission) { granted += 1 }
            else { skipped.append("\(loc.title)（\(resolvedPath(loc))）") }
        }
        lastError = skipped.isEmpty ? nil : "跳过 \(skipped.count) 项不存在的路径"
        return (granted, skipped)
    }

    func setPermission(_ loc: HostLocation, _ permission: HostMountPermission) {
        if mounted[loc.key] != nil {
            mounted[loc.key] = permission
            persistGrants()
        }
    }

    // MARK: AI 请求

    /// AI 请求访问。已授权返回 true；需确认返回 false 并挂起弹窗。
    func requestAccess(_ loc: HostLocation, requester: String, wantsWrite: Bool) -> Bool {
        if isAllowed(loc) {
            if wantsWrite, let p = mounted[loc.key], p == .readOnly {
                // 已授权但只读，且 AI 想写 → 需要确认
                pendingRequest = HostMountRequest(location: loc, requester: requester, wantsWrite: true)
                return false
            }
            return true
        }
        guard level != .off else { return false }
        pendingRequest = HostMountRequest(location: loc, requester: requester, wantsWrite: wantsWrite)
        return false
    }

    func approve(_ req: HostMountRequest, permission: HostMountPermission? = nil) {
        let perm = req.wantsWrite ? .readWrite : permission
        _ = grant(req.location, permission: perm)
        pendingRequest = nil
    }

    func deny() { pendingRequest = nil }

    /// 写操作是否需要二次确认
    func writeNeedsConfirmation(_ loc: HostLocation) -> Bool {
        confirmWrites
    }

    // MARK: 描述

    func availableDescription() -> String {
        var lines = ["当前访问级别：\(level.title)",
                     "写操作确认：\(confirmWrites ? "需要" : "不需要")", ""]
        for loc in Self.allLocations {
            let state: String
            if level == .off {
                state = "已关闭"
            } else if let p = mounted[loc.key] {
                state = "已开启（\(p.title)）"
            } else {
                state = "未开启"
            }
            lines.append("• \(loc.key) — \(loc.title)：\(state)\n    路径 \(loc.hostPath)")
        }
        return lines.joined(separator: "\n")
    }

    /// 某路径是否需要写确认（命中「需确认」的位置才需要）
    func needsWriteConfirmation(for path: String) -> Bool {
        // 全盘访问开启时，任何路径的写操作都按 confirmWrites 处理
        if isFullDiskEnabled, confirmWrites { return true }
        for loc in Self.allLocations where loc.requiresWriteConfirmation {
            guard isMounted(loc) else { continue }
            let root = resolvedPath(loc)
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// 供 HostFileAccess 判定真实路径（越狱根动态解析）。
    /// 顺序：用户手填 > 自动探测（libjailbreak / roothide 扫描） > 字面量 /var/jb。
    func resolvedPath(_ loc: HostLocation) -> String {
        guard loc.key == "jb" else { return loc.hostPath }
        if let real = JailbreakInjector.resolveJailbreakRoot(), !real.isEmpty {
            return real
        }
        return loc.hostPath
    }

    /// 越狱根：用户自定义路径（设置里可填，留空则自动探测）。
    var customJailbreakRoot: String {
        get { JailbreakInjector.customJailbreakRoot }
        set { JailbreakInjector.customJailbreakRoot = newValue; objectWillChange.send() }
    }

    /// 自动探测到的越狱根（供设置页展示/一键填入）
    var detectedJailbreakRoot: String? {
        JailbreakInjector.scanRoothideRoot()
    }
}
