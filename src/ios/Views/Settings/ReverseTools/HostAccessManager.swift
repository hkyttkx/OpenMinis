//
//  HostAccessManager.swift
//  KyTuT
//
//  宿主文件系统访问控制。
//
//  背景（为什么需要这个）：
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

// MARK: - 常用宿主位置

struct HostLocation: Identifiable, Hashable {
    var id: String { key }
    let key: String          // 短名，AI 用这个名字引用
    let hostPath: String     // 宿主真实路径
    let title: String
    let detail: String

    var guestPath: String { "/var/minis/host/\(key)" }

    static let builtins: [HostLocation] = [
        HostLocation(key: "apps",
                     hostPath: "/var/containers/Bundle/Application",
                     title: "已安装 App",
                     detail: "所有 App 的安装包，含主二进制与 Frameworks"),
        HostLocation(key: "containers",
                     hostPath: "/var/mobile/Containers/Data/Application",
                     title: "App 数据容器",
                     detail: "各 App 的 Documents / Library / tmp"),
        HostLocation(key: "shared",
                     hostPath: "/var/mobile/Containers/Shared/AppGroup",
                     title: "App 共享容器",
                     detail: "App Group 共享目录"),
        HostLocation(key: "jb",
                     hostPath: "/var/jb",
                     title: "越狱根",
                     detail: "越狱环境文件（roothide 下可能是随机路径）"),
        HostLocation(key: "root",
                     hostPath: "/",
                     title: "整个文件系统",
                     detail: "根目录，权限最高，仅建议临时使用"),
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

    /// 已成功挂载的位置
    @Published private(set) var mounted: [HostLocation] = []

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
        // 切到全自动：把默认放行集合补上；切到关闭：清空本次批准
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

    /// 是否可以无条件访问该位置
    func isAllowed(_ loc: HostLocation) -> Bool {
        switch level {
        case .off:
            return false
        case .auto:
            // 全自动：内置位置放行；root 仍需单独批准
            return Self.autoDefaultKeys.contains(loc.key) || approvedKeys.contains(loc.key)
        case .ask:
            return approvedKeys.contains(loc.key)
        }
    }

    /// AI 请求访问某位置。返回 true 表示已可直接使用（无需 UI 交互）。
    /// 返回 false 表示已挂起待用户确认，UI 会弹出确认框。
    func requestAccess(_ loc: HostLocation, requester: String) -> Bool {
        if isAllowed(loc) {
            ensureMounted(loc)
            return true
        }
        if level == .off {
            return false
        }
        // ask 模式（或 auto 模式下访问未放行的 root）：挂起等待用户确认
        pendingRequest = HostMountRequest(location: loc, requester: requester)
        return false
    }

    /// 用户批准
    func approve(_ request: HostMountRequest) {
        approvedKeys.insert(request.location.key)
        persistApproved()
        ensureMounted(request.location)
        pendingRequest = nil
    }

    /// 用户拒绝
    func deny() {
        pendingRequest = nil
    }

    // MARK: 实际挂载

    /// 执行 bind mount（幂等）
    @discardableResult
    func ensureMounted(_ loc: HostLocation) -> Bool {
        if mounted.contains(where: { $0.key == loc.key }) { return true }

        // 越狱根是随机路径，需动态解析
        var hostPath = loc.hostPath
        if loc.key == "jb" {
            if let real = JailbreakInjector.resolveJailbreakRoot(), !real.isEmpty {
                hostPath = real
            } else if !FileManager.default.fileExists(atPath: hostPath) {
                // 找不到越狱根，跳过（不算失败，只是不可用）
                return false
            }
        }

        guard FileManager.default.fileExists(atPath: hostPath) else {
            return false
        }

        let rc = ISHKernel.shared.bindMountPath(loc.guestPath, toHostPath: hostPath, readOnly: true)
        guard rc == 0 else { return false }

        mounted.append(loc)
        return true
    }

    /// 卸载单个
    func unmount(_ loc: HostLocation) {
        _ = ISHKernel.shared.bindUnmountPath(loc.guestPath)
        mounted.removeAll { $0.key == loc.key }
        approvedKeys.remove(loc.key)
        persistApproved()
    }

    /// 全部卸载
    func unmountAll() {
        for loc in mounted {
            _ = ISHKernel.shared.bindUnmountPath(loc.guestPath)
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
            } else if mounted.contains(where: { $0.key == loc.key }) {
                state = "已挂载 → \(loc.guestPath)"
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
