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

    /// 多选注入：一次可勾选多个 dylib，注入时按列表顺序逐个执行。
    @State private var selectedDylibPaths: Set<String> = []
    /// 待删除的 dylib（确认弹窗用）
    @State private var pendingDeletePath: String? = nil
    @State private var showDeleteConfirm = false
    @State private var mode: DynamicInjectMode = .clean
    @State private var running = false
    @State private var progressText = ""

    @State private var resultSuccess: Bool?
    @State private var resultMessage = ""

    @State private var showLog = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var availableDylibs: [String] = []
    @State private var aiHintShown = false

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
                            toggleSelection(p)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedDylibPaths.contains(p)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedDylibPaths.contains(p)
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pendingDeletePath = p
                                showDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }

                    if !selectedDylibPaths.isEmpty {
                        Button {
                            selectedDylibPaths.removeAll()
                        } label: {
                            Label("取消已选的 \(selectedDylibPaths.count) 个",
                                  systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("注入内容")
            } footer: {
                if selectedDylibPaths.isEmpty {
                    Text("从「文件」App 选择 .dylib，导入后保存在本机动态库目录。左滑可删除。")
                } else {
                    Text("已选 \(selectedDylibPaths.count) 个，将按列表顺序依次注入。")
                }
            }

            // MARK: AI 生成
            Section {
                Button {
                    startAIConversation()
                } label: {
                    Label("让 AI 分析与生成 Hook", systemImage: "sparkles")
                }

                if let produced = HookChatRouter.latestProducedDylib(bundleID: app.bundleId) {
                    Button {
                        if !selectedDylibPaths.contains(produced) {
                            selectedDylibPaths.insert(produced)
                        }
                        reloadDylibs()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("使用 AI 最近产出的动态库", systemImage: "wand.and.stars")
                            Text((produced as NSString).lastPathComponent)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("将跳转到聊天会话，AI 会先分析目标 App 再与你确认 Hook 方案，确认后自动生成动态库并询问是否注入。")
            }

            // MARK: 注入通道说明
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("无痕沙盒注入引擎")
                            .font(.body.weight(.medium))
                        Text("基于 Relaxin 官方通道执行，不篡改目标 App bundle，零文件污染，杜绝签名闪退")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("注入通道")
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
                            Text(selectedDylibPaths.count > 1
                                 ? "依次注入 \(selectedDylibPaths.count) 个"
                                 : "开始动态注入")
                        }
                        Spacer()
                    }
                }
                .disabled(running || selectedDylibPaths.isEmpty)

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
        .alert("删除动态库", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let p = pendingDeletePath { deleteDylib(p) }
                pendingDeletePath = nil
            }
            Button("取消", role: .cancel) { pendingDeletePath = nil }
        } message: {
            Text("将删除 \((pendingDeletePath as NSString?)?.lastPathComponent ?? "")\\n此操作不可恢复。")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.dylibTypes,
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("已切到聊天页", isPresented: $aiHintShown) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("开场说明已放入剪贴板并记录在会话上下文里。\n\n到聊天页把内容粘贴发送，AI 会先分析 \(app.name) 再与你确认 Hook 方案；确认后会调用工具生成动态库并询问是否注入。")
        }
        .onAppear {
            reloadDylibs()
            if let produced = HookChatRouter.latestProducedDylib(bundleID: app.bundleId),
               selectedDylibPaths.isEmpty {
                selectedDylibPaths.insert(produced)
            }
        }
    }

    // MARK: - dylib 类型

    static var dylibTypes: [UTType] {
        var types: [UTType] = []
        if let t = UTType(filenameExtension: "dylib") { types.append(t) }
        types.append(.data)
        return types
    }

    // MARK: - 动作

    /// 跳转到聊天会话，把目标 App 的上下文交给 AI
    private func startAIConversation() {
        HookChatRouter.launchConversation(app: app)
        aiHintShown = true
    }

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

        // 选中项中已不存在的（被删/被移走）要剔除，避免对着失效路径注入
        let stillValid = Set(availableDylibs)
        selectedDylibPaths = selectedDylibPaths.intersection(stillValid)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let path = try JailbreakInjector.importDylib(from: url)
                selectedDylibPaths.insert(path)
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

    /// 勾选/取消勾选
    private func toggleSelection(_ path: String) {
        if selectedDylibPaths.contains(path) {
            selectedDylibPaths.remove(path)
        } else {
            selectedDylibPaths.insert(path)
        }
    }

    /// 删除一个 dylib 文件（同时从选中集合移除）
    private func deleteDylib(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        selectedDylibPaths.remove(path)
        reloadDylibs()
    }

    /// 依次注入所有已勾选的 dylib。
    ///
    /// 为什么串行而不是并发：每次注入都会 spawn 一个 root 子进程去投递/签名/
    /// 调用 opainject，并短暂改写目标进程状态。并发会互相干扰暂存与清理，
    /// 也会让目标进程在同一时刻承受多次远程调用。逐个来最稳。
    private func startInject() {
        let targets = availableDylibs.filter { selectedDylibPaths.contains($0) }
        guard !targets.isEmpty else { return }
        running = true
        resultSuccess = nil
        resultMessage = ""
        progressText = "准备中…"

        var succeeded: [String] = []
        var failed: [(String, String)] = []

        func step(_ index: Int) {
            guard index < targets.count else {
                running = false
                progressText = ""
                let ok = failed.isEmpty
                resultSuccess = ok
                if targets.count == 1 {
                    resultMessage = ok
                        ? "注入成功"
                        : (failed.first?.1 ?? "注入失败")
                } else {
                    var parts: [String] = ["成功 \(succeeded.count)/\(targets.count)"]
                    for (name, reason) in failed {
                        parts.append("\(name)：\(reason)")
                    }
                    resultMessage = parts.joined(separator: "\n")
                }
                return
            }

            let path = targets[index]
            let name = (path as NSString).lastPathComponent
            progressText = "\(index + 1)/\(targets.count) \(name)"

            JailbreakInjector.inject(
                bundleID: app.bundleId,
                bundleURL: app.bundleURL,
                executableName: app.mainExecutableURL?.lastPathComponent,
                dylibPath: path,
                mode: mode,
                progress: { s in progressText = s },
                completion: { outcome in
                    if outcome.success {
                        succeeded.append(name)
                    } else {
                        failed.append((name, outcome.message))
                    }
                    // 逐个之间留一点间隔，让目标进程缓一口气
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        step(index + 1)
                    }
                }
            )
        }

        step(0)
    }
}
