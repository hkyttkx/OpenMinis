//
//  HostAccessSettingsView.swift
//  KyTuT
//
//  「设置 → 开发者 → 宿主访问」
//
//  完全可控的宿主文件访问：总开关 + 逐项开关 + 逐项权限 + 写确认。
//  直读模式，不涉及 fakefs 挂载。
//

import SwiftUI

struct HostAccessSettingsView: View {
    @ObservedObject private var manager = HostAccessManager.shared

    var body: some View {
        List {
            // MARK: 总开关
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
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("总开关")
            } footer: {
                Text("「全部关闭」会立即撤销所有已授权位置。切到该档后 AI 无法读取任何宿主文件。")
            }

            // MARK: 逐项开关
            Section {
                ForEach(HostLocation.builtins) { loc in
                    HostLocationRow(location: loc, manager: manager)
                }
            } header: {
                Text("位置权限")
            } footer: {
                Text("逐项开启。系统路径（/、越狱根、App 安装包）强制只读，无法切换为读写。开启后 AI 可经 host_file 工具直接读取。")
            }

            // MARK: 写保护
            Section {
                Toggle(isOn: $manager.confirmWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("写操作需确认")
                        Text("AI 每次写入或删除前弹窗确认")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("写保护")
            } footer: {
                Text("开启后 AI 的写/删操作都会先询问你。系统路径无论如何都不可写。")
            }

            // MARK: 状态
            Section {
                if manager.mounted.isEmpty {
                    Text("当前没有已授权的位置")
                        .font(.caption).foregroundStyle(.secondary)
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
                                Text(manager.resolvedPath(loc))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        manager.revokeAll()
                    } label: {
                        Label("撤销全部授权", systemImage: "eject")
                    }
                }

                if let err = manager.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("当前状态")
            }

            // MARK: 说明
            Section {
                Label("采用直读模式：App 直接以自身权限访问宿主路径，不做系统级挂载。因此不会出现挂载失败，且卸载重装后不残留挂载状态。",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("说明")
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

    private var isOn: Bool { manager.isMounted(location) }
    private var perm: HostMountPermission? { manager.mounted[location.key] }
    private var disabled: Bool { manager.level == .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title).font(.body.weight(.medium))
                    Text(location.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { on in
                        if on { _ = manager.grant(location) }
                        else { manager.revoke(location) }
                    }
                ))
                .labelsHidden()
                .disabled(disabled)
            }

            Text(manager.resolvedPath(location))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)

            if isOn {
                if location.allowsWrite {
                    Picker("权限", selection: Binding(
                        get: { perm ?? .readOnly },
                        set: { manager.setPermission(location, $0) }
                    )) {
                        ForEach(HostMountPermission.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Label("只读（系统路径）", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
