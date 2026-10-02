//
//  FridaAppsView.swift
//  KyTuT
//
//  目标 App 管理：
//   - 列出全部已安装 App（LSApplicationWorkspace，图标/名称/版本/加密状态）
//   - 详情页：路径信息 / 浏览沙盒（数据容器 + Bundle）/ 复制到沙盒供 AI 分析
//   - 详情页内置「动态注入」面板：选择 dylib 与注入模式后可对当前 App 注入
//     （运行时可逆，重启后失效；注入日志可在 App 内查看）
//

import SwiftUI
import UIKit

// MARK: - App 列表

struct FridaAppsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledAppInfo] = []
    @State private var loading = true
    @State private var search = ""
    @State private var includeSystem = false
    @State private var selected: InstalledAppInfo?

    private var filtered: [InstalledAppInfo] {
        guard !search.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.bundleId.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("读取 App 列表…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("未读到任何 App").font(.headline)
                        Text("需要以扩展权限（no-sandbox）签名。\n若刚更新，请先卸载再重装本 App。")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { app in
                            Button { selected = app } label: {
                                HStack(spacing: 12) {
                                    AppIconView(icon: app.icon)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(app.bundleId).font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if app.isEncrypted {
                                        Text("🔒加密").font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(.red.opacity(0.15)))
                                            .foregroundStyle(.red)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("目标 App 管理")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索名称 / Bundle ID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Toggle("系统", isOn: $includeSystem)
                        .toggleStyle(.button)
                        .onChange(of: includeSystem) { _ in reload() }
                }
            }
            .sheet(item: $selected) { app in
                FridaAppDetailView(app: app)
            }
            .task { reload() }
        }
    }

    private func reload() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let list = InstalledAppsService.listApps(includeSystem: includeSystem)
            await MainActor.run {
                apps = list
                loading = false
            }
        }
    }
}

// MARK: - 图标

struct AppIconView: View {
    let icon: UIImage?
    var body: some View {
        if let icon {
            Image(uiImage: icon)
                .resizable().frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            RoundedRectangle(cornerRadius: 9)
                .fill(.quaternary).frame(width: 40, height: 40)
                .overlay(Image(systemName: "app").foregroundStyle(.secondary))
        }
    }
}

// MARK: - App 详情

struct FridaAppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let app: InstalledAppInfo

    /// bundleSize 是递归枚举整个 Bundle（几千文件）的重操作，不能在 body 里
    /// 直接触发（主线程卡顿）—— 后台算一次存这里。
    @State private var bundleSizeText = "…"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AppIconView(icon: app.icon)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.title3.bold())
                            Text(app.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if !app.version.isEmpty { Text("v\(app.version)") }
                                Text(bundleSizeText)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if app.isEncrypted {
                        Label("该 App 带 FairPlay 加密，二进制在磁盘上是密文，静态分析意义有限",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.red)
                    } else {
                        Label("磁盘上已解密，可直接复制二进制做静态分析", systemImage: "lock.open.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                } header: {
                    Text("加密状态")
                }

                Section("动态注入") {
                    NavigationLink {
                        InjectPanelView(app: app, onRequestAIHook: nil)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.orange, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("注入动态库")
                                Text("采用 Relaxin 官方无痕沙盒注入引擎")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        InjectLogViewer()
                    } label: {
                        Label("注入日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("沙盒") {
                    if let container = app.dataContainerURL {
                        NavigationLink {
                            SandboxBrowserView(title: app.name, root: container)
                        } label: {
                            Label("浏览数据容器", systemImage: "folder")
                        }
                    }
                    NavigationLink {
                        SandboxBrowserView(title: "\(app.name) Bundle", root: app.bundleURL)
                    } label: {
                        Label("浏览 Bundle", systemImage: "shippingbox")
                    }
                }

                Section("路径") {
                    LabeledCopyRow("Bundle", app.bundleURL.path)
                    if let c = app.dataContainerURL {
                        LabeledCopyRow("数据容器", c.path)
                    }
                    if let exe = app.mainExecutableURL {
                        LabeledCopyRow("主二进制", exe.lastPathComponent)
                    }
                }
            }
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .task {
                // bundleSize 递归枚举整个 Bundle 目录（几千文件），后台算一次。
                // 加密状态已是存储字段（listApps 时算好），body 零重 IO。
                let bundleURL = app.bundleURL
                let size = await Task.detached(priority: .utility) { () -> Int64 in
                    FileManager.default.accumulatedFileSize(of: bundleURL)
                }.value
                bundleSizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }
    }
}

// MARK: - 可复制行

struct LabeledCopyRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
            Spacer()
            Button {
                UIPasteboard.general.string = value
            } label: {
                Image(systemName: "doc.on.doc")
            }.buttonStyle(.borderless)
        }
    }
}

// MARK: - 沙盒浏览器（#3）

struct SandboxBrowserView: View {
    let title: String
    let root: URL

    @State private var dirStack: [URL] = []
    @State private var entries: [(name: String, isDir: Bool, size: Int64)] = []
    @State private var loadError: String?
    @State private var previewFile: FilePreview?

    private var currentURL: URL { dirStack.last ?? root }

    var body: some View {
        List {
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
            Section {
                ForEach(entries, id: \.name) { e in
                    let url = currentURL.appendingPathComponent(e.name)
                    if e.isDir {
                        Button {
                            dirStack.append(url)
                            reload()
                        } label: {
                            Label(e.name, systemImage: "folder.fill")
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Button { previewFile = FilePreview(url: url) } label: {
                            HStack {
                                Label(e.name, systemImage: fileIcon(e.name))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("/" + currentURL.path.replacingOccurrences(of: root.path + "/", with: ""))
                    .font(.caption2.monospaced())
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if dirStack.count > 1 {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dirStack.removeLast()
                        reload()
                    } label: { Image(systemName: "chevron.left") }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: root) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { if dirStack.isEmpty { dirStack = [root] }; reload() }
        .sheet(item: $previewFile) { p in
            SandboxFilePreviewSheet(file: p)
        }
    }

    private func reload() {
        loadError = nil
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: currentURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            loadError = "无法读取该目录（权限不足？）"
            entries = []
            return
        }
        entries = items
            .compactMap { url -> (String, Bool, Int64)? in
                let name = url.lastPathComponent
                guard !name.hasPrefix(".") else { return nil }
                guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
                return (name, v.isDirectory == true, Int64(v.fileSize ?? 0))
            }
            .sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "plist": return "gearshape"
        case "db", "sqlite", "sqlite3": return "cylinder"
        case "json": return "curlybraces"
        case "js": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        case "dylib": return "puzzlepiece.extension"
        case "ipa": return "shippingbox"
        default: return "doc"
        }
    }
}

// MARK: - 文件预览

struct FilePreview: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct SandboxFilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: FilePreview
    @State private var text: String?
    @State private var tooLarge = false
    @State private var copiedToSandbox = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let text {
                        ScrollView {
                            Text(text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .textSelection(.enabled)
                        }
                    } else if tooLarge {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.badge.ellipsis")
                                .font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("文件过大（>512KB），不建议文本预览").font(.subheadline)
                            if !copiedToSandbox {
                                Button {
                                    copyToSandbox()
                                } label: {
                                    Label("复制到沙盒供 AI 分析", systemImage: "arrow.right.doc.on.clipboard")
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Label("已复制到沙盒 /var/minis/workspace", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(file.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .task {
                let url = file.url
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 512 * 1024 {
                    tooLarge = true
                    return
                }
                text = try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }

    private func copyToSandbox() {
        let dest = URL(fileURLWithPath: "/var/minis/workspace")
            .appendingPathComponent(file.url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: file.url, to: dest)
            copiedToSandbox = true
        } catch {}
    }
}
