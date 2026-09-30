import UIKit
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOWebSocket

class ExchangeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    var proxyContext: ProxyContext
    var gotEnd: Bool = false

    private var responseHeadForRewrite: HTTPResponseHead?
    private var pendingWebSocketUpgrade = false

    init(proxyContext: ProxyContext) {
        self.proxyContext = proxyContext
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let res = unwrapInboundIn(data)
        switch res {
        case .head(var head):
            var rewrittenBody: ByteBuffer?
            RewriteEngine.shared.applyResponseRewrite(response: &head, body: &rewrittenBody, rules: proxyContext.rewriteRules)
            responseHeadForRewrite = head
            pendingWebSocketUpgrade = isWebSocketUpgradeResponse(head)
            proxyContext.webSocketUpgraded = pendingWebSocketUpgrade

            proxyContext.session.rspStartTime = NSNumber(value: Date().timeIntervalSince1970)
            proxyContext.session.rspHttpVersion = "\(head.version)"
            proxyContext.session.state = "\(head.status.code)"
            proxyContext.session.rspMessage = head.status.reasonPhrase
            let contentType = head.headers["Content-Type"].first ?? ""
            proxyContext.session.rspType = contentType
            if let type = contentType.components(separatedBy: ";").first {
                proxyContext.session.suffix = type.components(separatedBy: "/").last ?? ""
            }
            proxyContext.session.rspEncoding = head.headers["Content-Encoding"].first ?? ""
            proxyContext.session.rspHeads = Session.getHeadsJson(headers: head.headers)
            proxyContext.session.rspDisposition = head.headers["Content-Disposition"].first ?? ""
            try? proxyContext.session.saveToDB()

            _ = proxyContext.serverChannel?.writeAndFlush(HTTPServerResponsePart.head(head))

        case .body(let body):
            var responseBody = body
            if var rewriteHead = responseHeadForRewrite {
                var bodyBuffer: ByteBuffer? = responseBody
                RewriteEngine.shared.applyResponseRewrite(response: &rewriteHead, body: &bodyBuffer, rules: proxyContext.rewriteRules)
                responseHeadForRewrite = rewriteHead
                if let rewrittenBody = bodyBuffer {
                    responseBody = rewrittenBody
                }
            }

            if proxyContext.session.fileName == "" {
                if let fileName = proxyContext.session.uri?.getFileName() {
                    proxyContext.session.fileName = fileName
                    try? proxyContext.session.saveToDB()
                }
                let nameParts = proxyContext.session.fileName.components(separatedBy: ".")
                if nameParts.count < 2 {
                    let type = proxyContext.session.rspType.getRealType()
                    if type != "" {
                        proxyContext.session.fileName = "\(proxyContext.session.fileName).\(type)"
                        try? proxyContext.session.saveToDB()
                    }
                }
            }

            if !proxyContext.session.ignore {
                proxyContext.session.writeBody(type: .RSP, buffer: responseBody, realName: proxyContext.session.fileName)
            }
            _ = proxyContext.serverChannel?.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(responseBody)))

        case .end(let tailHeaders):
            proxyContext.session.rspEndTime = NSNumber(value: Date().timeIntervalSince1970)
            gotEnd = true
            if !proxyContext.session.ignore, !pendingWebSocketUpgrade {
                proxyContext.session.writeBody(type: .RSP, buffer: nil, realName: proxyContext.session.fileName)
            }

            let promise = proxyContext.serverChannel?.eventLoop.makePromise(of: Void.self)
            proxyContext.serverChannel?.writeAndFlush(HTTPServerResponsePart.end(tailHeaders), promise: promise)

            if pendingWebSocketUpgrade {
                promise?.futureResult.whenComplete { _ in
                    self.upgradeToWebSocket(context: context)
                }
                return
            }

            promise?.futureResult.whenComplete { _ in
                if self.proxyContext.serverChannel?.isActive == true {
                    self.proxyContext.serverChannel?.close(mode: .all, promise: nil)
                }
            }

            let outPromise = context.eventLoop.makePromise(of: Void.self)
            context.channel.close(mode: .all, promise: outPromise)
            outPromise.futureResult.whenComplete { _ in }
            return
        }

        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        context.close(mode: .all, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        NSLog("[Exchange] errorCaught: %@ host=%@", error.localizedDescription, proxyContext.request?.host ?? "?")
        context.channel.close(mode: .all, promise: nil)
        if proxyContext.serverChannel?.isActive == true {
            _ = proxyContext.serverChannel?.close(mode: .all)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {}

    private func isWebSocketUpgradeResponse(_ head: HTTPResponseHead) -> Bool {
        guard head.status.code == 101 else {
            return false
        }

        let upgradeValue = head.headers["Upgrade"].first?.lowercased() ?? ""
        guard upgradeValue == "websocket" else {
            return false
        }

        let hasUpgradeToken = head.headers["Connection"].contains { value in
            value.lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains("upgrade")
        }
        return hasUpgradeToken
    }

    private func upgradeToWebSocket(context: ChannelHandlerContext) {
        guard let inboundChannel = proxyContext.serverChannel else {
            return
        }

        let outboundChannel = context.channel
        proxyContext.webSocketUpgraded = true
        proxyContext.session.note = "upgraded to websocket"
        try? proxyContext.session.saveToDB()

        let removeInbound = removeHandlers(
            ["HTTPHandler", "HTTPHandle", "HTTPServerPipelineHandler", "HTTPResponseEncoder", "ByteToMessageHandler"],
            from: inboundChannel.pipeline
        )

        let removeOutbound = removeHandlers(
            ["ExchangeHandler", "HTTPRequestEncoder", "ByteToMessageHandler"],
            from: outboundChannel.pipeline
        )

        _ = removeInbound.and(removeOutbound).flatMap { _ in
            let inboundWS = self.configureWebSocketPipeline(
                channel: inboundChannel,
                direction: .send,
                peerProvider: { [weak outboundChannel] in outboundChannel }
            )
            let outboundWS = self.configureWebSocketPipeline(
                channel: outboundChannel,
                direction: .receive,
                peerProvider: { [weak inboundChannel] in inboundChannel }
            )
            return inboundWS.and(outboundWS).map { _ in () }
        }.whenFailure { _ in
            inboundChannel.close(mode: .all, promise: nil)
            outboundChannel.close(mode: .all, promise: nil)
        }
    }

    private func configureWebSocketPipeline(
        channel: Channel,
        direction: WebSocketHandler.Direction,
        peerProvider: @escaping () -> Channel?
    ) -> EventLoopFuture<Void> {
        channel.pipeline.addHandler(WebSocketFrameEncoder(), name: "WebSocketFrameEncoder_\(direction.rawValue)").flatMap {
            channel.pipeline.addHandler(
                ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 20)),
                name: "WebSocketFrameDecoder_\(direction.rawValue)"
            )
        }.flatMap {
            channel.pipeline.addHandler(
                WebSocketHandler(
                    proxyContext: self.proxyContext,
                    direction: direction,
                    peerChannelProvider: peerProvider
                ),
                name: "WebSocketHandler_\(direction.rawValue)"
            )
        }
    }

    private func removeHandlers(_ names: [String], from pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        var future = pipeline.eventLoop.makeSucceededFuture(())
        for name in names {
            future = future.flatMap {
                self.removeHandler(named: name, from: pipeline)
            }
        }
        return future
    }

    private func removeHandler(named name: String, from pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        let promise = pipeline.eventLoop.makePromise(of: Void.self)
        pipeline.removeHandler(name: name, promise: promise)
        return promise.futureResult.flatMapError { _ in
            pipeline.eventLoop.makeSucceededFuture(())
        }
    }
}
