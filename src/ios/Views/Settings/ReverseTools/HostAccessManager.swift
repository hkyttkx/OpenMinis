//
//  HostAccessManager.swift
//  KyTuT
//
//  宿主文件系统访问控制。
//
//  背景：
//    iSH 是用户态模拟的 Alpine，只看得见经 fakefs 挂载的路径。要让沙盒内的
//    分析工具（r2 / nm / strings / sqlite3）读到手机上任意文件，必须把宿主
//    目录 bind mount 进 fakefs —— 内核接口是 ISHKernel 的
//    bindMountPath:toHostPath:readOnly:。
//
//    已有的「挂载外部文件夹」走 iOS 标准的 UIDocumentPicker + security-scoped
//    bookmark，只覆盖「文件」App 可见的目录；/var/containers/... 这类位置挂不上。
//    在巨魔 + 越狱环境下 App 有 no-sandbox 权限，可以直接 bind 任意宿主路径。
//
//  三种访问级别（用户在设置里选）：
//    .off       关闭 —— 不暴露任何宿主路径
//    .ask       询问 —— AI 每次尝试访问新路径时弹出确认，批准后本次会话内记住
//    .auto      全自动 —— 白名单内的常用位置直接暴露，不打扰
//
//  两档权限：
//    .readOnly  只读 —— 默认。系统路径（越狱根、根目录）强制只读，不可绕过
//    .readWrite 读写 —— 仅对 App 数据容器这类低风险位置开放
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
        case .off:  return "关闭"
        case .ask:  return "询问后访问"
        case .auto: return "全自动访问"
        }
    }

    var subtitle: String {
        switch self {
        case .off:  return "不向 AI 暴露任何宿主文件，静态分析只能读取已复制到沙盒的文件"
        case .ask:  return "AI 每次访问新位置时弹窗确认，批准后本次会话内有效"
        case .auto: return "常用位置（已装 App、数据容器、越狱根）直接可读，不再询问"
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

    var title: String {
        switch self {
        case .readOnly:  return "只读"
        case .readWrite: return "读写"
        }
    }

    var detail: String {
        switch self {
        case .readOnly:  return "AI 只能读取，无法修改或删除"
        case .readWrite: return "AI 可写入、修改、删除该目录内的文件"
        }
    }
}

// MARK: - 常用宿主位置

struct HostLocation: Identifiable, Hashable {
    var id: String { key }
    let key: String          // 短名，AI 用这个名字引用
    let hostPath: String     // 宿主真实路径
    let title: String
    let detail: String
    /// 是否允许切换到读写。系统路径固定为 false（风险高）
    let allowsWrite: Bool

    var guestPath: String { "/var/minis/host/\(key)" }

    /// 是否属于系统关键路径（强制只读）
    var isSystemPath: Bool { !allowsWrite }

    static let builtins: [HostLocation] = [
        HostLocation(key: "apps",
                     hostPath: "/var/containers/Bundle/Application",
                     title: "已安装 App",
                     detail: "所有 App 的安装包，含主二进制与 Frameworks",
                     allowsWrite: false),
        HostLocation(key: "containers",
                     hostPath: "/var/mobile/Containers/Data/Application",
                     title: "App 数据容器",
                     detail: "各 App 的 Documents / Library / tmp —— 默认读写，AI 可读改写",
                     allowsWrite: true),
        HostLocation(key: "shared",
                     hostPath: "/var/mobile/Containers/Shared/AppGroup",
                     title: "App 共享容器",
                     detail: "App Group 共享目录 —— 默认读写",
                     allowsWrite: true),
        HostLocation(key: "jb",
                     hostPath: "/var/jb",
                     title: "越狱根",
                     detail: "越狱环境文件（roothide 下可能是随机路径）—— 强制只读",
                     allowsWrite: false),
        HostLocation(key: "root",
                     hostPath: "/",
                     title: "整个文件系统",
                     detail: "根目录 —— 强制只读，权限最高，仅建议临时使用",
                     allowsWrite: false),
    ]
}

// MARK: - 挂载请求（供 UI 弹窗）

struct HostMountRequest: Identifiable {
    let id = UUID()
    let location: HostLocation
    /// 触发方（通常是 AI 工具调用）
    let requester: String
}

// MARK: - 访问管理

@MainActor
final class HostAccessManager: ObservableObject {

    static let shared = HostAccessManager()

    /// 当前访问级别（持久化）
    @Published var level: HostAccessLevel = .ask {
        didSet {
            guard didFinishInit else { return }
            UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey)
        }
    }

    /// init 期间 didSet 不该执行业务逻辑
    private var didFinishInit = false

    /// 本次会话已批准的挂载点（key 集合）
    @Published private(set) var approvedKeys: Set<String> = []

    /// 已成功挂载的位置（key → 实际权限）
    @Published private(set) var mounted: [String: HostMountPermission] = [:]

    /// 最近一次失败原因（供 UI 提示）
    @Published var lastError: String?

    /// 待确认的挂载请求（UI 监听此属性弹窗）
    @Published var pendingRequest: HostMountRequest?

    private static let levelKey = "reverse.hostAccess.level"
    private static let autoKeysKey = "reverse.hostAccess.autoKeys"

    /// 全自动模式下默认放行的位置（不含 root —— 即使全自动也不默认暴露根目录）
    private static let autoDefaultKeys: Set<String> = ["apps", "containers", "jb"]

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.levelKey) ?? HostAccessLevel.ask.rawValue
        let loadedLevel = HostAccessLevel(rawValue: raw) ?? .ask

        if let saved = UserDefaults.standard.array(forKey: Self.autoKeysKey) as? [String] {
            approvedKeys = Set(saved)
        } else {
            approvedKeys = Self.autoDefaultKeys
        }

        level = loadedLevel
        didFinishInit = true
    }

    // MARK: 级别切换

    func setLevel(_ new: HostAccessLevel) {
        level = new
        switch new {
        case .auto:
            approvedKeys.formUnion(Self.autoDefaultKeys)
        case .off:
            approvedKeys.removeAll()
            unmountAll()
        case .ask:
            break
        }
        persistApproved()
    }

    private func persistApproved() {
        UserDefaults.standard.set(Array(approvedKeys), forKey: Self.autoKeysKey)
    }

    // MARK: 授权查询

    func isAllowed(_ loc: HostLocation) -> Bool {
        switch level {
        case .off:
            return false
        case .auto:
            return Self.autoDefaultKeys.contains(loc.key) || approvedKeys.contains(loc.key)
        case .ask:
            return approvedKeys.contains(loc.key)
        }
    }

    func isMounted(_ loc: HostLocation) -> Bool {
        mounted[loc.key] != nil
    }

    /// AI 请求访问某位置。返回 true 表示已可直接使用（无需 UI 交互）。
    func requestAccess(_ loc: HostLocation, requester: String) -> Bool {
        if isAllowed(loc) {
            ensureMounted(loc)
            return true
        }
        if level == .off {
            return false
        }
        pendingRequest = HostMountRequest(location: loc, requester: requester)
        return false
    }

    func approve(_ request: HostMountRequest, permission: HostMountPermission? = nil) {
        approvedKeys.insert(request.location.key)
        persistApproved()
        ensureMounted(request.location, permission: permission)
        pendingRequest = nil
    }

    func deny() {
        pendingRequest = nil
    }

    // MARK: 内核

    /// bind mount 要求 iSH 内核已启动 —— 未启动时 fakefs_bind_mount 直接返回 -1。
    /// 用户在设置页点挂载时往往还没用过沙盒，因此这里必须先确保内核就绪。
    private func ensureKernelReady() -> Bool {
        if ISHKernel.shared.isBooted { return true }

        do {
            try RootfsManager.shared.installIfNeeded()
            let err = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
            if err < 0 {
                lastError = "iSH 内核启动失败（code \(err)），无法挂载宿主目录"
                return false
            }
            MinisFsRouter.shared.installHook()
            RootfsManager.shared.applyDefaultMountOverlay()
            return true
        } catch {
            lastError = "沙盒根文件系统准备失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: 实际挂载

    /// 执行 bind mount（幂等）
    @discardableResult
    func ensureMounted(_ loc: HostLocation, permission: HostMountPermission? = nil) -> Bool {
        // 已挂载：若权限有变则重新挂载
        if let current = mounted[loc.key] {
            if let want = permission, want != current {
                _ = ISHKernel.shared.bindUnmountPath(loc.guestPath)
                mounted.removeValue(forKey: loc.key)
            } else {
                return true
            }
        }

        lastError = nil

        guard ensureKernelReady() else { return false }

        // 越狱根是随机路径，需动态解析
        var hostPath = loc.hostPath
        if loc.key == "jb" {
            if let real = JailbreakInjector.resolveJailbreakRoot(), !real.isEmpty {
                hostPath = real
            }
        }

        guard FileManager.default.fileExists(atPath: hostPath) else {
            lastError = "宿主路径不存在：\(hostPath)"
            return false
        }

        // 权限策略（与用户设定一致）：
        //   系统关键路径（越狱根、根目录、App 安装包）→ 强制只读，不接受读写请求
        //   其余位置（App 数据容器、App Group）      → 默认读写，AI 可读改写
        var perm = permission ?? (loc.allowsWrite ? .readWrite : .readOnly)
        if !loc.allowsWrite { perm = .readOnly }

        let rc = ISHKernel.shared.bindMountPath(loc.guestPath,
                                                toHostPath: hostPath,
                                                readOnly: perm == .readOnly)
        guard rc == 0 else {
            lastError = "挂载失败（err=\(rc)）：\(hostPath)"
            return false
        }

        mounted[loc.key] = perm
        return true
    }

    /// 切换已挂载位置的权限
    @discardableResult
    func setPermission(_ loc: HostLocation, _ permission: HostMountPermission) -> Bool {
        guard isMounted(loc) else { return false }
        guard loc.allowsWrite || permission == .readOnly else {
            lastError = "\(loc.title) 属于系统路径，仅支持只读"
            return false
        }
        return ensureMounted(loc, permission: permission)
    }

    func unmount(_ loc: HostLocation) {
        _ = ISHKernel.shared.bindUnmountPath(loc.guestPath)
        mounted.removeValue(forKey: loc.key)
        approvedKeys.remove(loc.key)
        persistApproved()
    }

    func unmountAll() {
        for key in mounted.keys {
            let guest = "/var/minis/host/\(key)"
            _ = ISHKernel.shared.bindUnmountPath(guest)
        }
        mounted.removeAll()
    }

    // MARK: 描述

    /// 给 AI 的可用位置说明（只读，不触发挂载）
    func availableDescription() -> String {
        var lines: [String] = []
        lines.append("当前宿主访问级别：\(level.title)")
        lines.append("")
        for loc in HostLocation.builtins {
            let state: String
            if level == .off {
                state = "不可用（已关闭）"
            } else if let perm = mounted[loc.key] {
                state = "已挂载（\(perm.title)，\(perm == .readWrite ? "可读改写" : "仅可读")）→ \(loc.guestPath)"
            } else if isAllowed(loc) {
                state = "已授权，可挂载 → \(loc.guestPath)"
            } else {
                state = "未授权（调用 host_access action=request 可请求）"
            }
            lines.append("• \(loc.key) — \(loc.title)：\(state)")
        }
        return lines.joined(separator: "\n")
    }
}
