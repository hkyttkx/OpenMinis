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
    /// 越狱根手填输入框（留空则自动探测）
    @State private var jbrootDraft: String = ""

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
                Text("逐项开启，每项可单独设为只读或读写，默认只读。开启后 AI 可经 host_file 工具访问。注意：对「整个文件系统」开启读写时，AI 的每次修改都会弹窗请你确认。")
            }

            // MARK: 越狱根
            //
            // roothide 的越狱根是随机目录名（形如 `.jbroot-A1B99E8FE8B71244`），
            // 自动探测不一定命中，所以允许手填；留空时回落到自动探测。
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义越狱根")
                        .font(.body.weight(.medium))
                    TextField("留空则自动探测，例如 /var/containers/Bundle/Application/.jbroot-XXXXXXXX",
                              text: $jbrootDraft)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { manager.customJailbreakRoot = jbrootDraft }

                    HStack(spacing: 10) {
                        Button {
                            manager.customJailbreakRoot = jbrootDraft
                        } label: {
                            Label("保存", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            if let d = manager.detectedJailbreakRoot {
                                jbrootDraft = d
                                manager.customJailbreakRoot = d
                            }
                        } label: {
                            Label("自动探测", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(manager.detectedJailbreakRoot == nil)

                        Button(role: .destructive) {
                            jbrootDraft = ""
                            manager.customJailbreakRoot = ""
                        } label: {
                            Label("清除", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("越狱根")
            } footer: {
                Text("roothide 越狱根是随机目录，默认的 /var/jb 通常不存在。这里填真实路径后，「越狱根」位置与动态注入都会用它。")
            }

            // MARK: 写保护
            Section {
                Toggle(isOn: $manager.confirmWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("整盘读写需确认")
                        Text("AI 修改「整个文件系统」范围内的文件前弹窗确认")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("写保护")
            } footer: {
                Text("仅对「整个文件系统」这一档生效。普通目录（App 容器、共享目录、媒体目录）的读写不会打扰你。")
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
        .onAppear { jbrootDraft = manager.customJailbreakRoot }
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
                Picker("权限", selection: Binding(
                    get: { perm ?? .readOnly },
                    set: { manager.setPermission(location, $0) }
                )) {
                    ForEach(HostMountPermission.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                if location.requiresWriteConfirmation {
                    Label("读写模式下，AI 每次改动都会弹窗请你确认", systemImage: "exclamationmark.shield")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
