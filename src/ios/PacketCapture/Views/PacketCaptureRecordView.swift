import SwiftUI
import TunnelServices

// MARK: - 记录列表（按 Task 分组）

private struct TaskDaySection: Identifiable {
    let date: Date
    let tasks: [TunnelServices.Task]
    var id: Date { date }
}

struct PacketCaptureRecordView: View {
    @StateObject private var viewModel = RecordListVM()
    @State private var searchText = ""
    @State private var showClearConfirm = false

    private var groupedSections: [TaskDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.filteredTasks) { task in
            let ts = task.startTime?.doubleValue ?? 0
            return calendar.startOfDay(for: Date(timeIntervalSince1970: max(0, ts)))
        }
        return grouped.keys.sorted(by: >).map { date in
            let tasks = (grouped[date] ?? []).sorted {
                ($0.startTime?.doubleValue ?? 0) > ($1.startTime?.doubleValue ?? 0)
            }
            return TaskDaySection(date: date, tasks: tasks)
        }
    }

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 内嵌搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索域名", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if isSearchFocused {
                    Button("取消") {
                        searchText = ""
                        isSearchFocused = false
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                if groupedSections.isEmpty {
                    emptyState(icon: "tray", title: "暂无记录", message: "开启 VPN 抓包后，记录将显示在这里")
                } else {
                    ForEach(groupedSections) { section in
                        Section(header: Text(sectionTitle(section.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)
                        ) {
                            ForEach(section.tasks, id: \.id) { task in
                                NavigationLink(destination: TaskSessionListView(task: task)) {
                                    TaskRowView(task: task)
                                }
                            }
                            .onDelete { offsets in
                                viewModel.deleteTasks(in: section, at: offsets)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("抓包记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    Button { viewModel.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { viewModel.reload() }
        .onChange(of: searchText) { viewModel.updateSearch($0) }
        .alert("确认清除", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除全部", role: .destructive) {
                PacketHoundDataStore.shared.clearAllRecords()
                viewModel.reload()
            }
        } message: {
            Text("将清除所有抓包记录和存储文件，此操作不可恢复")
        }
    }

    private func sectionTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今日" }
        if cal.isDateInYesterday(date) { return "昨日" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/M/d"
        return fmt.string(from: date)
    }
}

// MARK: - Task 行

private struct TaskRowView: View {
    let task: TunnelServices.Task

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(startText)
                        .font(.subheadline.weight(.bold))
                    Text(taskDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(durationText) · \(task.interceptCount.intValue) 请求 · ↑\(fmtBytes(task.uploadTraffic.int64Value)) ↓\(fmtBytes(task.downloadFlow.int64Value))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var startText: String {
        guard let ts = task.startTime?.doubleValue, ts > 0 else { return "-" }
        return Self.timeFmt.string(from: Date(timeIntervalSince1970: ts))
    }

    private var taskDisplayName: String {
        let name = task.ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.lowercased() == "default" {
            return "全局抓包"
        }
        return name
    }

    private var durationText: String {
        guard let s = task.startTime?.doubleValue, s > 0 else { return "-" }
        guard let e = task.stopTime?.doubleValue, e > 0 else { return "进行中" }
        let sec = Int(max(0, e - s))
        if sec < 60 { return "\(sec)秒" }
        if sec < 3600 { return "\(sec / 60)分\(sec % 60)秒" }
        return "\(sec / 3600)小时\(sec % 3600 / 60)分钟"
    }
}

// MARK: - RecordList ViewModel

@MainActor
private final class RecordListVM: ObservableObject {
    @Published private(set) var filteredTasks: [TunnelServices.Task] = []
    private var allTasks: [TunnelServices.Task] = []
    private var query = ""
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: PacketHoundDataStore.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        PacketHoundDataStore.shared.configureIfNeeded()
        PacketHoundDataStore.shared.checkpoint()
        allTasks = TunnelServices.Task.findAll(pageSize: 500, pageIndex: 0, orderBy: "id")
        applySearch()
    }

    func updateSearch(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        applySearch()
    }

    func deleteTasks(in section: TaskDaySection, at offsets: IndexSet) {
        for index in offsets {
            guard section.tasks.indices.contains(index) else { continue }
            let task = section.tasks[index]
            // 删除该 Task 下的所有 Session
            if let taskID = task.id?.stringValue {
                let sessions = Session.findAll(
                    taskID: taskID, keyWord: nil, params: nil,
                    pageSize: 1_000_000, pageIndex: 0, orderBy: "id"
                )
                sessions.forEach { try? $0.delete() }
            }
            // 删除该 Task 下的抓包文件
            removeTaskFiles(task)
            // 删除 Task 本身
            try? task.delete()
        }
        reload()
    }

    private func removeTaskFiles(_ task: TunnelServices.Task) {
        guard let taskID = task.id?.stringValue,
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.openminis.app"
              ) else { return }
        let taskFolder = containerURL.appendingPathComponent("Task/\(taskID)", isDirectory: true)
        try? FileManager.default.removeItem(at: taskFolder)
    }

    private func applySearch() {
        guard !query.isEmpty else { filteredTasks = allTasks; return }
        let lower = query.lowercased()
        filteredTasks = allTasks.filter { task in
            // 匹配 Task 名称
            if task.ruleName.lowercased().contains(lower) { return true }
            // 匹配 Task ID
            if (task.id?.stringValue ?? "").contains(lower) { return true }
            // 查 Session 表匹配域名/URL
            return taskContainsDomain(task, keyword: query)
        }
    }

    private func taskContainsDomain(_ task: TunnelServices.Task, keyword: String) -> Bool {
        guard let taskID = task.id?.stringValue else { return false }
        let result = Session.findAll(
            taskID: taskID,
            keyWord: keyword,
            params: nil,
            pageSize: 1,
            pageIndex: 0,
            orderBy: "startTime"
        )
        return !result.isEmpty
    }
}

// MARK: - 共用工具

private func fmtBytes(_ bytes: Int64) -> String {
    let v = max(0, Double(bytes))
    if v < 1024 { return "\(Int(v))B" }
    let units = ["KB", "MB", "GB", "TB"]
    var size = v / 1024
    var i = 0
    while size >= 1024, i < units.count - 1 { size /= 1024; i += 1 }
    return size >= 100 ? String(format: "%.0f%@", size, units[i]) : String(format: "%.1f%@", size, units[i])
}

private func emptyState(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.secondary)
        Text(title).font(.headline)
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .listRowBackground(Color.clear)
}
