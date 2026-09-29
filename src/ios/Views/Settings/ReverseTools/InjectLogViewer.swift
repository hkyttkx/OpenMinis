//
//  InjectLogViewer.swift
//  KyTuT
//
//  动态注入日志查看器
//  日志由 JailbreakInjector 写入 <Documents>/inject_debug.log，
//  内容包括：每次注入的目标、模式、各阶段结果、trust cache 通道命中情况，
//  以及目标 App 闪退时从 CrashReporter 抓回的报告摘要。
//

import SwiftUI

struct InjectLogViewer: View {
    @Environment(\.dismiss) private var dismiss

    @State private var logContent: String = ""
    @State private var isRefreshing = false
    @State private var autoScroll = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if logContent.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.secondary)
                                Text("暂无注入日志")
                                    .font(.headline)
                                Text("在「目标 App 管理」里对一个 App 执行动态注入后，\n这里会显示完整过程与失败原因。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else {
                            Text(logContent)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("logBottom")
                        }
                    }
                }
                .onChange(of: logContent) { _ in
                    guard autoScroll else { return }
                    withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
                }
                .onAppear {
                    loadLog()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            .navigationTitle("动态注入日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        loadLog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)

                    ShareLink(item: URL(fileURLWithPath: JailbreakInjector.logPath)) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Menu {
                        Toggle("自动滚到底部", isOn: $autoScroll)
                        Button(role: .destructive) {
                            JailbreakInjector.clearLog()
                            loadLog()
                        } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func loadLog() {
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let content = JailbreakInjector.readLog()
            DispatchQueue.main.async {
                logContent = (content == "（暂无日志）") ? "" : content
                isRefreshing = false
            }
        }
    }
}
