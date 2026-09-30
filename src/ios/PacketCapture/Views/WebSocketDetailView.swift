import SwiftUI
import TunnelServices

struct WebSocketDetailView: View {
    let sessionID: NSNumber
    let sessionFolder: String?

    @StateObject private var viewModel = WebSocketDetailViewModel()
    @State private var expandedFrameIDs: Set<Int> = []

    init(sessionID: NSNumber, sessionFolder: String? = nil) {
        self.sessionID = sessionID
        self.sessionFolder = sessionFolder
    }

    var body: some View {
        List {
            if viewModel.frames.isEmpty {
                EmptyStateView(
                    title: "暂无 WebSocket 帧",
                    systemImage: "bubble.left.and.bubble.right",
                    message: "捕获到 WebSocket 流量后将显示在这里"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.frames, id: \.id) { frame in
                    frameRow(frame)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("WebSocket")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            viewModel.reload(sessionID: sessionID)
        }
        .onAppear {
            viewModel.reload(sessionID: sessionID)
        }
    }

    private func frameRow(_ frame: WSFrame) -> some View {
        let frameID = frame.id?.intValue ?? -1
        let expanded = expandedFrameIDs.contains(frameID)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(directionSymbol(for: frame.direction))
                    .font(.headline)
                    .foregroundStyle(directionColor(for: frame.direction))

                Text(directionText(for: frame.direction))
                    .font(.subheadline.weight(.semibold))

                Text(opcodeText(for: frame.opcode.intValue))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())

                Spacer()

                Text(timestampText(frame.timestamp.doubleValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(previewPayload(for: frame))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)

            Button(expanded ? "收起" : "展开") {
                toggleExpanded(id: frameID)
            }
            .font(.caption.bold())
        }
        .padding(.vertical, 4)
    }

    private func toggleExpanded(id: Int) {
        guard id >= 0 else {
            return
        }

        if expandedFrameIDs.contains(id) {
            expandedFrameIDs.remove(id)
        } else {
            expandedFrameIDs.insert(id)
        }
    }

    private func previewPayload(for frame: WSFrame) -> String {
        if !frame.payload_file.isEmpty,
           let data = loadPayloadFile(named: frame.payload_file),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return frame.payload.isEmpty ? "(空数据)" : frame.payload
    }

    private func loadPayloadFile(named fileName: String) -> Data? {
        guard !fileName.isEmpty else {
            return nil
        }

        if let sessionFolder {
            let path = "\(MitmService.getStoreFolder())\(sessionFolder)/\(fileName)"
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }

        if let session = Session.findAll(["id": sessionID]).first,
           let folder = session.fileFolder {
            let path = "\(MitmService.getStoreFolder())\(folder)/\(fileName)"
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }

        return nil
    }

    private func directionSymbol(for direction: String) -> String {
        direction.lowercased() == "send" ? "↑" : "↓"
    }

    private func directionText(for direction: String) -> String {
        direction.lowercased() == "send" ? "发送" : "接收"
    }

    private func directionColor(for direction: String) -> Color {
        direction.lowercased() == "send" ? .green : .blue
    }

    private func opcodeText(for opcode: Int) -> String {
        switch opcode {
        case 0: return "续传"
        case 1: return "文本"
        case 2: return "二进制"
        case 8: return "关闭"
        case 9: return "心跳"
        case 10: return "心跳回复"
        default: return "opcode:\(opcode)"
        }
    }

    private func timestampText(_ timestamp: Double) -> String {
        guard timestamp > 0 else {
            return "-"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

@MainActor
private final class WebSocketDetailViewModel: ObservableObject {
    @Published var frames: [WSFrame] = []

    func reload(sessionID: NSNumber) {
        PacketHoundDataStore.shared.configureIfNeeded()
        frames = WSFrame.frames(sessionID: sessionID)
    }
}
