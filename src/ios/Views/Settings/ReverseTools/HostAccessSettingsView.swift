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
    /// 自定义路径输入
    @State private var customPathDraft: String = ""
    /// 一键授权的结果提示
    @State private var grantAllMessage: String?

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

            // MARK: 全盘访问（一个开关管全部）
            Section {
                Toggle(isOn: Binding(
                    get: { manager.isFullDiskEnabled },
                    set: { manager.setFullDisk($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全盘访问（读写）").font(.body.weight(.medium))
                        Text("开启后 AI 可读写手机上任意路径，包含越狱目录与其它 App 容器。每次修改是否弹窗确认，由下面的「写保护」决定。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(manager.level == .off)
            } header: {
                Text("全盘访问")
            } footer: {
                Text("这是最省事的用法：开这一个就够。想精确控制时，关掉它改用下面的逐项授权。")
            }

            // MARK: 一键授权
            Section {
                Button {
                    let r = manager.grantAll(permission: .readWrite)
                    if r.skipped.isEmpty {
                        grantAllMessage = "已授权 \(r.granted) 项（读写）"
                    } else {
                        grantAllMessage = "已授权 \(r.granted) 项，跳过 \(r.skipped.count) 项：\n"
                            + r.skipped.joined(separator: "\n")
                    }
                } label: {
                    Label("一键授权全部位置（读写）", systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.level == .off)

                Button(role: .destructive) {
                    manager.revokeAll()
                    grantAllMessage = nil
                } label: {
                    Label("撤销全部", systemImage: "xmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let msg = grantAllMessage {
                    Text(msg)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("一键授权")
            } footer: {
                Text("一次性把下面所有位置（含自定义）设为读写。不存在的路径会自动跳过，不影响其它项。总开关为「全部关闭」时不可用。")
            }

            // MARK: 自定义路径
            Section {
                HStack(spacing: 8) {
                    TextField("/var/mobile/... 任意宿主路径", text: $customPathDraft)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let p = customPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !p.isEmpty else { return }
                        _ = HostAccessManager.addCustomLocation(path: p)
                        customPathDraft = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(customPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ForEach(HostAccessManager.customLocations()) { loc in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.title).font(.body)
                            Text(loc.hostPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            manager.revoke(loc)
                            HostAccessManager.removeCustomLocation(key: loc.key)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("自定义路径")
            } footer: {
                Text("填任意宿主绝对路径并添加，它会和内置位置一样出现在下面的列表里，可单独设只读或读写。适合 Theos、SDK、特定 App 容器这类固定位置。")
            }

            // MARK: 逐项开关
            Section {
                ForEach(HostAccessManager.allLocations) { loc in
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
                    ForEach(HostAccessManager.allLocations.filter { manager.mounted[$0.key] != nil }) { loc in
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
