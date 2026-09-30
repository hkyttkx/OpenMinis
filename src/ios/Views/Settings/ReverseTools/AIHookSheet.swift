//
//  AIHookSheet.swift
//  KyTuT
//
//  AI Hook 生成与注入闭环。
//
//  流程：
//    1. 用户点击「让 AI 分析并生成 Hook」
//    2. 输入希望达成的效果（自然语言，可选）
//    3. AI 生成 Objective-C Hook 源码（在当前会话里由模型输出）
//    4. 源码在本机 Alpine 沙盒内用 clang 编译成 dylib
//    5. 编译成功 → 弹窗询问「是否立即注入该 dylib」
//    6. 确认 → 跳回注入面板并预选该 dylib
//

import SwiftUI

struct AIHookSheet: View {
    let app: InstalledAppInfo
    /// 编译成功并通过用户确认后回调，把 dylib 路径交回注入面板
    let onReadyToInject: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var requirement: String = ""
    @State private var sourceCode: String = ""
    @State private var compiling = false
    @State private var compileResult: HookDylibCompiler.CompileResult?
    @State private var askInject = false
    @State private var hookName: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("希望实现什么效果？例如：绕过登录校验", text: $requirement, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("目标")
                } footer: {
                    Text("描述越具体，生成的 Hook 越贴合。留空则生成一个探测模板。")
                }

                Section {
                    TextField("hook 名称", text: $hookName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("产物名称")
                } footer: {
                    Text("将编译为 <名称>.dylib 并存入本机动态库目录。")
                }

                Section {
                    Button {
                        generateTemplate()
                    } label: {
                        Label("生成 Hook 源码模板", systemImage: "doc.text")
                    }
                    Button {
                        Task { await compileCurrentSource() }
                    } label: {
                        HStack {
                            Label("编译为动态库", systemImage: "hammer")
                            Spacer()
                            if compiling { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(compiling || sourceCode.isEmpty)
                } header: {
                    Text("编译")
                } footer: {
                    Text("编译在 App 内置的 Alpine 沙盒里完成，使用 clang 交叉编译出 arm64 动态库。")
                }

                if !sourceCode.isEmpty {
                    Section("源码预览") {
                        Text(sourceCode)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxHeight: 260)
                    }
                }

                if let r = compileResult {
                    Section("编译结果") {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: r.success ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(r.success ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.success ? "编译成功" : "编译失败")
                                    .font(.body.weight(.medium))
                                if let err = r.error {
                                    Text(err).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !r.output.isEmpty {
                            DisclosureGroup("编译器输出") {
                                Text(r.output)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if r.success {
                            Button {
                                askInject = true
                            } label: {
                                Label("立即注入到 \(app.name)", systemImage: "bolt.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("AI 生成 Hook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                if hookName.isEmpty {
                    hookName = "Hook_\(app.bundleId.replacingOccurrences(of: ".", with: "_"))"
                }
            }
            .alert("是否立即注入？", isPresented: $askInject) {
                Button("注入") {
                    if let p = compileResult?.dylibPath {
                        onReadyToInject(p)
                        dismiss()
                    }
                }
                Button("稍后", role: .cancel) {}
            } message: {
                Text("将把 \((compileResult?.dylibPath as NSString?)?.lastPathComponent ?? "动态库") 注入到 \(app.name)。\n\n运行时可逆，目标 App 重启后失效。")
            }
        }
    }

    // MARK: - 动作

    private func generateTemplate() {
        sourceCode = HookDylibCompiler.minimalHookTemplate(
            bundleID: app.bundleId,
            className: "NSObject",
            methodName: "description"
        )
    }

    private func compileCurrentSource() async {
        compiling = true
        compileResult = nil
        let name = hookName.isEmpty ? "HookDylib" : hookName
        let r = await HookDylibCompiler.compile(source: sourceCode, name: name)
        compiling = false
        compileResult = r
    }
}
