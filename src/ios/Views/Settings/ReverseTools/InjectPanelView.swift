//
//  InjectPanelView.swift
//  KyTuT
//
//  目标 App 管理 → App 详情页的「动态注入」面板。
//  流程：选 dylib（文件导入 / 历史记录 / AI 生成）→ 选注入模式 → 执行 → 查看结果与日志。
//

import SwiftUI
import UniformTypeIdentifiers

struct InjectPanelView: View {
    let app: InstalledAppInfo

    @State private var selectedDylibPath: String = ""
    @State private var mode: DynamicInjectMode = .clean
    @State private var running = false
    @State private var progressText = ""

    @State private var resultSuccess: Bool?
    @State private var resultMessage = ""

    @State private var showLog = false
    @State private var showImporter = false
    @State private var showAIHook = false
    @State private var importError: String?
    @State private var availableDylibs: [String] = []

    let onRequestAIHook: (() -> Void)?

    init(app: InstalledAppInfo, onRequestAIHook: (() -> Void)? = nil) {
        self.app = app
        self.onRequestAIHook = onRequestAIHook
    }

    var body: some View {
        List {
            // MARK: 注入内容
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入动态库", systemImage: "square.and.arrow.down")
                }

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !availableDylibs.isEmpty {
                    ForEach(availableDylibs, id: \.self) { p in
                        Button {
                            selectedDylibPath = p
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedDylibPath == p
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedDylibPath == p
                                                     ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((p as NSString).lastPathComponent)
                                        .foregroundStyle(.primary)
                                    Text(byteSize(p))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("注入内容")
            } footer: {
                if selectedDylibPath.isEmpty {
                    Text("从「文件」App 选择 .dylib，导入后保存在本机动态库目录。")
                } else {
                    Text("已选择：\((selectedDylibPath as NSString).lastPathComponent)")
                }
            }

            // MARK: AI 生成
            Section {
                Button {
                    showAIHook = true
                } label: {
                    Label("让 AI 生成并编译 Hook", systemImage: "sparkles")
                }
            } footer: {
                Text("AI 生成 Hook 源码后在本机 Alpine 沙盒里用 clang 编译成动态库，编译成功会询问是否立即注入。")
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
                Text("两种模式的注入流程与内核交互完全一致，区别只在 dylib 的临时落点。")
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
                                Text("详细过程与失败原因见注入日志。")
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
        .sheet(isPresented: $showAIHook) {
            AIHookSheet(app: app) { dylibPath in
                selectedDylibPath = dylibPath
                reloadDylibs()
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.dylibTypes,
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .onAppear { reloadDylibs() }
    }

    // MARK: - dylib 类型

    static var dylibTypes: [UTType] {
        var types: [UTType] = []
        if let t = UTType(filenameExtension: "dylib") { types.append(t) }
        types.append(.data)
        return types
    }

    // MARK: - 动作

    private func reloadDylibs() {
        var found = JailbreakInjector.listImportedDylibs()

        // 目标 App 的 Frameworks 目录里已有的动态库
        let fw = app.bundleURL.appendingPathComponent("Frameworks")
        if let items = try? FileManager.default.contentsOfDirectory(at: fw, includingPropertiesForKeys: nil) {
            found.append(contentsOf: items.filter { $0.pathExtension == "dylib" }.map(\.path))
        }
        // 内置 Hook 引擎
        if let tpl = Bundle.main.path(forResource: "FuckEngine", ofType: "dylib") {
            found.append(tpl)
        }
        availableDylibs = Array(Set(found)).sorted()

        if selectedDylibPath.isEmpty {
            selectedDylibPath = availableDylibs.first ?? ""
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let path = try JailbreakInjector.importDylib(from: url)
                selectedDylibPath = path
                reloadDylibs()
            } catch {
                importError = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            importError = "选择失败：\(error.localizedDescription)"
        }
    }

    private func byteSize(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
            progress: { step in progressText = step },
            completion: { outcome in
                running = false
                resultSuccess = outcome.success
                resultMessage = outcome.message
                progressText = ""
            }
        )
    }
}
