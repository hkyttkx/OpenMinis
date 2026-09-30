// PH3模式不需要此文件，已禁用编译
#if false
import SwiftUI
import TunnelServices

struct TCPFrameDetailView: View {
    let sessionID: NSNumber
    let sessionFolder: String?

    @StateObject private var viewModel = TCPFrameDetailViewModel()
    @State private var expandedFrameIDs: Set<String> = []

    init(sessionID: NSNumber, sessionFolder: String? = nil) {
        self.sessionID = sessionID
        self.sessionFolder = sessionFolder
    }

    var body: some View {
        List {
            if viewModel.frames.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("暂无 TCP 帧")
                            .font(.headline)
                        Text("捕获 TCP 流量后帧数据将显示在此处")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.frames, id: \.frameStableID) { frame in
                    frameRow(frame)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("TCP Frames")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            viewModel.reload(sessionID: sessionID)
        }
        .onAppear {
            viewModel.reload(sessionID: sessionID)
        }
    }

    private func frameRow(_ frame: TCPFrame) -> some View {
        let frameID = frame.frameStableID
        let expanded = expandedFrameIDs.contains(frameID)
        let style = FrameStyle(contentType: frame.contentType)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(directionSymbol(for: frame.direction))
                    .font(.headline)
                    .foregroundStyle(directionColor(for: frame.direction))

                Text("#\(frame.idx.intValue)")
                    .font(.subheadline.weight(.semibold))

                Text(style.label)
                    .font(.caption.bold())
                    .foregroundStyle(style.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(style.tint.opacity(0.15))
                    .clipShape(Capsule())

                Spacer()

                Text(formatBytes(UInt64(max(0, frame.size.int64Value))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(timestampText(frame.timestamp.doubleValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(previewPayload(for: frame))
                .font(.footnote.monospaced())
                .foregroundStyle(style.payloadColor)
                .lineLimit(expanded ? nil : 4)

            Button(expanded ? "收起" : "展开") {
                toggleExpanded(id: frameID)
            }
            .font(.caption.bold())
        }
        .padding(.vertical, 4)
    }

    private func toggleExpanded(id: String) {
        if expandedFrameIDs.contains(id) {
            expandedFrameIDs.remove(id)
        } else {
            expandedFrameIDs.insert(id)
        }
    }

    private func previewPayload(for frame: TCPFrame) -> String {
        if !frame.payload.isEmpty {
            return frame.payload
        }

        if let data = loadPayloadData(for: frame) {
            if frame.contentType.lowercased() == TCPContentType.binary.rawValue {
                return hexDump(from: data)
            }
            if frame.contentType.lowercased() == TCPContentType.tls.rawValue {
                return "[TLS Record - \(data.count) bytes]"
            }
            return String(data: data, encoding: .utf8) ?? hexDump(from: data)
        }

        if frame.contentType.lowercased() == TCPContentType.binary.rawValue {
            return "(binary data)"
        }

        return "(empty payload)"
    }

    private func loadPayloadData(for frame: TCPFrame) -> Data? {
        guard !frame.payload_file.isEmpty else {
            return nil
        }

        if let sessionFolder {
            let path = "\(MitmService.getStoreFolder())\(sessionFolder)/\(frame.payload_file)"
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }

        if let session = Session.findAll(["id": sessionID]).first,
           let folder = session.fileFolder {
            let path = "\(MitmService.getStoreFolder())\(folder)/\(frame.payload_file)"
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }

        return nil
    }

    private func directionSymbol(for direction: String) -> String {
        direction.lowercased() == "send" ? "↑" : "↓"
    }

    private func directionColor(for direction: String) -> Color {
        direction.lowercased() == "send" ? .green : .blue
    }

    private func timestampText(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
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

    private func hexDump(from data: Data) -> String {
        if data.isEmpty {
            return "(empty payload)"
        }

        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0

        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset ..< end]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            lines.append(String(format: "%04X  %@", offset, hex))
            offset += 16
        }

        return lines.joined(separator: "\n")
    }
}

private struct FrameStyle {
    let label: String
    let tint: Color
    let payloadColor: Color

    init(contentType: String) {
        switch contentType.lowercased() {
        case TCPContentType.json.rawValue:
            label = "JSON"
            tint = .green
            payloadColor = .green
        case TCPContentType.binary.rawValue:
            label = "BINARY"
            tint = .orange
            payloadColor = .orange
        case TCPContentType.http.rawValue:
            label = "HTTP"
            tint = .blue
            payloadColor = .secondary
        case TCPContentType.tls.rawValue:
            label = "TLS"
            tint = .purple
            payloadColor = .secondary
        case TCPContentType.xml.rawValue:
            label = "XML"
            tint = .mint
            payloadColor = .secondary
        case TCPContentType.html.rawValue:
            label = "HTML"
            tint = .teal
            payloadColor = .secondary
        case TCPContentType.urlEncoded.rawValue:
            label = "FORM"
            tint = .indigo
            payloadColor = .secondary
        case TCPContentType.formData.rawValue:
            label = "MULTIPART"
            tint = .indigo
            payloadColor = .secondary
        default:
            label = contentType.isEmpty ? "UNKNOWN" : contentType.uppercased()
            tint = .secondary
            payloadColor = .secondary
        }
    }
}

@MainActor
private final class TCPFrameDetailViewModel: ObservableObject {
    @Published var frames: [TCPFrame] = []

    func reload(sessionID: NSNumber) {
        PacketHoundDataStore.shared.configureIfNeeded()
        frames = TCPFrame.frames(sessionID: sessionID)
    }
}

private extension TCPFrame {
    var frameStableID: String {
        if let id {
            return "id-\(id.stringValue)"
        }
        return "idx-\(idx.intValue)-\(direction)-\(timestamp.doubleValue)"
    }
}

#endif
