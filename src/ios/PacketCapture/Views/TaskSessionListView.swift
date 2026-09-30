import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LinkPresentation
import ObjectiveC
import TunnelServices

// MARK: - AirDrop icon crash workaround (iOS 16.3 CIContext/EAGLContext null pointer)
// Crash: UIAirDropActivity._activityImage → UIImage._applicationIconImageForFormat →
//   LICreateIconForImage → CIContext → CI::GLContext → null function pointer
//
// Strategy: Force-load ShareSheet.framework via dlopen, then swizzle
// UIAirDropActivity._activityImage to return a safe UIImage.
// Also swizzle +[CIContext _MI_sharedIconCompositorContext] as secondary defense.
private func performAirDropSwizzle() {
    // 1) Swizzle CIContext._MI_sharedIconCompositorContext (secondary defense)
    let ciSel = NSSelectorFromString("_MI_sharedIconCompositorContext")
    if let origCIMethod = class_getClassMethod(CIContext.self, ciSel),
       let swizzledCIMethod = class_getClassMethod(CIContext.self, #selector(CIContext.ph_safeIconContext)) {
        method_exchangeImplementations(origCIMethod, swizzledCIMethod)
        NSLog("[AirDropFix] Swizzled CIContext._MI_sharedIconCompositorContext")
    }

    // 2) Force-load ShareSheet.framework so UIAirDropActivity class is available
    dlopen("/System/Library/PrivateFrameworks/ShareSheet.framework/ShareSheet", RTLD_NOW)

    // 3) Swizzle UIAirDropActivity._activityImage (primary defense)
    guard let airdropClass = NSClassFromString("UIAirDropActivity") else {
        NSLog("[AirDropFix] UIAirDropActivity class not found after dlopen")
        return
    }
    let activityImageSel = NSSelectorFromString("_activityImage")
    guard let origMethod = class_getInstanceMethod(airdropClass, activityImageSel) else {
        // Try activityImage (public property) as fallback
        let pubSel = NSSelectorFromString("activityImage")
        guard let pubMethod = class_getInstanceMethod(airdropClass, pubSel) else {
            NSLog("[AirDropFix] Neither _activityImage nor activityImage found")
            return
        }
        // Replace implementation directly
        let newIMP: @convention(block) (AnyObject) -> UIImage? = { _ in
            return UIImage(systemName: "airdrop")
        }
        let imp = imp_implementationWithBlock(newIMP)
        method_setImplementation(pubMethod, imp)
        NSLog("[AirDropFix] Replaced activityImage via method_setImplementation")
        return
    }
    // Replace _activityImage implementation directly (no swizzle exchange needed)
    let newIMP: @convention(block) (AnyObject) -> UIImage? = { _ in
        return UIImage(systemName: "airdrop")
    }
    let imp = imp_implementationWithBlock(newIMP)
    method_setImplementation(origMethod, imp)
    NSLog("[AirDropFix] Replaced _activityImage via method_setImplementation")
}

private var airDropSwizzleDone = false

extension CIContext {
    // Secondary defense: if somehow CIContext icon compositor is still called,
    // return a pre-existing shared context (avoid creating new one)
    @objc class func ph_safeIconContext() -> CIContext? {
        return nil // caller should handle nil gracefully
    }
}

private enum TaskSessionTopTab: String, CaseIterable, Identifiable {
    case capture = "抓包记录"
    case logs = "日志记录"

    var id: String { rawValue }
}

private enum SchemeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case http = "http"
    case https = "https"
    case ws = "ws(s)"
    case tcp = "tcp"
    case udp = "udp"

    var id: String { rawValue }
}

private struct TaskSessionFilter {
    static let methodOptions = ["全部", "CONNECT", "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
    static let statusOptions = ["全部", "200", "301", "302", "400", "401", "403", "404", "500", "502"]
    static let contentTypeOptions = ["全部", "Text", "Image", "Audio", "Video", "Compress", "二进制"]

    var scheme: SchemeFilter = .all
    var method: String = "全部"
    var statusCode: String = "全部"
    var contentType: String = "全部"
    var hideLocalIP: Bool = true

    mutating func reset() {
        scheme = .all
        method = "全部"
        statusCode = "全部"
        contentType = "全部"
        hideLocalIP = true
    }

    var sqlParams: [String: [String]] {
        var params: [String: [String]] = [:]

        if method != "全部" {
            params["methods"] = [method.lowercased()]
        }

        if statusCode != "全部" {
            params["state"] = [statusCode]
        }

        switch scheme {
        case .http:
            params["schemes"] = ["http"]
        case .https:
            params["schemes"] = ["https"]
        case .tcp:
            params["schemes"] = ["tcp"]
        case .udp:
            params["schemes"] = ["udp"]
        default:
            break
        }

        return params
    }

    func matches(_ session: Session) -> Bool {
        if hideLocalIP, sessionIsLocal(session) {
            return false
        }

        guard matchesScheme(session) else {
            return false
        }

        if method != "全部", (session.methods ?? "").uppercased() != method {
            return false
        }

        if statusCode != "全部", (session.state ?? "") != statusCode {
            return false
        }

        return matchesContentType(session)
    }

    private func matchesScheme(_ session: Session) -> Bool {
        let scheme = (session.schemes ?? "").lowercased()
        let note = (session.note ?? "").lowercased()

        switch self.scheme {
        case .all:
            return true
        case .http:
            return scheme == "http"
        case .https:
            return scheme == "https"
        case .ws:
            return scheme == "ws" || scheme == "wss" || note.contains("websocket") || note.contains("upgrade")
        case .tcp:
            return scheme == "tcp" || scheme == "tcps"
        case .udp:
            return scheme == "udp" || scheme == "udps"
        }
    }

    private func matchesContentType(_ session: Session) -> Bool {
        if contentType == "全部" {
            return true
        }

        let type = session.rspType.lowercased()
        if type.isEmpty {
            return false
        }

        switch contentType {
        case "Text":
            return isTextType(type)
        case "Image":
            return type.contains("image/")
        case "Audio":
            return type.contains("audio/")
        case "Video":
            return type.contains("video/")
        case "Compress":
            return isCompressType(type)
        case "二进制":
            if type.contains("octet-stream") {
                return true
            }
            return type.contains("application/")
                && !isTextType(type)
                && !type.contains("image/")
                && !type.contains("audio/")
                && !type.contains("video/")
                && !isCompressType(type)
        default:
            return true
        }
    }

    private func isTextType(_ type: String) -> Bool {
        type.contains("text/")
            || type.contains("json")
            || type.contains("xml")
            || type.contains("html")
            || type.contains("javascript")
            || type.contains("css")
    }

    private func isCompressType(_ type: String) -> Bool {
        type.contains("gzip")
            || type.contains("compress")
            || type.contains("zip")
            || type.contains("tar")
            || type.contains("rar")
            || type.contains("7z")
            || type.contains("bzip")
    }

    private func isLocalIP(_ host: String) -> Bool {
        // 提取纯 IP（去掉端口号）
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return false }
        // 处理 "ip:port" 格式
        if let colonRange = h.range(of: ":", options: .backwards), !h.contains("::") {
            h = String(h[h.startIndex..<colonRange.lowerBound])
        }
        // 127.x.x.x
        if h.hasPrefix("127.") { return true }
        // 10.x.x.x
        if h.hasPrefix("10.") { return true }
        // 192.168.x.x
        if h.hasPrefix("192.168.") { return true }
        // PacketTunnel virtual subnet (not RFC1918, but local for this app)
        if h.hasPrefix("192.169.89.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        // localhost
        if h == "localhost" { return true }
        // ::1, fe80::
        if h == "::1" || h.hasPrefix("fe80:") { return true }
        // 169.254.x.x (link-local)
        if h.hasPrefix("169.254.") { return true }
        // 0.0.0.0
        if h == "0.0.0.0" { return true }
        return false
    }

    private func isTransportSession(_ session: Session) -> Bool {
        let scheme = (session.schemes ?? "").lowercased()
        return scheme == "tcp" || scheme == "tcps" || scheme == "udp" || scheme == "udps"
    }

    private func isLikelyDNSNoise(_ session: Session) -> Bool {
        let scheme = (session.schemes ?? "").lowercased()
        guard scheme == "udp" || scheme == "udps" else {
            return false
        }

        let proto = session.protoDetail.lowercased()
        let isDNS = proto.contains("dns") || destinationPort(session) == 53
        guard isDNS else {
            return false
        }

        let sourceIP = normalizedHost(session.srcIP)
        if sourceIP.isEmpty {
            return false
        }

        // Most outbound sessions share the same source IP; hide only DNS noise from local/tunnel IP.
        return isLocalIP(sourceIP)
    }

    private func destinationPort(_ session: Session) -> Int? {
        let rawPort = session.dstPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Int(rawPort), parsed > 0 {
            return parsed
        }
        return portFromAddress(session.remoteAddress)
    }

    private func portFromAddress(_ address: String?) -> Int? {
        guard var value = address?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("["),
           let rightBracket = value.lastIndex(of: "]"),
           rightBracket < value.endIndex {
            let tail = value[value.index(after: rightBracket)...]
            if tail.hasPrefix(":") {
                return Int(tail.dropFirst())
            }
            return nil
        }
        if let index = value.lastIndex(of: ":") {
            value = String(value[value.index(after: index)...])
            return Int(value)
        }
        return nil
    }

    private func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["),
           let rightBracket = value.lastIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<rightBracket])
        }
        if let colonRange = value.range(of: ":", options: .backwards), !value.contains("::") {
            value = String(value[value.startIndex..<colonRange.lowerBound])
        }
        return value
    }

    /// 判断 session 的目标地址是否为本地/私有 IP
    private func sessionIsLocal(_ session: Session) -> Bool {
        if isLikelyDNSNoise(session) {
            return true
        }

        if isTransportSession(session) {
            // For TCP/UDP keep outbound sessions by default; only filter truly local targets.
            if isLocalIP(session.dstIP) { return true }
            if isLocalIP(session.remoteAddress ?? "") { return true }
            return false
        }

        // 检查 host 字段（HTTP/HTTPS 用）
        if isLocalIP(session.host ?? "") { return true }
        // 检查 remoteAddress 字段（备用）
        if isLocalIP(session.remoteAddress ?? "") { return true }
        return false
    }
}

struct TaskSessionListView: View {
    let task: TunnelServices.Task

    @StateObject private var viewModel: TaskSessionListViewModel
    @State private var selectedTopTab: TaskSessionTopTab = .capture
    @State private var searchText = ""

    @State private var appliedFilter = TaskSessionFilter()
    @State private var draftFilter = TaskSessionFilter()
    @State private var showFilterSheet = false

    @State private var isSelectionMode = false
    @State private var selectedSessionIDs: Set<String> = []

    init(task: TunnelServices.Task) {
        self.task = task
        _viewModel = StateObject(wrappedValue: TaskSessionListViewModel(task: task))
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("类型", selection: $selectedTopTab) {
                ForEach(TaskSessionTopTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            searchBar

            if selectedTopTab == .capture {
                sessionList
            } else {
                EmptyStateView(
                    title: "暂无日志",
                    systemImage: "doc.text",
                    message: "日志记录功能暂未实现"
                )
                .padding(.top, 36)

                Spacer()
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelectionMode {
                    Button("取消") {
                        exitSelectionMode()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if isSelectionMode {
                    Button("全选") {
                        selectAllSessions()
                    }
                } else {
                    Button("选择") {
                        enterSelectionMode()
                    }
                }
            }
        }
        .onAppear {
            reloadSessions()
        }
        .onChange(of: selectedTopTab) { newValue in
            if newValue == .capture {
                reloadSessions()
            } else {
                exitSelectionMode()
            }
        }
        .onChange(of: searchText) { _ in
            if selectedTopTab == .capture {
                reloadSessions()
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            filterSheet
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                selectionBottomBar
            }
        }
    }

    private var navigationTitleText: String {
        if isSelectionMode {
            return "已选\(selectedSessionIDs.count)项"
        }
        let name = task.ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.lowercased() == "default" {
            return "全局抓包"
        }
        return name
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                draftFilter = appliedFilter
                showFilterSheet = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSelectionMode)
        }
        .padding(.horizontal, 16)
    }

    private var sessionList: some View {
        List {
            if viewModel.sessions.isEmpty {
                EmptyStateView(
                    title: "暂无会话",
                    systemImage: "tray",
                    message: "该任务下暂无抓包记录"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.sessions, id: \.id) { session in
                    if isSelectionMode {
                        Button {
                            toggleSelection(for: session)
                        } label: {
                            TaskSessionRowView(
                                session: session,
                                showSelection: true,
                                isSelected: selectedSessionIDs.contains(sessionIdentifier(session))
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.visible)
                    } else {
                        NavigationLink(destination: SessionDetailView(session: session)) {
                            TaskSessionRowView(session: session)
                        }
                        .listRowSeparator(.visible)
                    }
                }
                .onDelete { offsets in
                    viewModel.deleteSessions(at: offsets)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            reloadSessions()
        }
    }

    private var filterSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("协议类型")
                            .font(.headline)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(SchemeFilter.allCases) { item in
                                    Button {
                                        draftFilter.scheme = item
                                    } label: {
                                        Text(item.rawValue)
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .foregroundStyle(draftFilter.scheme == item ? Color.white : Color.primary)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(draftFilter.scheme == item ? Color.accentColor : Color(.secondarySystemBackground))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        Divider()

                        menuRow(title: "请求方法", selection: $draftFilter.method, options: TaskSessionFilter.methodOptions)
                        menuRow(title: "状态码", selection: $draftFilter.statusCode, options: TaskSessionFilter.statusOptions)
                        menuRow(title: "内容类型", selection: $draftFilter.contentType, options: TaskSessionFilter.contentTypeOptions)

                        Divider()

                        Toggle("隐藏本地 IP", isOn: $draftFilter.hideLocalIP)
                    }
                    .padding(16)
                }

                HStack(spacing: 12) {
                    Button {
                        draftFilter.reset()
                    } label: {
                        Text("重置")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        appliedFilter = draftFilter
                        showFilterSheet = false
                        reloadSessions()
                    } label: {
                        Text("确认")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .navigationTitle("修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        showFilterSheet = false
                    }
                }
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                shareSelectedSessions()
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedSessionIDs.isEmpty ? Color.gray.opacity(0.25) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedSessionIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private func menuRow(title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) {
                        selection.wrappedValue = option
                    }
                }
            } label: {
                Text(selection.wrappedValue == "全部" ? "请选择 >" : "\(selection.wrappedValue) >")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reloadSessions() {
        viewModel.reload(searchText: searchText, filter: appliedFilter)
        syncSelectionWithCurrentList()
    }

    private func enterSelectionMode() {
        isSelectionMode = true
        selectedSessionIDs.removeAll()
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedSessionIDs.removeAll()
    }

    private func selectAllSessions() {
        selectedSessionIDs = Set(viewModel.sessions.map(sessionIdentifier(_:)))
    }

    private func toggleSelection(for session: Session) {
        let id = sessionIdentifier(session)
        if selectedSessionIDs.contains(id) {
            selectedSessionIDs.remove(id)
        } else {
            selectedSessionIDs.insert(id)
        }
    }

    private func syncSelectionWithCurrentList() {
        guard isSelectionMode else {
            return
        }
        let validIDs = Set(viewModel.sessions.map(sessionIdentifier(_:)))
        selectedSessionIDs.formIntersection(validIDs)
    }

    private func shareSelectedSessions() {
        // Perform AirDrop icon crash swizzle (once)
        if !airDropSwizzleDone {
            performAirDropSwizzle()
            airDropSwizzleDone = true
        }

        let selected = viewModel.sessions.filter { selectedSessionIDs.contains(sessionIdentifier($0)) }
        guard !selected.isEmpty else {
            return
        }

        let text = selected.enumerated().map { index, session in
            shareLine(for: session, index: index + 1)
        }.joined(separator: "\n\n--------------------\n\n")

        // Write to App Group container (system /tmp is not writable on TrollStore)
        let fileName = "PacketHound_\(UUID().uuidString.prefix(8)).txt"
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.packethound.app") else {
            NSLog("[Share] App Group container unavailable")
            return
        }
        let exportDir = groupURL.appendingPathComponent("ShareExport", isDirectory: true)
        let fileURL = exportDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Share] failed to write file: %@", error.localizedDescription)
            return
        }

        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            else {
                NSLog("[Share] no key window found")
                try? FileManager.default.removeItem(at: fileURL)
                return
            }

            var presenter = rootVC
            while let presentedVC = presenter.presentedViewController {
                presenter = presentedVC
            }

            let itemSource = TextFileActivityItemSource(fileURL: fileURL, subject: "抓包数据导出", title: fileName)
            let activityVC = UIActivityViewController(activityItems: [itemSource], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: fileURL)
            }

            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.maxY - 40,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }

            guard presenter.presentedViewController == nil else {
                NSLog("[Share] presenter is busy")
                try? FileManager.default.removeItem(at: fileURL)
                return
            }

            presenter.present(activityVC, animated: true)
        }
    }

    private func shareLine(for session: Session, index: Int) -> String {
        let requestHeaders = headersText(from: session.reqHeads)
        let responseHeaders = headersText(from: session.rspHeads)
        let requestSize = formatBytes(session.getBodySize(true))
        let responseSize = formatBytes(session.getBodySize(false))

        return """
        [\(index)]
        URL: \(safeURL(for: session))
        Method: \((session.methods ?? "-").uppercased())
        Status: \(session.state ?? "-")
        Request Headers:
        \(requestHeaders)
        Response Headers:
        \(responseHeaders)
        Body Size: request=\(requestSize), response=\(responseSize)
        """
    }

    private func headersText(from json: String?) -> String {
        let pairs = parseHeaders(from: json)
        if pairs.isEmpty {
            return "(none)"
        }
        return pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private func parseHeaders(from json: String?) -> [(String, String)] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return []
        }

        if let map = object as? [String: Any] {
            return map.keys.sorted().map { key in
                (key, "\(map[key] ?? "")")
            }
        }

        if let array = object as? [[String: Any]] {
            var result: [(String, String)] = []
            for item in array {
                if let key = item["key"] as? String {
                    result.append((key, "\(item["value"] ?? "")"))
                } else {
                    for (key, value) in item {
                        result.append((key, "\(value)"))
                    }
                }
            }
            return result
        }

        return []
    }

    private func sessionIdentifier(_ session: Session) -> String {
        if let id = session.id?.stringValue {
            return id
        }
        let timestamp = session.startTime?.doubleValue ?? 0
        return "\(timestamp)-\(safeURL(for: session))"
    }

    private func safeURL(for session: Session) -> String {
        let url = session.getFullUrl()
        if !url.isEmpty {
            return url
        }
        return session.uri ?? "(empty URL)"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let value = max(0, Double(bytes))
        if value < 1024 {
            return "\(Int(value))B"
        }

        let units = ["KB", "MB", "GB", "TB"]
        var size = value / 1024
        var unitIndex = 0

        while size >= 1024, unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }

        if size >= 100 {
            return String(format: "%.0f%@", size, units[unitIndex])
        }
        return String(format: "%.1f%@", size, units[unitIndex])
    }

}

private struct TaskSessionRowView: View {
    let session: Session
    var showSelection: Bool = false
    var isSelected: Bool = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showSelection {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("#\(session.id?.stringValue ?? "-")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(badgeText)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text(session.state ?? "-")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusColor)

                    Spacer()

                    Text(timestampText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("↑\(formatBytes(session.uploadTraffic.int64Value)) ↓\(formatBytes(session.downloadFlow.int64Value))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(fullURL)
                    .font(.subheadline)
                    .foregroundStyle(isTransportSession ? Color.primary : Color.blue)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isTransportSession {
                    Text(protoDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var fullURL: String {
        if isTransportSession {
            return endpointSummary
        }
        let url = session.getFullUrl()
        if !url.isEmpty {
            return url
        }
        return session.uri ?? "(empty URL)"
    }

    private var isTransportSession: Bool {
        let scheme = (session.schemes ?? "").uppercased()
        return scheme == "TCP" || scheme == "UDP"
    }

    private var endpointSummary: String {
        let scheme = (session.schemes ?? "").uppercased()
        let source = endpoint(ip: session.srcIP, port: session.srcPort, fallback: session.localAddress)
        let destination = endpoint(ip: session.dstIP, port: session.dstPort, fallback: session.remoteAddress)
        return "[\(scheme)] \(source) \u{2192} \(destination)"
    }

    private var badgeText: String {
        if isTransportSession {
            return (session.schemes ?? "-").uppercased()
        }
        return (session.methods ?? "-").uppercased()
    }

    private var badgeColor: Color {
        let scheme = (session.schemes ?? "").uppercased()
        switch scheme {
        case "HTTP":
            return .blue
        case "HTTPS":
            return .green
        case "TCP":
            return .orange
        case "UDP":
            return .purple
        default:
            return methodBadgeColor
        }
    }

    private var protoDetailText: String {
        let detail = session.protoDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "协议: -"
        }
        return "协议: \(detail)"
    }

    private func endpoint(ip: String, port: String, fallback: String?) -> String {
        if !ip.isEmpty || !port.isEmpty {
            return "\(ip.isEmpty ? "-" : ip):\(port.isEmpty ? "-" : port)"
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        return "-"
    }

    private var timestampText: String {
        guard let timestamp = session.startTime?.doubleValue, timestamp > 0 else {
            return "-"
        }
        return Self.timeFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private var methodBadgeColor: Color {
        switch (session.methods ?? "").uppercased() {
        case "GET":
            return .green
        case "POST":
            return .blue
        case "PUT":
            return .orange
        case "DELETE":
            return .red
        case "CONNECT":
            return .gray
        default:
            return .gray
        }
    }

    private var statusColor: Color {
        let value = Int(session.state ?? "") ?? 0
        switch value {
        case 200 ..< 300:
            return .green
        case 400 ..< 500:
            return .orange
        case 500 ... 999:
            return .red
        default:
            return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let value = max(0, Double(bytes))
        if value < 1024 {
            return "\(Int(value))B"
        }

        let units = ["KB", "MB", "GB", "TB"]
        var size = value / 1024
        var unitIndex = 0

        while size >= 1024, unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }

        if size >= 100 {
            return String(format: "%.0f%@", size, units[unitIndex])
        }
        return String(format: "%.1f%@", size, units[unitIndex])
    }
}

@MainActor
private final class TaskSessionListViewModel: ObservableObject {
    let task: TunnelServices.Task

    @Published var sessions: [Session] = []
    
    private var dataChangeObserver: NSObjectProtocol?
    private var lastSearchText = ""
    private var lastFilter = TaskSessionFilter()

    init(task: TunnelServices.Task) {
        self.task = task
        dataChangeObserver = NotificationCenter.default.addObserver(
            forName: PacketHoundDataStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reload(searchText: self.lastSearchText, filter: self.lastFilter)
        }
    }
    
    deinit {
        if let dataChangeObserver {
            NotificationCenter.default.removeObserver(dataChangeObserver)
        }
    }

    func reload(searchText: String, filter: TaskSessionFilter) {
        lastSearchText = searchText
        lastFilter = filter
        
        PacketHoundDataStore.shared.configureIfNeeded()
        PacketHoundDataStore.shared.checkpoint()

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = filter.sqlParams

        NSLog("[PH-DEBUG] reload: taskID=%@ keyword='%@' params=%@",
              task.id?.stringValue ?? "nil", keyword, "\(params)")

        var fetched = Session.findAll(
            taskID: task.id?.stringValue,
            keyWord: keyword.isEmpty ? nil : keyword,
            params: params.isEmpty ? nil : params,
            pageSize: 5_000,
            pageIndex: 0,
            orderBy: "startTime"
        )

        NSLog("[PH-DEBUG] reload: fetched %d sessions from DB, after filter %d",
              fetched.count, fetched.filter { filter.matches($0) }.count)

        fetched = fetched.filter { filter.matches($0) }
        sessions = fetched
    }

    func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            guard sessions.indices.contains(index) else { continue }
            let session = sessions[index]
            // 删除关联的抓包文件
            if let folder = session.fileFolder, !folder.isEmpty {
                let path = MitmService.getStoreFolder() + folder
                try? FileManager.default.removeItem(atPath: path)
            }
            // 删除关联的 WSFrame
            if let sessionID = session.id {
                let frames = WSFrame.frames(sessionID: sessionID)
                frames.forEach { try? $0.delete() }
            }
            try? session.delete()
        }
        sessions.remove(atOffsets: offsets)
    }
}

private final class TextFileActivityItemSource: NSObject, UIActivityItemSource {
    private let fileURL: URL
    private let subject: String
    private let title: String

    init(fileURL: URL, subject: String, title: String) {
        self.fileURL = fileURL
        self.subject = subject
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        title as NSString
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.plainText.identifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
        suggestedSize size: CGSize
    ) -> UIImage? {
        UIImage(named: "AppIcon60x60")
            ?? UIImage(systemName: "doc.text")
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = fileURL
        metadata.url = fileURL
        if let icon = UIImage(named: "AppIcon60x60")
            ?? UIImage(systemName: "doc.text") {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}
