// PH3模式不需要此文件，已禁用编译
#if false
import Foundation
import NIO
import NetworkExtension

/// A local CONNECT proxy server that bridges NIO client channels to NWTCPConnection.
/// NIO handlers (HTTPHandler, TunnelProxyHandler) connect here and send CONNECT host:port.
/// The server creates NWTCPConnection via provider.createTCPConnection() to bypass the VPN
/// tunnel, then relays data bidirectionally.
public class OutboundProxyServer {
    private let group: MultiThreadedEventLoopGroup
    private weak var provider: NEPacketTunnelProvider?
    private var serverChannel: Channel?

    public private(set) var port: Int = 0

    public init(provider: NEPacketTunnelProvider) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.provider = provider
    }

    public func start() throws -> Int {
        let provider = self.provider
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(OutboundConnectHandler(provider: provider))
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        serverChannel = channel
        port = channel.localAddress!.port!
        NSLog("[OutboundProxy] listening on 127.0.0.1:%d", port)
        return port
    }

    public func shutdown() {
        serverChannel?.close(promise: nil)
        try? group.syncShutdownGracefully()
    }
}

/// Server-side handler for a single CONNECT tunnel.
/// 1. Reads CONNECT request from NIO channel
/// 2. Creates NWTCPConnection via provider.createTCPConnection() (bypasses VPN)
/// 3. Sends "200 Connection Established" response
/// 4. Relays data bidirectionally between NIO channel and NWTCPConnection
private final class OutboundConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private weak var provider: NEPacketTunnelProvider?
    private var headerBuffer = ByteBuffer()
    private var nwConnection: NWTCPConnection?
    private var stateObservation: NSKeyValueObservation?
    private var tunnelEstablished = false
    private var closed = false
    private weak var ctx: ChannelHandlerContext?

    init(provider: NEPacketTunnelProvider?) {
        self.provider = provider
    }

    func handlerAdded(context: ChannelHandlerContext) {
        ctx = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closed else { return }

        if tunnelEstablished {
            let buf = unwrapInboundIn(data)
            let bytes = Data(buf.readableBytesView)
            nwConnection?.write(bytes) { [weak self] error in
                if let error = error {
                    NSLog("[OutboundProxy] write error: %@", error.localizedDescription)
                    context.eventLoop.execute { self?.closeAll() }
                }
            }
            return
        }

        var buf = unwrapInboundIn(data)
        headerBuffer.writeBuffer(&buf)

        guard let str = headerBuffer.getString(at: headerBuffer.readerIndex,
                                                length: headerBuffer.readableBytes),
              str.contains("\r\n\r\n") else {
            return
        }

        guard let firstLine = str.components(separatedBy: "\r\n").first,
              firstLine.uppercased().hasPrefix("CONNECT ") else {
            NSLog("[OutboundProxy] not CONNECT: %@", String(str.prefix(80)))
            closeAll()
            return
        }

        let tokens = firstLine.split(separator: " ")
        guard tokens.count >= 2 else { closeAll(); return }

        let hostPort = String(tokens[1])
        let parts = hostPort.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? String(parts[1]) : "443"

        // Extract any data after \r\n\r\n
        let headerEndRange = str.range(of: "\r\n\r\n")!
        let headerLen = str[str.startIndex..<headerEndRange.upperBound].utf8.count
        let totalLen = headerBuffer.readableBytes
        let extraLen = totalLen - headerLen
        var extraData: Data?
        if extraLen > 0, let bytes = headerBuffer.getBytes(at: headerBuffer.readerIndex + headerLen,
                                                             length: extraLen) {
            extraData = Data(bytes)
        }
        headerBuffer.clear()

        guard let provider = provider else {
            NSLog("[OutboundProxy] provider released")
            closeAll()
            return
        }

        let endpoint = NWHostEndpoint(hostname: host, port: port)
        let conn = provider.createTCPConnection(to: endpoint, enableTLS: false,
                                                  tlsParameters: nil, delegate: nil)
        nwConnection = conn

        NSLog("[OutboundProxy] connecting to %@:%@", host, port)

        var didConnect = false
        stateObservation = conn.observe(\.state, options: [.initial, .new]) { [weak self] conn, _ in
            guard let self = self, !self.closed, let ctx = self.ctx else { return }
            ctx.eventLoop.execute {
                guard !self.closed, !didConnect else { return }
                switch conn.state {
                case .connected:
                    didConnect = true
                    self.onRemoteConnected(context: ctx, host: host, port: port, extraData: extraData)
                case .disconnected, .cancelled, .invalid:
                    NSLog("[OutboundProxy] connect failed %@:%@ state=%ld", host, port, conn.state.rawValue)
                    self.closeAll()
                case .waiting:
                    NSLog("[OutboundProxy] waiting %@:%@", host, port)
                default:
                    break
                }
            }
        }
    }

    private func onRemoteConnected(context: ChannelHandlerContext, host: String, port: String,
                                    extraData: Data?) {
        NSLog("[OutboundProxy] connected to %@:%@", host, port)
        tunnelEstablished = true

        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        var buf = context.channel.allocator.buffer(capacity: response.utf8.count)
        buf.writeString(response)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)

        if let extra = extraData, !extra.isEmpty {
            nwConnection?.write(extra) { _ in }
        }

        readRemoteLoop(context: context)
    }

    private func readRemoteLoop(context: ChannelHandlerContext) {
        guard !closed, tunnelEstablished, let conn = nwConnection else { return }

        conn.readMinimumLength(1, maximumLength: 65536) { [weak self] data, error in
            guard let self = self, !self.closed, let ctx = self.ctx else { return }
            ctx.eventLoop.execute {
                if error != nil {
                    self.closeAll()
                    return
                }
                guard let data = data, !data.isEmpty, ctx.channel.isActive else {
                    self.closeAll()
                    return
                }
                var buf = ctx.channel.allocator.buffer(capacity: data.count)
                buf.writeBytes(data)
                ctx.writeAndFlush(self.wrapOutboundOut(buf), promise: nil)
                self.readRemoteLoop(context: ctx)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        NSLog("[OutboundProxy] channel error: %@", error.localizedDescription)
        closeAll()
    }

    private func closeAll() {
        guard !closed else { return }
        closed = true
        stateObservation = nil
        nwConnection?.cancel()
        nwConnection = nil
        ctx?.close(promise: nil)
    }
}
#endif
