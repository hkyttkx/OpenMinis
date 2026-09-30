import Foundation
import NIO
import NIOFoundationCompat
import NIOWebSocket

final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    enum Direction: String {
        case send
        case receive
    }

    private struct FragmentAccumulator {
        var opcode: WebSocketOpcode
        var data: ByteBuffer
    }

    private let proxyContext: ProxyContext
    private let direction: Direction
    private let peerChannelProvider: () -> Channel?
    private var fragmentAccumulator: FragmentAccumulator?
    private let payloadFileThreshold = 8 * 1024

    init(proxyContext: ProxyContext, direction: Direction, peerChannelProvider: @escaping () -> Channel?) {
        self.proxyContext = proxyContext
        self.direction = direction
        self.peerChannelProvider = peerChannelProvider
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        record(frame: frame)
        forward(frame: frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(mode: .all, promise: nil)
        peerChannelProvider()?.close(mode: .all, promise: nil)
    }

    private func forward(frame: WebSocketFrame) {
        guard let peerChannel = peerChannelProvider(), peerChannel.isActive else {
            return
        }

        var outboundFrame = frame
        if frame.maskKey != nil {
            outboundFrame.data = frame.unmaskedData
            outboundFrame.extensionData = frame.unmaskedExtensionData
        }

        _ = peerChannel.writeAndFlush(wrapOutboundOut(outboundFrame))
    }

    private func record(frame: WebSocketFrame) {
        let payload = payloadBuffer(from: frame)

        switch frame.opcode {
        case .text, .binary:
            if frame.fin {
                saveFrame(opcode: frame.opcode, payload: payload)
            } else {
                fragmentAccumulator = FragmentAccumulator(opcode: frame.opcode, data: payload)
            }
        case .continuation:
            handleContinuation(frame: frame, payload: payload)
        default:
            saveFrame(opcode: frame.opcode, payload: payload)
        }
    }

    private func handleContinuation(frame: WebSocketFrame, payload: ByteBuffer) {
        guard var accumulator = fragmentAccumulator else {
            saveFrame(opcode: frame.opcode, payload: payload)
            return
        }

        var merged = accumulator.data
        var next = payload
        merged.writeBuffer(&next)
        accumulator.data = merged
        fragmentAccumulator = accumulator

        if frame.fin {
            saveFrame(opcode: accumulator.opcode, payload: accumulator.data)
            fragmentAccumulator = nil
        }
    }

    private func payloadBuffer(from frame: WebSocketFrame) -> ByteBuffer {
        if frame.maskKey != nil {
            return frame.unmaskedData
        }
        return frame.data
    }

    private func saveFrame(opcode: WebSocketOpcode, payload: ByteBuffer) {
        guard let sessionID = proxyContext.session.id else {
            return
        }

        let payloadData = payload.getData(at: payload.readerIndex, length: payload.readableBytes) ?? Data()
        let payloadValue = serializedPayload(data: payloadData, opcode: opcode)

        let frameRecord = WSFrame()
        frameRecord.session_id = sessionID
        frameRecord.direction = direction.rawValue
        frameRecord.opcode = NSNumber(value: Int(webSocketOpcode: opcode))
        frameRecord.payload = payloadValue.payload
        frameRecord.payload_file = payloadValue.payloadFile
        frameRecord.timestamp = NSNumber(value: Date().timeIntervalSince1970)
        try? frameRecord.save()
    }

    private func serializedPayload(data: Data, opcode: WebSocketOpcode) -> (payload: String, payloadFile: String) {
        if data.count > payloadFileThreshold, let fileName = writePayloadToFile(data: data) {
            return (payload: "[stored in file]", payloadFile: fileName)
        }

        if opcode == .text, let text = String(data: data, encoding: .utf8) {
            return (payload: text, payloadFile: "")
        }

        return (payload: data.base64EncodedString(), payloadFile: "")
    }

    private func writePayloadToFile(data: Data) -> String? {
        let folderPath = "\(MitmService.getStoreFolder())\(proxyContext.session.fileFolder ?? "ws")"
        let fileManager = FileManager.default

        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: folderPath, isDirectory: &isDir)
        if !exists {
            try? fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true, attributes: nil)
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileName = "ws_\(proxyContext.session.id?.intValue ?? 0)_\(direction.rawValue)_\(timestamp).bin"
        let filePath = "\(folderPath)/\(fileName)"

        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }
}
