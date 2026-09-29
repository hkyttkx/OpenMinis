//
//  InjectPanelView.swift
//  KyTuT
//
//  目标 App 管理 → App 详情页的「动态注入」面板。
//  流程：选 dylib → 选注入模式 → 执行 → 查看结果与日志。
//

import SwiftUI

struct InjectPanelView: View {
    let app: InstalledAppInfo

    @State private var selectedDylibPath: String = ""
    @State private var mode: DynamicInjectMode = .strict
    @State private var running = false
    @State private var progressText = ""

    @State private var resultSuccess: Bool?
    @State private var resultMessage = ""

    @State private var showLog = false
    @State private var showPicker = false
    @State private var availableDylibs: [String] = []

    var body: some View {
        List {
            // MARK: 注入内容
            Section {
                if selectedDylibPath.isEmpty {
                    Button {
                        showPicker = true
                    } label: {
                        Label("选择要注入的动态库", systemImage: "plus.circle")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text((selectedDylibPath as NSString).lastPathComponent)
                                .font(.body.weight(.medium))
                            Spacer()
                            Button("更换") { showPicker = true }
                                .font(.caption)
                        }
                        Text(selectedDylibPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }

                if !availableDylibs.isEmpty {
                    Menu {
                        ForEach(availableDylibs, id: \.self) { p in
                            Button((p as NSString).lastPathComponent) {
                                selectedDylibPath = p
                            }
                        }
                    } label: {
                        Label("从已发现列表选择", systemImage: "list.bullet")
                    }
                }
            } header: {
                Text("注入内容")
            } footer: {
                Text("需要 .dylib 文件。可先用 AI 分析目标 App 并生成 Hook 配置，编译成动态库后在此注入。")
            }

            // MARK: 注入模式
            Section {
                ForEach(DynamicInjectMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: m == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(m == mode ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: m.systemImage)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(m.title).font(.body.weight(.medium))
                                }
                                Text(m.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(running)
                }
            } header: {
                Text("注入模式")
            } footer: {
                Text("两种模式的注入流程与内核交互完全一致，区别只在 dylib 的临时落点。严格复刻兼容性最好，无痕模式全程不触碰目标 App 目录。")
            }

            // MARK: 执行
            Section {
                Button {
                    startInject()
                } label: {
                    HStack {
                        Spacer()
                        if running {
                            ProgressView().scaleEffect(0.85)
                            Text(progressText.isEmpty ? "正在注入…" : progressText)
                                .font(.footnote)
                        } else {
                            Image(systemName: "bolt.fill")
                            Text("开始动态注入")
                        }
                        Spacer()
                    }
                }
                .disabled(running || selectedDylibPath.isEmpty)

                if let ok = resultSuccess {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(ok ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ok ? "注入成功" : "注入失败")
                                .font(.body.weight(.medium))
                            if !resultMessage.isEmpty {
                                Text(resultMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !ok {
                                Text("若目标 App 已闪退，崩溃报告已记录到注入日志。")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Button {
                    showLog = true
                } label: {
                    Label("查看注入日志", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("执行")
            } footer: {
                Text("注入为运行时行为，目标 App 重启后失效。请确保目标 App 已启动。")
            }

            // MARK: 环境
            Section {
                Text(JailbreakInjector.environmentSummary())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("注入环境")
            }
        }
        .sheet(isPresented: $showLog) { InjectLogViewer() }
        .sheet(isPresented: $showPicker) {
            DylibPathPicker(selected: $selectedDylibPath)
        }
        .onAppear { scanDylibs() }
    }

    // MARK: - 动作

    private func scanDylibs() {
        var found: [String] = []
        let fm = FileManager.default

        let dirs: [URL] = [
            app.bundleURL.appendingPathComponent("Frameworks"),
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dylibs"),
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DynamicLibraries"),
        ]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            found.append(contentsOf: items.filter { $0.pathExtension == "dylib" }.map(\.path))
        }
        if let tpl = Bundle.main.path(forResource: "FuckEngine", ofType: "dylib") {
            found.append(tpl)
        }
        availableDylibs = Array(Set(found)).sorted()
    }

    private func startInject() {
        guard !selectedDylibPath.isEmpty else { return }
        running = true
        resultSuccess = nil
        resultMessage = ""
        progressText = "准备中…"

        JailbreakInjector.inject(
            bundleID: app.bundleId,
            bundleURL: app.bundleURL,
            executableName: app.mainExecutableURL?.lastPathComponent,
            dylibPath: selectedDylibPath,
            mode: mode,
            progress: { step in
                progressText = step
            },
            completion: { outcome in
                running = false
                resultSuccess = outcome.success
                resultMessage = outcome.message
                progressText = ""
            }
        )
    }
}

// MARK: - dylib 路径选择

struct DylibPathPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: String

    @State private var manual = ""

    var body: some View {
        NavigationStack {
            List {
                Section("手动输入路径") {
                    TextField("/var/containers/Bundle/Application/…/xxx.dylib", text: $manual)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("使用该路径") {
                        let p = manual.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !p.isEmpty else { return }
                        selected = p
                        dismiss()
                    }
                    .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    Text("可先在详情页「浏览 Bundle / 数据容器」找到 .dylib，复制其路径粘贴到此处。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("选择动态库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
