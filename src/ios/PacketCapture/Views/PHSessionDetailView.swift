import SwiftUI
import UIKit
import TunnelServices

private enum SessionDetailTab: String, CaseIterable, Identifiable {
    case preview = "预览"
    case request = "请求"
    case response = "响应"
    case logs = "日志记录"

    var id: String { rawValue }
}

struct SessionDetailView: View {
    let session: Session

    @State private var selectedTab: SessionDetailTab = .preview
    @State private var toastMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tabSelector

                switch selectedTab {
                case .preview:
                    previewSection
                case .request:
                    requestSection
                case .response:
                    responseSection
                case .logs:
                    logsSection
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("会话详情")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(toastMessage)
            }
        }
    }

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(SessionDetailTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isTransportSession {
                detailCard(title: "预览") {
                    detailRow("协议类型", value: transportProtocol)
                    detailRow("源地址", value: transportSourceEndpoint)
                    detailRow("目标地址", value: transportDestinationEndpoint)
                    detailRow("协议详情", value: transportProtoDetail)
                    detailRow("上传流量", value: formatBytes(session.uploadTraffic.int64Value))
                    detailRow("下载流量", value: formatBytes(session.downloadFlow.int64Value))
                    detailRow("连接状态", value: connectionStateText)
                    detailRow("开始时间", value: formattedDate(session.startTime))
                    detailRow("连接时间", value: formattedDate(session.connectTime))
                    detailRow("结束时间", value: formattedDate(session.endTime))
                    detailRow("总耗时", value: durationText(from: session.startTime, to: session.endTime))
                }
            } else {
                detailCard(title: "预览") {
                    urlRow
                    detailRow("客户端地址", value: session.localAddress ?? "-")
                    detailRow("服务端地址", value: session.remoteAddress ?? "-")
                    detailRow("上传流量", value: formatBytes(session.uploadTraffic.int64Value))
                    detailRow("下载流量", value: formatBytes(session.downloadFlow.int64Value))
                    detailRow("排队时间", value: durationText(from: session.startTime, to: session.connectTime))
                    detailRow("DNS解析", value: dnsResolveText)
                    detailRow("连接时间", value: durationText(from: session.connectTime, to: session.connectedTime))
                    detailRow("TLS握手", value: tlsHandshakeText)
                    detailRow("数据传输", value: durationText(from: session.rspStartTime, to: session.rspEndTime))
                    detailRow("总耗时", value: durationText(from: session.startTime, to: session.rspEndTime))
                    detailRow("长连接", value: keepAliveText)
                }
            }

            if isWebSocketSession, let sessionID = session.id {
                NavigationLink(destination: WebSocketDetailView(sessionID: sessionID, sessionFolder: session.fileFolder)) {
                    HStack {
                        Text("查看 WebSocket 帧")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var requestSection: some View {
        if isTransportSession {
            transportPayloadSection(isRequest: true)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                lineCard(title: "请求行", line: requestLineText)
                headersCard(title: "请求头", headers: requestHeaders, copyMessage: "已复制请求头")
                payloadCard(
                    title: "请求体",
                    bodyData: session.getDecodedBody(true),
                    contentType: session.reqType,
                    byteCount: session.getBodySize(true)
                )
            }
        }
    }

    @ViewBuilder
    private var responseSection: some View {
        if isTransportSession {
            transportPayloadSection(isRequest: false)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                lineCard(title: "状态行", line: responseLineText)
                headersCard(title: "响应头", headers: responseHeaders, copyMessage: "已复制响应头")
                payloadCard(
                    title: "消息体",
                    bodyData: session.getDecodedBody(false),
                    contentType: session.rspType,
                    byteCount: session.getBodySize(false)
                )
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailCard(title: "时间线") {
                ForEach(Array(timelineEvents.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                            Text(formattedDate(item.value))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(offsetText(item.value))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if index < timelineEvents.count - 1 {
                        Divider()
                    }
                }
            }

            if let note = session.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detailCard(title: "备注") {
                    Text(note)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var urlRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("URL")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(fullURL)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)

            Button {
                copyToPasteboard(fullURL, message: "已复制 URL")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func detailCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func panelCard<Content: View>(
        title: String,
        onCopy: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let onCopy {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func lineCard(title: String, line: String) -> some View {
        panelCard(title: title) {
            Text(line)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func headersCard(title: String, headers: [(String, String)], copyMessage: String) -> some View {
        panelCard(title: title, onCopy: {
            copyToPasteboard(headersText(from: headers), message: copyMessage)
        }) {
            if headers.isEmpty {
                Text("无请求头")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, item in
                    Text("\(item.0): \(decodeHeaderValue(item.1))")
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func transportPayloadSection(isRequest: Bool) -> some View {
        let body = session.getDecodedBody(isRequest)
        let size = session.getBodySize(isRequest)

        return VStack(alignment: .leading, spacing: 12) {
            detailCard(title: isRequest ? "请求信息" : "响应信息") {
                detailRow("协议", value: transportProtocol)
                detailRow("方向", value: isRequest ? "客户端 → 服务端" : "服务端 → 客户端")
                detailRow("大小", value: formatBytes(size))
                if isRequest, let dnsQueryDomain {
                    detailRow("DNS查询", value: dnsQueryDomain)
                }
            }

            payloadCard(
                title: isRequest ? "请求数据" : "响应数据",
                bodyData: body,
                contentType: isRequest ? session.reqType : session.rspType,
                byteCount: size
            )
        }
    }

    private func payloadCard(title: String, bodyData: Data?, contentType: String, byteCount: UInt64) -> some View {
        panelCard(title: title) {
            if let bodyData, !bodyData.isEmpty {
                NavigationLink(destination: BodyDetailView(title: title, data: bodyData, contentType: contentType)) {
                    payloadRow(text: "数据 \(formatBytes(byteCount))")
                }
                .buttonStyle(.plain)

                Divider()

                NavigationLink(destination: HexDumpView(title: "\(title) 二进制", data: bodyData)) {
                    payloadRow(text: "二进制文本")
                }
                .buttonStyle(.plain)

                Divider()

                NavigationLink(destination: HexStringView(title: "\(title) 十六进制", data: bodyData)) {
                    payloadRow(text: "十六进制字符串")
                }
                .buttonStyle(.plain)
            } else {
                let isReq = title.contains("请求")
                let bodyField = isReq ? session.reqBody : session.rspBody
                if bodyField.isEmpty {
                    Text("无请求体")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    let size = isReq ? session.getBodySize(true) : session.getBodySize(false)
                    if size == 0 {
                        // 文件名存在但文件大小为0或文件不存在，说明实际没有数据
                        Text("无请求体")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("数据读取失败")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func payloadRow(text: String) -> some View {
        HStack {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var requestHeaders: [(String, String)] {
        parsedHeaders(from: session.reqHeads)
    }

    private var responseHeaders: [(String, String)] {
        parsedHeaders(from: session.rspHeads)
    }

    private var fullURL: String {
        let url = session.getFullUrl()
        if !url.isEmpty {
            return url
        }
        return session.uri ?? "-"
    }

    private var isTransportSession: Bool {
        let scheme = (session.schemes ?? "").uppercased()
        return scheme == "TCP" || scheme == "UDP"
    }

    private var transportProtocol: String {
        let scheme = (session.schemes ?? "").uppercased()
        if scheme.isEmpty {
            return "-"
        }
        return scheme
    }

    private var transportSourceEndpoint: String {
        endpoint(ip: session.srcIP, port: session.srcPort, fallback: session.localAddress)
    }

    private var transportDestinationEndpoint: String {
        endpoint(ip: session.dstIP, port: session.dstPort, fallback: session.remoteAddress)
    }

    private var transportProtoDetail: String {
        let detail = session.protoDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "-" : detail
    }

    private var connectionStateText: String {
        let candidates = [session.sstate, session.inState, session.outState, session.state]
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                return value
            }
        }
        return "-"
    }

    private var requestLineText: String {
        if let reqLine = session.reqLine, !reqLine.isEmpty {
            return reqLine
        }

        let method = (session.methods ?? "GET").uppercased()
        let version = session.reqHttpVersion ?? "HTTP/1.1"
        return "\(method) \(requestTarget) \(version)"
    }

    private var responseLineText: String {
        let version = session.rspHttpVersion ?? "HTTP/1.1"
        let statusCode = session.state ?? "-"
        let message = session.rspMessage ?? ""
        if message.isEmpty {
            return "\(version) \(statusCode)"
        }
        return "\(version) \(statusCode) \(message)"
    }

    private var requestTarget: String {
        if let uri = session.uri, !uri.isEmpty {
            if let url = URL(string: uri), url.scheme != nil {
                let path = url.path.isEmpty ? "/" : url.path
                let query = url.query.map { "?\($0)" } ?? ""
                return path + query
            }
            return uri
        }

        if let url = URL(string: session.getFullUrl()), url.scheme != nil {
            let path = url.path.isEmpty ? "/" : url.path
            let query = url.query.map { "?\($0)" } ?? ""
            return path + query
        }

        return "/"
    }

    private var keepAliveText: String {
        guard let value = headerValue(named: "Connection", headers: responseHeaders) else {
            return "-"
        }

        let lower = value.lowercased()
        if lower.contains("keep-alive") {
            return "是"
        }
        if lower.contains("close") {
            return "否"
        }
        return value
    }

    private var dnsResolveText: String {
        // Session model currently has no dedicated DNS timestamps.
        return "-"
    }

    private var tlsHandshakeText: String {
        guard (session.schemes ?? "").lowercased() == "https" else {
            return "-"
        }
        return durationText(from: session.connectedTime, to: session.handshakeEndTime)
    }

    private var dnsQueryDomain: String? {
        guard transportProtocol == "UDP" else {
            return nil
        }

        let destinationPort = UInt16(session.dstPort) ?? 0
        let sourcePort = UInt16(session.srcPort) ?? 0
        guard destinationPort == 53 || sourcePort == 53 else {
            return nil
        }

        guard let reqData = session.getDecodedBody(true), !reqData.isEmpty else {
            return nil
        }

        return parseDNSQueryDomain(from: reqData)
    }

    private var isWebSocketSession: Bool {
        (session.note ?? "").lowercased().contains("websocket")
    }

    private var timelineEvents: [(title: String, value: NSNumber?)] {
        [
            ("开始时间", session.startTime),
            ("连接时间", session.connectTime),
            ("TLS握手完成", session.handshakeEndTime),
            ("请求发送完成", session.reqEndTime),
            ("响应开始", session.rspStartTime),
            ("响应结束", session.rspEndTime)
        ]
    }

    private func parseDNSQueryDomain(from data: Data) -> String? {
        guard data.count >= 12 else {
            return nil
        }

        let questionCount = (UInt16(data[4]) << 8) | UInt16(data[5])
        guard questionCount > 0 else {
            return nil
        }

        var index = 12
        var labels: [String] = []

        while index < data.count {
            let length = Int(data[index])
            index += 1

            if length == 0 {
                break
            }

            // Skip compressed labels for a lightweight parser.
            if (length & 0xC0) == 0xC0 {
                break
            }

            guard index + length <= data.count else {
                return nil
            }

            let labelData = data[index ..< (index + length)]
            let label = String(decoding: labelData, as: UTF8.self)
            if !label.isEmpty {
                labels.append(label)
            }

            index += length
        }

        guard !labels.isEmpty else {
            return nil
        }
        return labels.joined(separator: ".")
    }

    private func parsedHeaders(from jsonString: String?) -> [(String, String)] {
        guard
            let jsonString,
            let data = jsonString.data(using: .utf8),
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
            var pairs: [(String, String)] = []
            for item in array {
                if let key = item["key"] as? String {
                    pairs.append((key, "\(item["value"] ?? "")"))
                    continue
                }
                for (key, value) in item {
                    pairs.append((key, "\(value)"))
                }
            }
            return pairs
        }

        return []
    }

    private func headersText(from headers: [(String, String)]) -> String {
        if headers.isEmpty {
            return "(none)"
        }
        return headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private func headerValue(named name: String, headers: [(String, String)]) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    private func decodeHeaderValue(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private func durationText(from start: NSNumber?, to end: NSNumber?) -> String {
        guard let start = start?.doubleValue, let end = end?.doubleValue, start > 0, end > 0 else {
            return "-"
        }

        let value = max(0, (end - start) * 1000)
        return "\(Int(value)) ms"
    }

    private func offsetText(_ value: NSNumber?) -> String {
        guard
            let base = session.startTime?.doubleValue,
            let current = value?.doubleValue,
            base > 0,
            current > 0
        else {
            return "-"
        }

        let offset = max(0, (current - base) * 1000)
        return "+\(Int(offset))ms"
    }

    private func formattedDate(_ value: NSNumber?) -> String {
        guard let timestamp = value?.doubleValue, timestamp > 0 else {
            return "-"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let value = max(0, Double(bytes))
        if value < 1024 {
            return "\(Int(value))B"
        }

        let units = ["KB", "MB", "GB", "TB"]
        var size = value / 1024
        var index = 0

        while size >= 1024, index < units.count - 1 {
            size /= 1024
            index += 1
        }

        if size >= 100 {
            return String(format: "%.0f%@", size, units[index])
        }
        return String(format: "%.1f%@", size, units[index])
    }

    private func formatBytes(_ bytes: Int64) -> String {
        formatBytes(UInt64(max(0, bytes)))
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

    private func copyToPasteboard(_ text: String, message: String) {
        guard !text.isEmpty else {
            return
        }

        UIPasteboard.general.string = text
        showToast(message)
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct BodyDetailView: View {
    let title: String
    let data: Data
    let contentType: String

    @State private var preferPrettyJSON = true
    @State private var toastMessage: String?

    private var isJSON: Bool {
        BodyPreviewView.isJSON(data: data, contentType: contentType)
    }

    private var isText: Bool {
        BodyPreviewView.isText(data: data, contentType: contentType)
    }

    var body: some View {
        ScrollView {
            BodyPreviewView(data: data, contentType: contentType, preferPrettyJSON: preferPrettyJSON)
                .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing: trailingButtons)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(toastMessage)
            }
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: 12) {
            if isJSON {
                Button(preferPrettyJSON ? "原始" : "格式化") {
                    preferPrettyJSON.toggle()
                }
            }

            copyButton
        }
    }

    private var copyButton: some View {
        Button {
            if let text = BodyPreviewView.copyableText(data: data, contentType: contentType, preferPrettyJSON: preferPrettyJSON) {
                UIPasteboard.general.string = text
                showToast("已复制内容")
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct HexDumpView: View {
    let title: String
    let data: Data

    @State private var toastMessage: String?

    var body: some View {
        ScrollView {
            Text(BodyPreviewView.hexDumpText(data: data))
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = BodyPreviewView.hexDumpText(data: data)
                    showToast("已复制十六进制")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(toastMessage)
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct HexStringView: View {
    let title: String
    let data: Data

    @State private var toastMessage: String?

    private var hexText: String {
        BodyPreviewView.hexStringText(data: data)
    }

    var body: some View {
        ScrollView {
            Text(hexText)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = hexText
                    showToast("已复制十六进制")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(toastMessage)
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct BodyPreviewView: View {
    enum Kind {
        case empty
        case json(String)
        case text(String)
        case image(UIImage)
        case hex(String)
        case hexString(String)  // pure hex string like "48 65 6C 6C 6F"
    }

    let data: Data?
    let contentType: String
    var preferPrettyJSON: Bool = true

    private var display: Kind {
        Self.resolveKind(data: data, contentType: contentType, preferPrettyJSON: preferPrettyJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch display {
            case .empty:
                Text("无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .json(let json):
                Text(json)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            case .text(let text):
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            case .image(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .hex(let value):
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 120, alignment: .top)
            case .hexString(let value):
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 60, alignment: .top)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func isJSON(data: Data?, contentType: String) -> Bool {
        guard let data, !data.isEmpty else {
            return false
        }
        return contentType.lowercased().contains("json") || looksLikeJSON(data)
    }

    static func isText(data: Data?, contentType: String) -> Bool {
        guard let data, !data.isEmpty else {
            return false
        }

        if contentType.lowercased().starts(with: "image/") {
            return false
        }

        if isHumanReadableContentType(contentType) {
            return true
        }

        if let text = String(data: data, encoding: .utf8), looksLikeText(text) {
            return true
        }

        if let text = String(data: data, encoding: .isoLatin1), looksLikeText(text) {
            return true
        }

        return false
    }

    static func copyableText(data: Data?, contentType: String, preferPrettyJSON: Bool) -> String? {
        switch resolveKind(data: data, contentType: contentType, preferPrettyJSON: preferPrettyJSON) {
        case .json(let value), .text(let value), .hex(let value), .hexString(let value):
            return value
        case .empty, .image:
            return nil
        }
    }

    static func hexDumpText(data: Data?) -> String {
        guard let data, !data.isEmpty else {
            return ""
        }
        return hexDump(data: data)
    }

    static func hexStringText(data: Data?) -> String {
        guard let data, !data.isEmpty else {
            return ""
        }
        let bytes = [UInt8](data.prefix(8192))
        var result = bytes.map { String(format: "%02x", $0) }.joined()
        if data.count > bytes.count {
            result += "\n... truncated ..."
        }
        return result
    }

    private static func resolveKind(data: Data?, contentType: String, preferPrettyJSON: Bool) -> Kind {
        guard let data, !data.isEmpty else {
            return .empty
        }

        if contentType.lowercased().starts(with: "image/"), let image = UIImage(data: data) {
            return .image(image)
        }

        if isJSON(data: data, contentType: contentType) {
            if let object = try? JSONSerialization.jsonObject(with: data, options: []) {
                let options: JSONSerialization.WritingOptions = preferPrettyJSON ? [.prettyPrinted] : []
                if let rendered = try? JSONSerialization.data(withJSONObject: object, options: options),
                   let text = String(data: rendered, encoding: .utf8) {
                    return .json(text)
                }
            }

            if let rawText = String(data: data, encoding: .utf8) {
                return .json(rawText)
            }
        }

        // Try UTF-8 first
        if let text = String(data: data, encoding: .utf8) {
            // For known readable types or text that looks printable, show as text
            if isHumanReadableContentType(contentType) || looksLikeText(text) {
                return .text(text)
            }
        }

        // Fall back to Latin1 (ISO-8859-1) which can decode ANY byte sequence - shows garbled for non-Latin but never fails
        if let text = String(data: data, encoding: .isoLatin1) {
            if isHumanReadableContentType(contentType) || looksLikeText(text) {
                return .text(text)
            }
        }

        return .hex(hexDump(data: data))
    }

    private static func isHumanReadableContentType(_ contentType: String) -> Bool {
        let lower = contentType.lowercased()
        if lower.starts(with: "text/") { return true }
        let readablePatterns = [
            "json", "xml", "html", "javascript", "ecmascript",
            "css", "csv", "yaml", "yml", "toml",
            "x-www-form-urlencoded", "soap", "graphql",
            "svg", "rss", "atom", "markdown", "plain"
        ]
        return readablePatterns.contains { lower.contains($0) }
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(1), encoding: .utf8) else {
            return false
        }
        return text == "{" || text == "["
    }

    private static func looksLikeText(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }

        let scalarCount = text.unicodeScalars.count
        let printableCount = text.unicodeScalars.filter { scalar in
            CharacterSet.controlCharacters.inverted.contains(scalar)
                || scalar == "\n"
                || scalar == "\r"
                || scalar == "\t"
        }.count

        return Double(printableCount) / Double(scalarCount) > 0.85
    }

    private static func hexDump(data: Data) -> String {
        let bytes = [UInt8](data.prefix(4096))
        guard !bytes.isEmpty else {
            return ""
        }

        var lines: [String] = []
        for index in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[index ..< min(index + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { byte -> String in
                let scalar = UnicodeScalar(byte)
                if scalar.isASCII && scalar.value >= 32 && scalar.value < 127 {
                    return String(Character(scalar))
                }
                return "."
            }.joined()
            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            lines.append(String(format: "%04X  %@  %@", index, paddedHex, ascii))
        }

        if data.count > bytes.count {
            lines.append("... truncated ...")
        }

        return lines.joined(separator: "\n")
    }
}
