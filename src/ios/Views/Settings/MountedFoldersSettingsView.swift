//
//  MountedFoldersSettingsView.swift
//  MinisApp
//
//  Settings screen for managing user-mounted external folders. Lets the user
//  pick a folder from iOS Files (e.g. an Obsidian vault in iCloud Drive),
//  give it a custom name, and mount it at /var/minis/mounts/<name>.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let mountUILogger = AppLogger(category: "MountedFoldersUI")

/// Wrapper so we can drive the Add-Mount sheet via `.sheet(item:)`, which
/// guarantees the URL is present when the sheet is constructed. Using two
/// stacked `.sheet(isPresented:)` modifiers races on first pick: the
/// AddMountSheet is built before `pendingPickedURL` has propagated, so its
/// "Source path" section renders empty until the next attempt.
private struct PendingMount: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
    var allowWrite: Bool
}

struct MountedFoldersSettingsView: View {
    @StateObject private var model = MountedFoldersViewModel()
    @State private var showingPicker = false
    @State private var pendingMount: PendingMount?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                InfoBanner()
            }

            // 宿主访问：越狱/巨魔环境下直接读取系统路径（App 包、数据容器、越狱根）。
            // 与上面的「挂载外部文件夹」正交 —— 那边走 UIDocumentPicker 的
            // security-scoped bookmark，只能覆盖「文件」App 可见的目录。
            Section {
                NavigationLink {
                    HostAccessSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.purple, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("宿主访问")
                            Text(HostAccessManager.shared.level.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("系统路径")
            } footer: {
                Text("允许 AI 在静态分析时直接读取手机上任意文件（已装 App 的二进制、数据容器、越狱目录等）。三档：关闭 / 询问后访问 / 全自动访问。")
            }

            // 上下文窗口默认：全局可设自定义上限或完全不限制
            Section {
                NavigationLink {
                    ContextLimitSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.append")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.teal, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上下文窗口默认")
                            Text(GlobalContextDefaults.mode.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("对话")
            } footer: {
                Text("控制每次对话可用的上下文上限。可跟随模型原生窗口、自定义大小，或完全不限制（同时关闭自动压缩）。单个会话可在聊天页单独覆盖。")
            }

            // 中转站账户：余额、用量、性能指标直接显示在 App 内
            Section {
                NavigationLink {
                    RelayQuotaView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.green, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("中转站账户")
                            Text({
                                let svc = RelayQuotaService.shared
                                if let id = svc.selectedId, let d = svc.selectedData,
                                   let balance = d.account.balance {
                                    return String(format: "余额 $%.2f", balance)
                                }
                                if let id = svc.selectedId, svc.isLoggedIn(id) { return "已登录" }
                                return "查看余额与用量"
                            }())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("账户")
            } footer: {
                Text("登录中转站后，余额、今日与累计的请求数、消费、Token 用量与性能指标直接显示在 App 内，不必再开浏览器。")
            }

            // GitHub 连接：AI 可直接操作仓库、文件、Issue 与 PR
            Section {
                NavigationLink {
                    GitHubSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.black, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GitHub 连接")
                            Text(GitHubService.shared.connected
                                 ? "@\(GitHubService.shared.account?.login ?? "")"
                                 : "未连接")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("代码托管")
            } footer: {
                Text("填入个人访问令牌后，AI 可直接操作你的 GitHub：查看与创建仓库、读写代码并提交、管理分支、处理 Issue 与 PR、搜索。")
            }

            if model.entries.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No mounted folders")
                            .font(.headline)
                        Text("Tap + to pick a folder from Files (e.g. an Obsidian vault in iCloud Drive).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(model.entries) { entry in
                        NavigationLink {
                            MountDetailView(
                                context: detailContext(for: entry),
                                onDismiss: { model.refresh() }
                            )
                        } label: {
                            MountedFolderRow(
                                entry: entry,
                                state: model.state(for: entry.id),
                                sourceURL: model.resolvedURL(for: entry.id)
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.remove(id: entry.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Mounted Folders")
                        Spacer()
                        Text("\(model.entries.count) / \(MountedFoldersManager.maxMountCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(model.isAtCapacity ? .orange : .secondary)
                    }
                } footer: {
                    if model.isAtCapacity {
                        Text("Mount limit reached. Remove an existing mount before adding a new one.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Mount External Folders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.isAtCapacity)
            }
        }
        .sheet(isPresented: $showingPicker) {
            FolderPicker { url in
                // `UIDocumentPickerViewController` fires its `didPickDocumentsAt`
                // delegate *after* SwiftUI has already started dismissing the
                // sheet, but we still need to wait until the dismissal fully
                // finishes before presenting a second sheet — iOS refuses to
                // stack two sheets, so assigning `pendingMount` synchronously
                // here silently drops the presentation on first try.
                // Hopping to the next run loop tick lets the picker sheet
                // finish leaving the hierarchy first.
                mountUILogger.info("FolderPicker onPick url=\(url.path)")
                DispatchQueue.main.async {
                    let pm = PendingMount(
                        url: url,
                        name: Self.defaultMountName(for: url),
                        allowWrite: true
                    )
                    mountUILogger.info("async assign pendingMount id=\(pm.id.uuidString) url=\(url.path)")
                    pendingMount = pm
                }
            }
        }
        .sheet(item: $pendingMount) { pending in
            // IMPORTANT: read from the `pending` closure parameter, not from
            // `pendingMount?.url` — the Optional state binding can be
            // momentarily nil while SwiftUI re-routes the sheet, which blanks
            // out the Source Path field.
            AddMountSheet(
                sourceURL: pending.url,
                name: Binding(
                    get: { pendingMount?.name ?? pending.name },
                    set: { pendingMount?.name = $0 }
                ),
                allowWrite: Binding(
                    get: { pendingMount?.allowWrite ?? pending.allowWrite },
                    set: { pendingMount?.allowWrite = $0 }
                ),
                onCancel: {
                    pendingMount = nil
                },
                onConfirm: {
                    let current = pendingMount ?? pending
                    do {
                        _ = try model.add(
                            pickedURL: current.url,
                            customName: current.name,
                            userAllowWrite: current.allowWrite
                        )
                    } catch {
                        errorText = error.localizedDescription
                    }
                    pendingMount = nil
                }
            )
        }
        .alert(AppLocalized("Error"),
               isPresented: Binding(get: { errorText != nil },
                                    set: { if !$0 { errorText = nil } })) {
            Button(AppLocalized("OK"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    /// Build the MountDetailView context for an external-mount entry.
    private func detailContext(for entry: MountedFolderEntry) -> MountDetailContext {
        // Host URL for Browse Files goes through the fakefs symlink so the
        // breadcrumb shows /var/minis/mounts/<name>.
        let mountPath = RootfsManager.shared.dataPath
            .appendingPathComponent("var/minis/mounts", isDirectory: true)
            .appendingPathComponent(entry.name)
        return MountDetailContext(
            kind: .external,
            linuxPath: "/var/minis/mounts/\(entry.name)",
            sourceDisplayName: entry.sourceDisplayName,
            hostURL: mountPath,
            iconName: "externaldrive.fill",
            iconColor: .orange,
            subtitle: nil,
            initialName: entry.name,
            canRename: true,
            externalMountId: entry.id,
            isOSWritable: entry.isWritable,
            initialUserAllowWrite: entry.userAllowWrite,
            sharedFolderName: nil,
            initialVisibleInFiles: true,
            isReadOnlyFromFiles: false
        )
    }

    /// Trivial / meaningless segments often appearing at the end of an iCloud
    /// container identifier's reverse-DNS bundle ID (e.g. `iCloud~com~nssurge~inc`
    /// where "inc" is just the company suffix). We skip these when picking a
    /// friendly default mount name.
    private static let trivialSuffixes: Set<String> = [
        "inc", "ltd", "llc", "app", "co", "corp", "gmbh"
    ]

    /// Default mount name suggestion.
    ///
    /// When the user picks an iCloud Drive app folder, `url.lastPathComponent`
    /// is often literally "Documents" because Apple's ubiquity container
    /// structure is:
    ///     .../Mobile Documents/iCloud~<team>~<bundle-parts>/Documents/
    ///
    /// Using "Documents" as the mount name gives no hint about which app the
    /// folder belongs to. We detect that case and instead derive the name
    /// from the parent container, picking the most meaningful segment of the
    /// reverse-DNS bundle ID (e.g. `iCloud~com~nssurge~inc` → `nssurge`, not
    /// `inc`).
    private static func defaultMountName(for url: URL) -> String {
        let lastName = url.lastPathComponent
        let candidate: String
        if lastName == "Documents" {
            // Walk up: parent is the ubiquity container directory.
            let parent = url.deletingLastPathComponent()
            let parentName = parent.lastPathComponent
            if parentName.hasPrefix("iCloud~") {
                // Format: "iCloud~<team>~<bundle-component-1>~<bundle-component-2>..."
                // Drop the "iCloud" prefix and the TLD-like team segment
                // (index 1, usually "com" / "net" / "org" / "io" / "md").
                let parts = parentName.split(separator: "~").map(String.init)
                let remaining = Array(parts.dropFirst(2)) // drop "iCloud" + team
                // Prefer the last segment that isn't a trivial corporate suffix.
                let best = remaining.reversed().first { segment in
                    !Self.trivialSuffixes.contains(segment.lowercased())
                } ?? remaining.last ?? parts.last ?? lastName
                candidate = best
            } else if !parentName.isEmpty {
                // Not an iCloud container but still called Documents —
                // fall back to the parent name for disambiguation.
                candidate = parentName
            } else {
                candidate = lastName
            }
        } else {
            candidate = lastName
        }

        let cleaned = candidate
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "mount" : cleaned
    }
}

// MARK: - Banner

private struct InfoBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mount external folders", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Picked folders are bind-mounted at /var/minis/mounts/<name>. You can browse them in Browse Files and read/write them directly from the iSH shell, just like /var/minis/shared. Up to 10 folders can be mounted at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row

private struct MountedFolderRow: View {
    let entry: MountedFolderEntry
    let state: MountActivationState
    let sourceURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(entry.name)
                    .font(.body.weight(.medium))
                accessBadge
                Spacer()
            }
            Text("/var/minis/mounts/\(entry.name)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "← \(sourceURL?.path ?? entry.sourceDisplayName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    /// Small pill reflecting the effective write state of this mount:
    /// - "R/W": the OS allows writes AND the user allowed writes
    /// - "Locked": the OS allows writes but the user set Allow Writes = off
    /// - "Read-only": the OS itself does not allow writes (user choice n/a)
    @ViewBuilder
    private var accessBadge: some View {
        if !entry.isWritable {
            badgePill(text: AppLocalized("Read-only"), color: .orange)
        } else if !entry.userAllowWrite {
            badgePill(text: AppLocalized("Locked"), color: .purple)
        } else {
            badgePill(text: AppLocalized("R/W"), color: .green)
        }
    }

    private func badgePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - Add mount sheet

private struct AddMountSheet: View {
    let sourceURL: URL?
    @Binding var name: String
    @Binding var allowWrite: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let url = sourceURL {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Source path")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(url.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    } footer: {
                        Text("The path above is how iOS exposes the folder you picked. Use it to confirm which app this data belongs to.")
                            .font(.caption2)
                    }
                }

                Section(header: Text("Mount name")) {
                    TextField("name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("This will be the folder name under /var/minis/mounts/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $allowWrite) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow writes")
                            Text(allowWrite
                                ? AppLocalized("AI, shell, and Files browser can modify files in this mount.")
                                : AppLocalized("This mount will be exposed as read-only. Useful for reference vaults you don't want the AI to touch."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("You can change the write permission later from the mount details page.")
                        .font(.caption)
                }
            }
            .navigationTitle("New Mount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Mount"), action: onConfirm)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Folder picker

private struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MountedFoldersViewModel: ObservableObject {
    @Published private(set) var entries: [MountedFolderEntry] = []
    @Published private(set) var states: [UUID: MountActivationState] = [:]

    var isAtCapacity: Bool {
        entries.count >= MountedFoldersManager.maxMountCount
    }

    init() {
        refresh()
    }

    func refresh() {
        entries = MountedFoldersManager.shared.entries
        states = MountedFoldersManager.shared.activationStates
    }

    func state(for id: UUID) -> MountActivationState {
        states[id] ?? .failed("")
    }

    /// Resolved host URL for a mount, if currently active. Exposed to row views
    /// so they can display the underlying iOS filesystem path.
    func resolvedURL(for id: UUID) -> URL? {
        MountedFoldersManager.shared.resolvedURL(for: id)
    }

    @discardableResult
    func add(pickedURL: URL, customName: String, userAllowWrite: Bool) throws -> MountedFolderEntry {
        // The document picker gives a URL with scope active; start it once more
        // defensively so MountedFoldersManager's bookmarkData call inside succeeds.
        let started = pickedURL.startAccessingSecurityScopedResource()
        defer { if started { pickedURL.stopAccessingSecurityScopedResource() } }
        let entry = try MountedFoldersManager.shared.add(
            pickedURL: pickedURL,
            customName: customName,
            userAllowWrite: userAllowWrite
        )
        refresh()
        return entry
    }

    func remove(id: UUID) {
        MountedFoldersManager.shared.remove(id: id)
        refresh()
    }

    func rename(id: UUID, to newName: String) throws {
        try MountedFoldersManager.shared.rename(id: id, to: newName)
        refresh()
    }

    func setUserAllowWrite(id: UUID, to allow: Bool) {
        MountedFoldersManager.shared.setUserAllowWrite(id: id, to: allow)
        refresh()
    }
}
