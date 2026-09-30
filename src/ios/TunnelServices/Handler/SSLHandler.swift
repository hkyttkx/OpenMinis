//
//  SSLHandler.swift
//  NIO1901
//
//  Created by LiuJie on 2019/4/17.
//  Copyright © 2019 Lojii. All rights reserved.
//

import UIKit
import NIOTLS
import NIO
import NIOSSL
import NIOHTTP1

class SSLHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum ClientHelloParseResult {
        case needMoreData
        case notTLS
        case parsed(serverName: String?)
    }

    var proxyContext: ProxyContext
    var scheduled: Scheduled<Void>

    private var bufferedClientHello: ByteBuffer?
    private var lastHandshakeHost: String?

    init(proxyContext: ProxyContext, scheduled: Scheduled<Void>) {
        self.proxyContext = proxyContext
        self.scheduled = scheduled
    }

    // 原始消息报文
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if bufferedClientHello == nil {
            bufferedClientHello = context.channel.allocator.buffer(capacity: incoming.readableBytes)
        }
        bufferedClientHello?.writeBuffer(&incoming)

        guard let clientHelloBuffer = bufferedClientHello else {
            return
        }

        switch parseClientHello(from: clientHelloBuffer) {
        case .needMoreData:
            return
        case .notTLS:
            scheduled.cancel()
            proxyContext.session.note = "error:invalid TLS ClientHello"
            proxyContext.session.sstate = "failure"
            context.channel.close(mode: .all, promise: nil)
            return
        case .parsed(let serverName):
            scheduled.cancel()
            proxyContext.isSSL = true

            let host = normalizedHost(serverName) ?? normalizedHost(proxyContext.request?.host) ?? "localhost"
            let port = proxyContext.request?.port ?? 443
            lastHandshakeHost = host
            NSLog("[PH-TLS] ClientHello parsed, SNI=%@, host=%@", serverName ?? "(nil)", host)

            // 自适应 TLS 跳过：如果此 host 之前 MITM 失败过，直接透传
            if proxyContext.task.mitmService?.skipHandshake(host: host) == true {
                NSLog("[PH-TLS] MITM skipped for host=%@, switching to passthrough", host)
                // 确保 proxyContext.request 存在（直连 SSL 路径可能为 nil）
                if proxyContext.request == nil {
                    let dummyHead = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "\(host):\(port)")
                    proxyContext.request = NetRequest(dummyHead)
                }
                proxyContext.session.sstate = "tunnel"
                proxyContext.session.note = "TLS passthrough \(host):\(port)"
                proxyContext.session.protoDetail = "TLS"
                // 复用 TunnelProxyHandler 做双向 TCP 透传
                let cancelTask = context.channel.eventLoop.scheduleTask(in: TimeAmount.seconds(10)) {
                    self.proxyContext.session.note = "error:TLS tunnel connect timeout \(host)"
                    self.proxyContext.session.sstate = "failure"
                    context.channel.close(mode: .all, promise: nil)
                }
                _ = context.pipeline.addHandler(
                    TunnelProxyHandler(proxyContext: proxyContext, isOut: false, scheduled: cancelTask),
                    name: "TunnelProxyHandler", position: .first)
                var replayBuffer = clientHelloBuffer
                context.fireChannelRead(wrapInboundOut(replayBuffer))
                bufferedClientHello = nil
                context.pipeline.removeHandler(self, promise: nil)
                try? proxyContext.session.saveToDB()
                return
            }

            guard
                let caCert = proxyContext.task.cacert,
                let caPrivateKey = proxyContext.task.cakey,
                let rsaPrivateKey = proxyContext.task.rsakey
            else {
                NSLog("[PH-TLS] ERROR: Missing CA materials! cacert=%d cakey=%d rsakey=%d",
                      proxyContext.task.cacert != nil ? 1 : 0,
                      proxyContext.task.cakey != nil ? 1 : 0,
                      proxyContext.task.rsakey != nil ? 1 : 0)
                AxLogger.log("Missing CA materials for SSL MITM", level: .Error)
                proxyContext.session.note = "error:missing CA materials"
                proxyContext.session.sstate = "failure"
                context.channel.close(mode: .all, promise: nil)
                return
            }

            let cacheKey = host.lowercased()
            var dynamicCert = proxyContext.task.certPool.object(forKey: cacheKey) as? NIOSSLCertificate
            if dynamicCert == nil {
                dynamicCert = CertUtils.generateCert(host: cacheKey, rsaKey: rsaPrivateKey, caKey: caPrivateKey, caCert: caCert)
                if let dynamicCert {
                    proxyContext.task.certPool.setValue(dynamicCert, forKey: cacheKey)
                }
            }

            guard let dynamicCert else {
                NSLog("[PH-TLS] ERROR: dynamic cert generation returned nil for %@", host)
                proxyContext.session.note = "error:dynamic cert generation failed"
                proxyContext.session.sstate = "failure"
                context.channel.close(mode: .all, promise: nil)
                return
            }

            do {
                NSLog("[PH-TLS] Setting up MITM TLS for %@", host)
                let tlsServerConfiguration = TLSConfiguration.forServer(
                    certificateChain: [.certificate(dynamicCert)],
                    privateKey: .privateKey(rsaPrivateKey)
                )
                let sslServerContext = try NIOSSLContext(configuration: tlsServerConfiguration)
                let sslServerHandler = try NIOSSLServerHandler(context: sslServerContext)

                let cancelHandshakeTask = context.channel.eventLoop.scheduleTask(in: TimeAmount.seconds(10)) {
                    self.proxyContext.session.note = "error:can not get server hello from MITM"
                    self.proxyContext.session.sstate = "failure"
                    self.proxyContext.task.mitmService?.addSkipHandshake(host: host)
                    NSLog("[PH-TLS] MITM timeout, add skip host=%@", host)
                    context.channel.close(mode: .all, promise: nil)
                }

                let negotiationHandler = ApplicationProtocolNegotiationHandler { _ -> EventLoopFuture<Void> in
                    cancelHandshakeTask.cancel()

                    let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)
                    return context.pipeline.addHandler(ByteToMessageHandler(requestDecoder), name: "ByteToMessageHandler").flatMap {
                        context.pipeline.addHandler(HTTPResponseEncoder(), name: "HTTPResponseEncoder").flatMap {
                            context.pipeline.addHandler(HTTPServerPipelineHandler(), name: "HTTPServerPipelineHandler").flatMap {
                                context.pipeline.addHandler(HTTPHandler(proxyContext: self.proxyContext), name: "HTTPHandler")
                            }
                        }
                    }
                }

                _ = context.pipeline.addHandler(sslServerHandler, name: "NIOSSLServerHandler", position: .last)
                _ = context.pipeline.addHandler(negotiationHandler, name: "ApplicationProtocolNegotiationHandler")

                var replayBuffer = clientHelloBuffer
                context.fireChannelRead(self.wrapInboundOut(replayBuffer))
                bufferedClientHello = nil
                context.pipeline.removeHandler(self, promise: nil)
            } catch {
                NSLog("[PH-TLS] ERROR: TLS MITM setup failed for %@ - %@", host, error.localizedDescription)
                proxyContext.session.note = "error:TLS MITM setup failed - \(error.localizedDescription)"
                proxyContext.session.sstate = "failure"
                proxyContext.task.mitmService?.addSkipHandshake(host: host)
                context.channel.close(mode: .all, promise: nil)
            }
        }
    }

    func prepareProxyContext(context: ChannelHandlerContext, data: NIOAny) {
        if proxyContext.serverChannel == nil {
            proxyContext.serverChannel = context.channel
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let host = lastHandshakeHost {
            proxyContext.task.mitmService?.addSkipHandshake(host: host)
        }
        NSLog("[PH-TLS] errorCaught: %@", error.localizedDescription)
        context.channel.close(mode: .all, promise: nil)
    }

    private func parseClientHello(from buffer: ByteBuffer) -> ClientHelloParseResult {
        let start = buffer.readerIndex

        guard buffer.readableBytes >= 5 else {
            return .needMoreData
        }

        guard
            let contentType: UInt8 = buffer.getInteger(at: start, as: UInt8.self),
            let majorVersion: UInt8 = buffer.getInteger(at: start + 1, as: UInt8.self),
            let _ = buffer.getInteger(at: start + 2, as: UInt8.self),
            let recordLength: UInt16 = buffer.getInteger(at: start + 3, as: UInt16.self)
        else {
            return .needMoreData
        }

        guard contentType == 22, majorVersion == 3 else {
            return .notTLS
        }

        let recordEnd = start + 5 + Int(recordLength)
        guard start + buffer.readableBytes >= recordEnd else {
            return .needMoreData
        }

        let handshakeStart = start + 5
        guard let handshakeType: UInt8 = buffer.getInteger(at: handshakeStart, as: UInt8.self), handshakeType == 1 else {
            return .notTLS
        }

        guard let handshakeLength = readUInt24(buffer, at: handshakeStart + 1) else {
            return .needMoreData
        }
        guard handshakeLength + 4 <= Int(recordLength) else {
            // ClientHello may be fragmented across TLS records.
            return .parsed(serverName: nil)
        }

        var offset = handshakeStart + 4
        let upperBound = recordEnd

        guard advance(offset: &offset, by: 2, upperBound: upperBound) else { return .notTLS } // client version
        guard advance(offset: &offset, by: 32, upperBound: upperBound) else { return .notTLS } // random

        guard let sessionIDLength: UInt8 = buffer.getInteger(at: offset, as: UInt8.self) else { return .notTLS }
        guard advance(offset: &offset, by: 1 + Int(sessionIDLength), upperBound: upperBound) else { return .notTLS }

        guard let cipherSuitesLength: UInt16 = buffer.getInteger(at: offset, as: UInt16.self) else { return .notTLS }
        guard advance(offset: &offset, by: 2 + Int(cipherSuitesLength), upperBound: upperBound) else { return .notTLS }

        guard let compressionMethodsLength: UInt8 = buffer.getInteger(at: offset, as: UInt8.self) else { return .notTLS }
        guard advance(offset: &offset, by: 1 + Int(compressionMethodsLength), upperBound: upperBound) else { return .notTLS }

        if offset == upperBound {
            return .parsed(serverName: nil)
        }

        guard let extensionsLength: UInt16 = buffer.getInteger(at: offset, as: UInt16.self) else {
            return .notTLS
        }
        offset += 2

        let extensionsEnd = offset + Int(extensionsLength)
        guard extensionsEnd <= upperBound else {
            return .notTLS
        }

        while offset + 4 <= extensionsEnd {
            guard
                let extType: UInt16 = buffer.getInteger(at: offset, as: UInt16.self),
                let extLength: UInt16 = buffer.getInteger(at: offset + 2, as: UInt16.self)
            else {
                return .notTLS
            }
            offset += 4

            let extensionEnd = offset + Int(extLength)
            guard extensionEnd <= extensionsEnd else {
                return .notTLS
            }

            if extType == 0 {
                guard offset + 2 <= extensionEnd,
                      let nameListLength: UInt16 = buffer.getInteger(at: offset, as: UInt16.self)
                else {
                    return .notTLS
                }

                var nameOffset = offset + 2
                let nameListEnd = min(offset + 2 + Int(nameListLength), extensionEnd)

                while nameOffset + 3 <= nameListEnd {
                    guard
                        let nameType: UInt8 = buffer.getInteger(at: nameOffset, as: UInt8.self),
                        let nameLength: UInt16 = buffer.getInteger(at: nameOffset + 1, as: UInt16.self)
                    else {
                        return .notTLS
                    }

                    nameOffset += 3
                    let nameEnd = nameOffset + Int(nameLength)
                    guard nameEnd <= nameListEnd else {
                        return .notTLS
                    }

                    if nameType == 0,
                       let host = buffer.getString(at: nameOffset, length: Int(nameLength)),
                       !host.isEmpty {
                        return .parsed(serverName: host)
                    }

                    nameOffset = nameEnd
                }
            }

            offset = extensionEnd
        }

        return .parsed(serverName: nil)
    }

    private func readUInt24(_ buffer: ByteBuffer, at index: Int) -> Int? {
        guard
            let byte0: UInt8 = buffer.getInteger(at: index, as: UInt8.self),
            let byte1: UInt8 = buffer.getInteger(at: index + 1, as: UInt8.self),
            let byte2: UInt8 = buffer.getInteger(at: index + 2, as: UInt8.self)
        else {
            return nil
        }

        return (Int(byte0) << 16) | (Int(byte1) << 8) | Int(byte2)
    }

    private func advance(offset: inout Int, by value: Int, upperBound: Int) -> Bool {
        let next = offset + value
        guard next <= upperBound else {
            return false
        }
        offset = next
        return true
    }

    private func normalizedHost(_ host: String?) -> String? {
        guard let host else {
            return nil
        }

        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasSuffix(".") {
            return String(lowercased.dropLast())
        }
        return lowercased
    }
}
