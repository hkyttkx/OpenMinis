//
//  FridaAppsView.swift
//  KyTuT
//
//  目标 App 管理：
//   - 列出全部已安装 App（图标/名称/版本/加密状态/安装来源）
//   - 顶部按安装来源筛选：全部 / 商店 / 巨魔 / 系统 / 其他
//   - 详情页：路径信息 / 浏览沙盒（数据容器 + Bundle）/ 复制到沙盒供 AI 分析
//   - 详情页内置「动态注入」面板
//

import SwiftUI
import UIKit

// MARK: - App 列表

struct FridaAppsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledAppInfo] = []
    @State private var loading = true
    @State private var search = ""
    @State private var sourceFilter: AppInstallSource? = nil   // nil = 全部
    @State private var selected: InstalledAppInfo?

    private var filtered: [InstalledAppInfo] {
        var list = apps
        if let f = sourceFilter {
            list = list.filter { $0.source == f }
        }
        guard !search.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.bundleId.localizedCaseInsensitiveContains(search)
        }
    }

    /// 各来源的数量（用于筛选条上的角标与禁用空分类）
    private var counts: [AppInstallSource: Int] {
        var m: [AppInstallSource: Int] = [:]
        for a in apps { m[a.source, default: 0] += 1 }
        return m
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
                        Text("需要以扩展权限签名。\n若刚更新，请先卸载再重装本 App。")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        sourceFilterBar
                        Divider()
                        appList
                    }
                }
            }
            .navigationTitle("目标 App 管理")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索名称 / Bundle ID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            sourceFilter = nil
                            reload()
                        } label: {
                            Label("重新读取全部 App", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $selected) { app in
                FridaAppDetailView(app: app)
            }
            .task { reload() }
        }
    }

    // MARK: 来源筛选条

    /// 横向滚动的来源筛选。做成横向滚动而不是 segmented，是为了容纳
    /// 5 个分类 + 数量角标而不挤压文字（小屏 segmented 会截断标题）。
    private var sourceFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: "全部", count: apps.count, source: nil)

                ForEach(AppInstallSource.allCases) { src in
                    let n = counts[src] ?? 0
                    sourceChip(title: src.shortTitle, count: n, source: src)
                        .opacity(n == 0 ? 0.4 : 1.0)
                        .disabled(n == 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }

    private func sourceChip(title: String, count: Int, source: AppInstallSource?) -> some View {
        let active = sourceFilter == source
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { sourceFilter = source }
        } label: {
            HStack(spacing: 5) {
                if let s = source {
                    Image(systemName: s.systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(active ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(active ? Color.accentColor : Color(UIColor.tertiarySystemFill))
            )
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 列表

    private var appList: some View {
        List {
            if filtered.isEmpty {
                Text("该分类下没有 App")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                        sourceBadge(app.source)
                        if app.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func sourceBadge(_ src: AppInstallSource) -> some View {
        Text(src.shortTitle)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(badgeColor(src).opacity(0.15)))
            .foregroundStyle(badgeColor(src))
    }

    private func badgeColor(_ src: AppInstallSource) -> Color {
        switch src {
        case .appStore:   return .blue
        case .trollStore: return .purple
        case .system:     return .gray
        case .other:      return .orange
        }
    }

    private func reload() {
        loading = true
        // 来源筛选包含系统 App，所以始终带 includeSystem 拉全量，
        // 由 sourceFilter 决定展示哪些（避免切换分类时反复重扫磁盘）。
        Task.detached(priority: .userInitiated) {
            let list = InstalledAppsService.listApps(includeSystem: true)
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
                    HStack(spacing: 10) {
                        Image(systemName: app.source.systemImage)
                            .foregroundStyle(.secondary)
                        Text(app.source.title).font(.body.weight(.medium))
                        Spacer()
                        if let t = app.teamID, !t.isEmpty {
                            Text(t).font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(app.source.injectionHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("安装来源")
                }

                Section {
                    if app.isEncrypted {
                        Label("二进制在磁盘上仍带 FairPlay 加密（静态分析意义有限）",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.red)
                        Text("注意：动态注入不依赖砸壳 —— 目标进程运行时，代码在内核里已解密。加密不影响注入。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("磁盘上已解密，可直接复制二进制做静态分析",
                              systemImage: "lock.open.fill")
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
