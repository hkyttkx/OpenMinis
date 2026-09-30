//
//  WriteConfirmationCenter.swift
//  KyTuT
//
//  写操作确认中心。
//
//  需求：AI 对宿主文件的任何修改（写入 / 删除 / 覆盖）都必须弹窗让用户确认。
//
//  机制：
//    AI 工具调用 write/rm 时先在此登记一个待确认请求并挂起（await），
//    UI 弹出确认框；用户允许或拒绝后 resume，工具拿到结果继续或中止。
//    超时（默认 60s）视为拒绝，避免工具永久挂起。
//
//  设计要点：
//    - 用 withCheckedContinuation 挂起调用方，不阻塞主线程
//    - 同一时刻只允许一个待确认请求，避免弹窗叠罗汉
//    - 记录最近确认历史，便于审计「AI 改了什么」
//

import Foundation
import SwiftUI

// MARK: - 待确认的写操作

struct PendingWriteRequest: Identifiable {
    let id = UUID()
    /// 操作类型：write / delete / mkdir 等
    let operation: String
    /// 目标路径
    let path: String
    /// 若为写入，内容大小；若为删除，nil
    let contentSize: Int?
    /// 内容预览（前若干字符）
    let preview: String?
    /// 是否命中系统关键路径（高风险提示）
    let isSystemPath: Bool
    /// 发起者说明（AI 为什么改）
    let reason: String?
}

// MARK: - 确认结果

enum WriteDecision {
    case approved
    case denied
    case timedOut
}

// MARK: - 中心

@MainActor
final class WriteConfirmationCenter: ObservableObject {

    static let shared = WriteConfirmationCenter()

    /// UI 监听此属性弹窗
    @Published var pending: PendingWriteRequest?

    /// 历史（最近 100 条）
    @Published private(set) var history: [(date: Date, op: String, path: String, approved: Bool)] = []

    /// 超时秒数
    @Published var timeoutSeconds: Double = 60

    private var continuation: CheckedContinuation<WriteDecision, Never>?
    private var timer: Timer?

    private init() {}

    // MARK: 请求确认

    /// 挂起等待用户确认。返回是否允许。
    func requestApproval(operation: String,
                         path: String,
                         contentSize: Int? = nil,
                         preview: String? = nil,
                         reason: String? = nil) async -> WriteDecision {

        // 是否需要确认由 HostAccessManager 按位置判定 —— 只有「整个文件系统」
        // 这类全盘权限才弹窗；App 目录等普通位置直接放行，不打扰。
        if !HostAccessManager.shared.needsWriteConfirmation(for: path) {
            return .approved
        }

        // 已有待确认请求 → 排队等它结束（简单策略：拒绝并提示重试）
        if pending != nil {
            log(op: operation, path: path, approved: false)
            return .denied
        }

        let req = PendingWriteRequest(
            operation: operation,
            path: path,
            contentSize: contentSize,
            preview: preview,
            isSystemPath: HostFileAccess.isSystemCritical(path),
            reason: reason
        )
        pending = req

        let decision = await withCheckedContinuation { (c: CheckedContinuation<WriteDecision, Never>) in
            self.continuation = c
            // 超时保护
            self.timer = Timer.scheduledTimer(withTimeInterval: self.timeoutSeconds, repeats: false) { _ in
                Task { @MainActor in
                    self.finish(.timedOut)
                }
            }
        }

        log(op: operation, path: path, approved: decision == .approved)
        return decision
    }

    /// 用户点击允许 / 拒绝
    func respond(_ approved: Bool) {
        finish(approved ? .approved : .denied)
    }

    private func finish(_ decision: WriteDecision) {
        timer?.invalidate()
        timer = nil
        pending = nil
        // 清空可能已失效的 continuation
        if let c = continuation {
            continuation = nil
            c.resume(returning: decision)
        }
    }

    private func log(op: String, path: String, approved: Bool) {
        history.append((Date(), op, path, approved))
        if history.count > 100 { history.removeFirst(history.count - 100) }
    }

    /// 供 AI 工具查询：某次写操作是否已获批准
    func describeHistory(limit: Int = 20) -> String {
        guard !history.isEmpty else { return "（无写操作记录）" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return history.suffix(limit).map {
            "\(f.string(from: $0.date))  \($0.approved ? "✅ 允许" : "❌ 拒绝")  \($0.op)  \($0.path)"
        }.joined(separator: "\n")
    }
}
