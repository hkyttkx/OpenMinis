// PH3模式不需要此文件，已禁用编译
#if false
import Foundation
import NIO

/// Client-side CONNECT handshake handler.
/// Added to the HEAD of a NIO pipeline that connects to OutboundProxyServer.
/// Intercepts channelActive to send CONNECT request, reads the 200 response,
/// then removes itself and fires channelActive to downstream handlers (e.g. NIOSSLClientHandler).
class CONNECTHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let targetHost: String
    private let targetPort: Int
    private let completion: (Bool) -> Void
    private var buffer = ByteBuffer()
    private var done = false

    init(targetHost: String, targetPort: Int, completion: @escaping (Bool) -> Void) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.completion = completion
    }

    func channelActive(context: ChannelHandlerContext) {
        // Send CONNECT request. Do NOT fire channelActive downstream yet —
        // downstream handlers (NIOSSLClientHandler) must wait until the tunnel is established.
        let req = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n\r\n"
        var buf = context.channel.allocator.buffer(capacity: req.utf8.count)
        buf.writeString(req)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
        NSLog("[CONNECTClient] sent CONNECT %@:%d", targetHost, targetPort)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if done {
            context.fireChannelRead(data)
            return
        }

        var buf = unwrapInboundIn(data)
        buffer.writeBuffer(&buf)

        guard let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
              str.contains("\r\n\r\n") else {
            return
        }

        done = true
        let success = str.contains("200")

        if success {
            NSLog("[CONNECTClient] CONNECT %@:%d succeeded", targetHost, targetPort)
        } else {
            NSLog("[CONNECTClient] CONNECT %@:%d rejected: %@", targetHost, targetPort, String(str.prefix(200)))
        }

        let channel = context.channel
        context.pipeline.removeHandler(self).whenComplete { [completion] _ in
            if success {
                // Fire channelActive to downstream handlers (triggers NIOSSLClientHandler TLS handshake etc.)
                channel.pipeline.fireChannelActive()
            }
            completion(success)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !done else {
            context.fireErrorCaught(error)
            return
        }
        done = true
        NSLog("[CONNECTClient] error %@:%d: %@", targetHost, targetPort, error.localizedDescription)
        context.pipeline.removeHandler(self).whenComplete { [completion] _ in
            completion(false)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            completion(false)
        }
        context.fireChannelInactive()
    }
}
#endif
