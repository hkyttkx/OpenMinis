//
//  LocalSnapshotView.swift
//  KyTuT
//
//  「设置 → 备份与恢复 → 本机快照」
//
//  把聊天记录与配置备份到 App Group 容器，卸载重装后仍在。
//  同时支持导出为文件保存到任意位置，以及从文件导入恢复。
//

import SwiftUI
import UniformTypeIdentifiers

struct LocalSnapshotView: View {
    @StateObject private var store = LocalSnapshotStore.shared

    @State private var showRestoreConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportDoc: SnapshotExportDoc?
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        List {
            // MARK: 容器状态
            Section {
                HStack {
                    Image(systemName: store.containerAvailable
                          ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.containerAvailable ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.containerAvailable ? "共享容器可用" : "共享容器不可用")
                        Text("group.com.openminis.app")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !store.containerAvailable {
                    Text("缺少 App Group 权限，本机快照无法使用。")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("存储位置")
            } footer: {
                Text("快照保存在 App 的共享容器中。iOS 在卸载 App 时会删除其沙盒，但共享容器只有在你删除所有相关 App 后才清理 —— 所以卸载重装后数据仍在。")
            }

            // MARK: 当前快照
            Section {
                if let m = store.meta {
                    LabeledContent("备份时间", value: Self.fmt.string(from: m.createdAt))
                    LabeledContent("数据量", value: store.snapshotSizeText())
                    LabeledContent("文件数", value: "\(m.itemCount)")
                    LabeledContent("包含", value: m.includedNames.joined(separator: "、"))
                    LabeledContent("App 版本", value: "\(m.appVersion)(\(m.buildNumber))")
                } else {
                    Text("还没有本机快照")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前快照")
            } footer: {
                Text("快照包含聊天记录与设置配置。建议在重要操作前手动备份一次。")
            }

            // MARK: 操作
            Section {
                Button {
                    Task {
                        await store.createSnapshot()
                        if store.lastError == nil {
                            report("快照已创建", isError: false)
                        } else {
                            report(store.lastError ?? "创建失败", isError: true)
                        }
                    }
                } label: {
                    HStack {
                        Label("立即备份", systemImage: "arrow.down.doc")
                        Spacer()
                        if store.busy { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(store.busy || !store.containerAvailable)

                Button {
                    showRestoreConfirm = true
                } label: {
                    Label("从本机快照恢复", systemImage: "arrow.uturn.backward")
                }
                .disabled(store.busy || !store.hasSnapshot)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除快照", systemImage: "trash")
                }
                .disabled(store.busy || !store.hasSnapshot)

                if !store.progressText.isEmpty {
                    Text(store.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("本机恢复")
            } footer: {
                Text("恢复会替换当前的聊天记录与配置，操作前会自动保留一份 pre-restore 副本以便回退。恢复完成后建议重启 App。")
            }

            // MARK: 导出 / 导入
            Section {
                Button {
                    prepareExport()
                } label: {
                    Label("导出为文件", systemImage: "square.and.arrow.up")
                }
                .disabled(store.busy || !store.hasSnapshot)

                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(store.busy)

                Button {
                    showImporter = true
                } label: {
                    Label("从已挂载路径读取", systemImage: "externaldrive")
                }
                .disabled(store.busy)
            } header: {
                Text("文件交换")
            } footer: {
                Text("导出把快照打包成文件，可保存到「文件」App、iCloud Drive 或任何已挂载的位置；导入从这些位置读回并恢复。换设备时用这条路径迁移。")
            }

            if let msg = resultMessage {
                Section {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(resultIsError ? Color.red : Color.green)
                }
            }
        }
        .navigationTitle("本机快照")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认恢复？", isPresented: $showRestoreConfirm) {
            Button("恢复", role: .destructive) {
                Task {
                    let ok = await store.restoreSnapshot()
                    report(ok ? "恢复完成，建议重启 App 使全部生效"
                              : (store.lastError ?? "恢复失败"),
                           isError: !ok)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将用快照覆盖当前的聊天记录与设置。原数据会保留为 pre-restore 副本。")
        }
        .alert("删除快照？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { store.deleteSnapshot() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。建议先导出为文件保存。")
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDoc,
                      contentType: .folder,
                      defaultFilename: "KyTuT-Snapshot") { result in
            switch result {
            case .success(let url):
                report("已导出到 \(url.lastPathComponent)", isError: false)
            case .failure(let e):
                report("导出失败：\(e.localizedDescription)", isError: true)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder, .data],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    // MARK: - 辅助

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func report(_ msg: String, isError: Bool) {
        resultMessage = msg
        resultIsError = isError
    }

    private func prepareExport() {
        guard let root = store.snapshotRoot else { return }
        exportDoc = SnapshotExportDoc(url: root)
        showExporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let ok = await store.importSnapshot(from: url)
                report(ok ? "已导入快照，可在上方点「从本机快照恢复」应用"
                          : (store.lastError ?? "导入失败"),
                       isError: !ok)
            }
        case .failure(let e):
            report("选择失败：\(e.localizedDescription)", isError: true)
        }
    }
}

// MARK: - 导出用的 Document

struct SnapshotExportDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    var url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // 直接引用已有目录 —— fileExporter 会把它整体拷到用户选的位置
        return try FileWrapper(url: url, options: .immediate)
    }
}
