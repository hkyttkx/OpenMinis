//
//  ContextLimitSettings.swift
//  KyTuT
//
//  上下文窗口上限设置。
//
//  三层优先级（高 → 低）：
//    1. 会话级覆盖   SessionContextOverrides（按 sessionId 存）
//    2. 模型组设置   ModelGroup.contextLimitTokens（既有机制）
//    3. 模型原生窗口 LLMModel.contextWindowTokens
//
//  每层都支持「不限制」：值为 0 表示不限制（即使用模型原生窗口，
//  且关闭自动压缩与 offload 的阈值判定，把决定权完全交给模型/服务端）。
//

import Foundation
import SwiftUI

// MARK: - 限制模式

enum ContextLimitMode: String, CaseIterable, Identifiable {
    /// 跟随下层（模型组 / 模型原生）
    case inherit
    /// 自定义上限
    case custom
    /// 不限制 —— 不设上限，也不触发自动压缩
    case unlimited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit:   return "跟随默认"
        case .custom:    return "自定义上限"
        case .unlimited: return "不限制"
        }
    }

    var detail: String {
        switch self {
        case .inherit:   return "使用模型组或模型自身设定的窗口大小"
        case .custom:    return "手动指定本会话可用的上下文上限"
        case .unlimited: return "不设上限，也不会自动压缩历史"
        }
    }
}

// MARK: - 会话级覆盖存储

enum SessionContextOverrides {

    private static let key = "context.sessionOverrides"

    /// 会话覆盖：[sessionId: tokens]，tokens = 0 表示不限制
    private static var all: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func mode(for sessionId: String) -> ContextLimitMode {
        guard let v = all[sessionId] else { return .inherit }
        return v == 0 ? .unlimited : .custom
    }

    static func tokens(for sessionId: String) -> Int? {
        guard let v = all[sessionId], v > 0 else { return nil }
        return v
    }

    static func isUnlimited(_ sessionId: String) -> Bool {
        all[sessionId] == 0
    }

    static func set(_ mode: ContextLimitMode, tokens: Int? = nil, for sessionId: String) {
        var m = all
        switch mode {
        case .inherit:
            m.removeValue(forKey: sessionId)
        case .unlimited:
            m[sessionId] = 0
        case .custom:
            let t = max(tokens ?? 0, 1)
            m[sessionId] = t
        }
        all = m
    }

    static func clear(for sessionId: String) {
        var m = all
        m.removeValue(forKey: sessionId)
        all = m
    }
}

// MARK: - 全局默认

enum GlobalContextDefaults {

    private static let modeKey = "context.globalMode"
    private static let tokensKey = "context.globalTokens"

    static var mode: ContextLimitMode {
        get {
            let raw = UserDefaults.standard.string(forKey: modeKey) ?? ContextLimitMode.inherit.rawValue
            return ContextLimitMode(rawValue: raw) ?? .inherit
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// 全局自定义上限，默认 128K
    static var tokens: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: tokensKey)
            return v > 0 ? v : 128_000
        }
        set { UserDefaults.standard.set(max(newValue, 1), forKey: tokensKey) }
    }
}

// MARK: - 常用档位

enum ContextLimitPresets {
    /// 预设档位（tokens）
    static let values: [Int] = [16_000, 32_000, 64_000, 128_000, 200_000, 400_000, 1_000_000]

    static func label(_ v: Int) -> String {
        if v >= 1_000_000 { return "\(v / 1_000_000)M" }
        return "\(v / 1000)K"
    }
}

// MARK: - 上下文设置页

struct ContextLimitSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// 为 nil 时编辑「全局默认」，否则编辑指定会话
    let sessionId: String?
    let sessionTitle: String?

    @State private var mode: ContextLimitMode = .inherit
    @State private var tokens: Int = 128_000

    init(sessionId: String? = nil, sessionTitle: String? = nil) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
    }

    private var isGlobal: Bool { sessionId == nil }

    var body: some View {
        List {
            Section {
                ForEach(ContextLimitMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: m == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(m == mode ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.title).font(.body.weight(.medium))
                                Text(m.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("模式")
            } footer: {
                if isGlobal {
                    Text("这是全局默认。单个会话可在聊天页单独覆盖。")
                } else {
                    Text("仅对「\(sessionTitle ?? "当前会话")」生效，不影响其他会话。")
                }
            }

            if mode == .custom {
                Section {
                    HStack {
                        Text("上限")
                        Spacer()
                        Text(ContextLimitPresets.label(tokens))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: Binding(
                        get: { Double(ContextLimitPresets.values.firstIndex(of: tokens) ?? 3) },
                        set: { tokens = ContextLimitPresets.values[max(0, min(Int($0.rounded()),
                                                                        ContextLimitPresets.values.count - 1))] }
                    ), in: 0...Double(ContextLimitPresets.values.count - 1), step: 1)

                    // 也允许手填
                    HStack {
                        Text("自定义数值")
                        Spacer()
                        TextField("128000", value: $tokens, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("上限大小")
                } footer: {
                    Text("实际可用窗口取「本设置」与「模型原生窗口」的较小值 —— 设置高于模型能力不会真的突破模型上限。")
                }
            }

            if mode == .unlimited {
                Section {
                    Label("不会自动压缩历史", systemImage: "infinity")
                        .font(.caption)
                    Text("关闭自动压缩后，若实际超出模型窗口，服务端可能直接报错或截断。建议对窗口足够大的模型使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("说明")
                }
            }
        }
        .navigationTitle(isGlobal ? "上下文默认" : "本会话上下文")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: mode) { _ in save() }
        .onChange(of: tokens) { _ in save() }
        .toolbar {
            if !isGlobal {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清除") {
                        SessionContextOverrides.clear(for: sessionId ?? "")
                        dismiss()
                    }
                }
            }
        }
    }

    private func load() {
        if let sid = sessionId {
            mode = SessionContextOverrides.mode(for: sid)
            tokens = SessionContextOverrides.tokens(for: sid) ?? GlobalContextDefaults.tokens
        } else {
            mode = GlobalContextDefaults.mode
            tokens = GlobalContextDefaults.tokens
        }
    }

    private func save() {
        if let sid = sessionId {
            SessionContextOverrides.set(mode, tokens: tokens, for: sid)
        } else {
            GlobalContextDefaults.mode = mode
            GlobalContextDefaults.tokens = tokens
        }
    }
}
