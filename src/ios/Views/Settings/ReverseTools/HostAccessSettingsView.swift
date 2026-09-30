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
    @ObservedObject private var manager = HostAccessManager.shared

    var body: some View {
        List {
            // MARK: 访问级别
            Section {
                ForEach(HostAccessLevel.allCases) { lv in
                    Button {
                        manager.setLevel(lv)
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
                    HostLocationRow(location: loc, manager: manager)
                }
            } header: {
                Text("可用位置")
            } footer: {
                Text("挂载后的位置在沙盒内以 /var/minis/host/<短名> 访问。系统路径强制只读；App 数据容器与 App Group 默认读写，可随时切换。")
            }

            // MARK: 状态
            Section {
                if manager.mounted.isEmpty {
                    Text("当前没有已挂载的宿主位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(HostLocation.builtins.filter { manager.mounted[$0.key] != nil }) { loc in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(loc.title).font(.body)
                                    Text(manager.mounted[loc.key]?.title ?? "")
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(.quaternary))
                                }
                                Text(loc.guestPath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        manager.unmountAll()
                    } label: {
                        Label("全部卸载", systemImage: "eject")
                    }
                }

                if let err = manager.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("挂载状态")
            } footer: {
                Text("卸载后 AI 立即失去对应位置的访问能力。App 重启会清空所有挂载。")
            }
        }
        .navigationTitle("宿主访问")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 位置行

private struct HostLocationRow: View {
    let location: HostLocation
    @ObservedObject var manager: HostAccessManager

    private var isMounted: Bool { manager.isMounted(location) }
    private var isAllowed: Bool { manager.isAllowed(location) }
    private var currentPerm: HostMountPermission? { manager.mounted[location.key] }

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
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)

                    // 读写切换：仅对允许写的位置显示
                    if location.allowsWrite {
                        Menu {
                            ForEach(HostMountPermission.allCases) { p in
                                Button {
                                    _ = manager.setPermission(location, p)
                                } label: {
                                    if currentPerm == p {
                                        Label(p.title, systemImage: "checkmark")
                                    } else {
                                        Text(p.title)
                                    }
                                }
                            }
                        } label: {
                            Label(currentPerm?.title ?? "只读", systemImage: "lock.open")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Label("只读（系统路径）", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(isAllowed ? "挂载" : "授权并挂载") {
                        manager.approve(HostMountRequest(location: location, requester: "手动"))
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
