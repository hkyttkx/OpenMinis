//
//  HostAccessSettingsView.swift
//  KyTuT
//
//  「设置 → 挂载外部文件夹 → 宿主访问」
//
//  三档访问级别 + 内置宿主位置开关 + 当前挂载状态。
//  与既有的「挂载外部文件夹」正交：那边挂的是「文件」App 可见的目录
//  （security-scoped bookmark），这里挂的是越狱/巨魔环境下可直接读取的
//  系统路径（App 包、数据容器、越狱根等）。
//

import SwiftUI

struct HostAccessSettingsView: View {
    @StateObject private var manager = HostAccessManager.shared
    @State private var refreshTick = 0

    var body: some View {
        List {
            // MARK: 访问级别
            Section {
                ForEach(HostAccessLevel.allCases) { lv in
                    Button {
                        manager.setLevel(lv)
                        refreshTick += 1
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: lv == manager.level ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(lv == manager.level ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: lv.systemImage)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(lv.tint)
                                    Text(lv.title).font(.body.weight(.medium))
                                }
                                Text(lv.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("访问级别")
            } footer: {
                Text("控制 AI 在静态分析时能否直接读取手机上的原始文件。关闭后 AI 只能分析已复制到沙盒的文件；询问模式会在 AI 首次访问某个位置时弹窗确认。")
            }

            // MARK: 内置位置
            Section {
                ForEach(HostLocation.builtins) { loc in
                    HostLocationRow(location: loc, manager: manager, refreshTick: $refreshTick)
                }
            } header: {
                Text("可用位置")
            } footer: {
                Text("挂载后的位置在沙盒内以 /var/minis/host/<短名> 访问。全部为只读挂载，AI 无法修改宿主文件。")
            }

            // MARK: 状态
            Section {
                if manager.mounted.isEmpty {
                    Text("当前没有已挂载的宿主位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.mounted) { loc in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.title).font(.body)
                                Text(loc.guestPath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        manager.unmountAll()
                        refreshTick += 1
                    } label: {
                        Label("全部卸载", systemImage: "eject")
                    }
                }
            } header: {
                Text("挂载状态")
            } footer: {
                Text("卸载后 AI 立即失去对应位置的访问能力。App 重启会清空所有挂载。")
            }
        }
        .navigationTitle("宿主访问")
        .navigationBarTitleDisplayMode(.inline)
        .id(refreshTick)   // 便于强刷状态
    }
}

// MARK: - 位置行

private struct HostLocationRow: View {
    let location: HostLocation
    @ObservedObject var manager: HostAccessManager
    @Binding var refreshTick: Int

    private var isMounted: Bool { manager.mounted.contains { $0.key == location.key } }
    private var isAllowed: Bool { manager.isAllowed(location) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title).font(.body.weight(.medium))
                    Text(location.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isMounted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }

            Text(location.hostPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                if isMounted {
                    Button("卸载") {
                        manager.unmount(location)
                        refreshTick += 1
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                } else {
                    Button(isAllowed ? "挂载" : "授权并挂载") {
                        manager.approve(HostMountRequest(location: location, requester: "手动"))
                        _ = manager.ensureMounted(location)
                        refreshTick += 1
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(manager.level == .off)

                    if manager.level == .off {
                        Text("访问已关闭")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
