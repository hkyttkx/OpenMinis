//
//  HttpHandel.swift
//  SwiftNIO
//
//  Created by Lojii on 2018/8/14.
//  Copyright © 2018年 Lojii. All rights reserved.
//

import Foundation
import NIO
import NIOTLS
import NIOHTTP1
import NIOConcurrencyHelpers
import NIOSSL
import Network

class HTTPHandler : ChannelInboundHandler, RemovableChannelHandler {
    
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    var connected:Bool
    var proxyContext:ProxyContext
    var requestDatas = [Any]()
    var cf:EventLoopFuture<Channel>?
    
    init(proxyContext:ProxyContext) {
        self.connected = false
        self.proxyContext = proxyContext
    }

    // 原始消息报文
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        prepareProxyContext(context: context, data: data)
        let res = self.unwrapInboundIn(data)
        switch res {
        case .head(var head):
            head.headers = NetRequest.removeProxyHead(heads: head.headers)
            let requestURL = absoluteURLString(from: head)
            let matchedRules = RewriteEngine.shared.matchRules(for: requestURL, method: "\(head.method)")
            proxyContext.rewriteRules = matchedRules

            let blockDecision = RewriteEngine.shared.shouldBlock(rules: matchedRules)
            if blockDecision.0 {
                proxyContext.requestBlocked = true
                proxyContext.session.reqLine = "\(head.method) \(head.uri) \(head.version)"
                proxyContext.session.host = head.headers["Host"].first ?? proxyContext.request?.host
                proxyContext.session.localAddress = Session.getIPAddress(socketAddress: context.channel.remoteAddress)
                proxyContext.session.methods = "\(head.method)"
                proxyContext.session.uri = head.uri
                proxyContext.session.reqHttpVersion = "\(head.version)"
                proxyContext.session.target = Session.getUserAgent(target: head.headers["User-Agent"].first)
                proxyContext.session.reqHeads = Session.getHeadsJson(headers: head.headers)
                proxyContext.session.reqEncoding = head.headers["Content-Encoding"].first ?? ""
                proxyContext.session.reqType = head.headers["Content-Type"].first ?? ""
                let statusCode = blockDecision.1 ?? 403
                let blockedBody = RewriteEngine.shared.blockBody(rules: matchedRules) ?? "Blocked by PacketHound rewrite rule."
                let now = NSNumber(value: Date().timeIntervalSince1970)
                proxyContext.session.state = "\(statusCode)"
                proxyContext.session.rspMessage = "Blocked"
                proxyContext.session.rspStartTime = now
                proxyContext.session.rspEndTime = now
                proxyContext.session.endTime = now
                proxyContext.session.note = "blocked by rewrite rule"
                try? proxyContext.session.saveToDB()
                respondBlocked(
                    context: context,
                    version: head.version,
                    statusCode: statusCode,
                    body: blockedBody
                )
                return
            }

            RewriteEngine.shared.applyRequestRewrite(request: &head, rules: matchedRules)
            updateRequestFromHead(head)
            
            // 记录请求头到数据库
            proxyContext.session.reqLine = "\(head.method) \(head.uri) \(head.version)"
            proxyContext.session.host = head.headers["Host"].first ?? proxyContext.request?.host //
            proxyContext.session.localAddress = Session.getIPAddress(socketAddress: context.channel.remoteAddress)
            proxyContext.session.methods = "\(head.method)"//
            proxyContext.session.uri = head.uri//
            proxyContext.session.reqHttpVersion = "\(head.version)"//
            proxyContext.session.target = Session.getUserAgent(target: head.headers["User-Agent"].first)
            proxyContext.session.reqHeads = Session.getHeadsJson(headers: head.headers)
            proxyContext.session.reqEncoding = head.headers["Content-Encoding"].first ?? ""
            proxyContext.session.reqType = head.headers["Content-Type"].first ?? ""
            
            // 判断规则，是否拦截，copy等
            if !proxyContext.request!.ssl {
                proxyContext.session.ignore = proxyContext.task.rule.matching(host: proxyContext.session.host ?? "",uri: head.uri, target: proxyContext.session.target ?? "")
//                print("HTTPHandler匹配")
                if proxyContext.task.rule.defaultStrategy == .COPY {
                    proxyContext.session.ignore = !proxyContext.session.ignore
                }
            }
            try? proxyContext.session.saveToDB()
            
            let uri = head.uri
            if !uri.starts(with: "/"),let hostStr = head.headers["Host"].first {  // fix http://wap.cmread.com/r/457427094/index.htm?cm=C0NA0001&vt=3
                if let newUri = uri.components(separatedBy: hostStr).last {
                    head.uri = newUri
                }
//                if let url = URL(string: uri) {
//                    let relativePath = url.relativePath
//                    let urlEnd = url.absoluteString.components(separatedBy: relativePath).last
//                    head.uri = relativePath + (urlEnd ?? "")
//                }
            }
//            if proxyContext.session.uri != head.uri {
//                print("session.uri:\(proxyContext.session.uri!)")
//                print("---head.uri:\(head.uri )")
//            }

            if cf == nil {
                connectToServer()// 1、建立连接
            }
            
            handleData(head)
            break
        case .body(var body):
            if proxyContext.requestBlocked {
                return
            }
            RewriteEngine.shared.applyRequestBodyRewrite(body: &body, rules: proxyContext.rewriteRules)
            if !proxyContext.session.ignore {
                proxyContext.session.writeBody(type: .REQ, buffer: body)
            }
            if cf == nil {
                connectToServer()
            }
            handleData(body)
            break
        case .end(let end):
            if proxyContext.requestBlocked {
                return
            }
            if !proxyContext.session.ignore {
                proxyContext.session.writeBody(type: .REQ, buffer: nil)
            }
            if cf == nil {
                connectToServer()
            }
            handleData(end,isEnd: true)
            break
        }
        context.fireChannelRead(data)
    }
    
    func connectToServer() -> Void {
        guard let request = proxyContext.request else {
            NSLog("[HTTP] ERROR: no request, closing")
            _ = proxyContext.serverChannel?.close(mode: .all)
            return
        }
        NSLog("[HTTP] connectToServer %@:%d ssl=%d", request.host, request.port, request.ssl ? 1 : 0)
        var channelInitializer: ((Channel) -> EventLoopFuture<Void>)?
//        if proxyContext.isSSL {
        if request.ssl {
            // TODO:添加握手超时断开
            channelInitializer = { (outChannel) -> EventLoopFuture<Void> in
                self.proxyContext.clientChannel = outChannel
                var tlsClientConfiguration = TLSConfiguration.forClient(applicationProtocols: ["http/1.1"])
                tlsClientConfiguration.certificateVerification = .none
                let sslClientContext = try! NIOSSLContext(configuration: tlsClientConfiguration)
                let sniName = request.host.isIPAddress() ? nil : request.host
                let sslClientHandler = try! NIOSSLClientHandler(context: sslClientContext, serverHostname: sniName)
                let applicationProtocolNegotiationHandler = ApplicationProtocolNegotiationHandler { (result) -> EventLoopFuture<Void> in
//                    print("======= m->s:\(result) =======")
                    // ssl握手成功才算连接成功
                    self.proxyContext.session.handshakeEndTime = NSNumber(value: Date().timeIntervalSince1970) //握手结束时间
                    self.connected = true
                    return outChannel.pipeline.addHandler(HTTPRequestEncoder(), name: "HTTPRequestEncoder").flatMap({
                        outChannel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder()), name: "ByteToMessageHandler").flatMap({
                            outChannel.pipeline.addHandler(ExchangeHandler(proxyContext: self.proxyContext), name: "ExchangeHandler").flatMap({
                                // HTTPS handshake has completed; flush buffered request data.
                                self.handleData(nil)
                                return outChannel.eventLoop.makeSucceededFuture(())
                            })
                        })
                    })
                }
                _ = outChannel.pipeline.addHandler(ChannelWatchHandler(proxyContext: self.proxyContext), name: "ChannelWatchHandler")
                return outChannel.pipeline.addHandler(sslClientHandler, name: "NIOSSLClientHandler").flatMap({
                    outChannel.pipeline.addHandler(applicationProtocolNegotiationHandler, name: "ApplicationProtocolNegotiationHandler")
                })
            }
        }else{
            proxyContext.session.connectTime = NSNumber(value: Date().timeIntervalSince1970)  // 开始建立连接
            channelInitializer = { (outChannel) -> EventLoopFuture<Void> in
                self.proxyContext.clientChannel = outChannel
                _ = outChannel.pipeline.addHandler(ChannelWatchHandler(proxyContext: self.proxyContext), name: "ChannelWatchHandler")
                return outChannel.pipeline.addHTTPClientHandlers().flatMap({
                    outChannel.pipeline.addHandler(ExchangeHandler(proxyContext: self.proxyContext), name: "ExchangeHandler")
                })
            }
        }
        
        let clientBootstrap = ClientBootstrap(group: proxyContext.serverChannel!.eventLoop.next())//SO_SNDTIMEO
            .channelInitializer(channelInitializer!)
        cf = clientBootstrap.connect(host: request.host, port: request.port)
        cf!.whenComplete { result in
            switch result {
            case .success(let outChannel):
                self.proxyContext.session.connectedTime = NSNumber(value: Date().timeIntervalSince1970)  // 建立连接成功
                self.proxyContext.clientChannel = outChannel
                self.proxyContext.session.outState = "open"
                self.proxyContext.session.remoteAddress = Session.getIPAddress(socketAddress: outChannel.remoteAddress)
                
                if !request.ssl {
//                    print("《------\(self.proxyContext)------》:HTTP与外部服务器连接成功！")
                    self.connected = true
                    self.handleData(nil)
                }
                try? self.proxyContext.session.saveToDB()
                break
            case .failure(let error):
                NSLog("[HTTP] outChannel connect failure: %@ host=%@:%d", error.localizedDescription, request.host, request.port)
                _ = self.proxyContext.serverChannel?.close()
                _ = self.proxyContext.clientChannel?.close()
                self.proxyContext.session.outState = "failure"
                self.proxyContext.session.note = "error:connect \(request.host):\(request.port) failure:\(error)!"
                break
            }
        }
    }
    
    func sendData(data:Any){
        if let head = data as? HTTPRequestHead{
            let clientHead = HTTPRequestHead(version: head.version, method: head.method, uri: head.uri, headers: head.headers)
            _ = proxyContext.clientChannel!.writeAndFlush(HTTPClientRequestPart.head(clientHead))
        }
        if let body = data as? ByteBuffer{
            _ = proxyContext.clientChannel!.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(body)))
        }
        if let end = data as? HTTPHeaders {
            let promise = proxyContext.clientChannel?.eventLoop.makePromise(of: Void.self)
            proxyContext.clientChannel!.writeAndFlush(HTTPClientRequestPart.end(end), promise: promise)
            promise?.futureResult.whenComplete({ (_) in
                self.proxyContext.session.reqEndTime = NSNumber(value: Date().timeIntervalSince1970)
                try? self.proxyContext.session.saveToDB()
            })
        }
        if let endstr = data as? String, endstr == "end"{
            let promise = proxyContext.clientChannel?.eventLoop.makePromise(of: Void.self)
            proxyContext.clientChannel!.writeAndFlush(HTTPClientRequestPart.end(nil), promise: promise)
            promise?.futureResult.whenComplete({ (_) in
                self.proxyContext.session.reqEndTime = NSNumber(value: Date().timeIntervalSince1970)
                try? self.proxyContext.session.saveToDB()
            })
        }
    }
    
    func handleData(_ data:Any?,isEnd:Bool = false) -> Void {
//        let lock = ConditionLock(value: 0)
//        lock.lock()
        if connected,let outChannel = proxyContext.clientChannel,outChannel.isActive {// 发送requestDatas，然后清空requestDatas
            for rd in requestDatas{
                sendData(data: rd)
            }
            if data != nil {
                sendData(data: data!)
            }
            if data == nil, isEnd {
                sendData(data: "end")
            }
            requestDatas.removeAll()
        }else{
            guard let msg = data else {
                if isEnd {
                    requestDatas.append("end")
                }
                return
            }// 这个return不知道会不会出现泄漏
            requestDatas.append(msg)
        }
//        lock.unlock()
    }
    
    func prepareProxyContext(context: ChannelHandlerContext, data: NIOAny) -> Void {
        if proxyContext.serverChannel == nil {
            proxyContext.serverChannel = context.channel
        }
        let res = self.unwrapInboundIn(data)
        switch res {
        case .head(let head):
            if proxyContext.request == nil {
                proxyContext.request = NetRequest(head)
            }
        case .body(_),.end(_):
            break
        }
    }

    private func updateRequestFromHead(_ head: HTTPRequestHead) {
        let newRequest = NetRequest(head)
        if proxyContext.request?.ssl == true {
            let lowercasedURI = head.uri.lowercased()
            if !lowercasedURI.hasPrefix("http://"), !lowercasedURI.hasPrefix("https://") {
                newRequest.ssl = true
                if newRequest.port == 80 {
                    newRequest.port = 443
                }
            }
        }
        proxyContext.request = newRequest
    }

    private func absoluteURLString(from head: HTTPRequestHead) -> String {
        let uri = head.uri
        let lowercasedURI = uri.lowercased()
        if lowercasedURI.hasPrefix("http://") || lowercasedURI.hasPrefix("https://") {
            return uri
        }

        let host = head.headers["Host"].first ?? proxyContext.request?.host ?? ""
        guard !host.isEmpty else {
            return uri
        }

        let scheme = proxyContext.request?.ssl == true ? "https" : "http"
        if uri.hasPrefix("/") {
            return "\(scheme)://\(host)\(uri)"
        }
        return "\(scheme)://\(host)/\(uri)"
    }

    private func respondBlocked(
        context: ChannelHandlerContext,
        version: HTTPVersion,
        statusCode: Int,
        body: String
    ) {
        var headers = HTTPHeaders()
        let payload = Array(body.utf8)
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(payload.count)")
        headers.add(name: "Connection", value: "close")

        let status = HTTPResponseStatus.custom(code: UInt(statusCode), reasonPhrase: "Blocked")
        let responseHead = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        if !payload.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(mode: .all, promise: nil)
            self.proxyContext.clientChannel?.close(mode: .all, promise: nil)
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
    
    func channelUnregistered(context: ChannelHandlerContext) {
//        print("HTTPHandler channelUnregistered !")
        context.close(mode: .all, promise: nil)
//        proxyContext.clientChannel?.close(mode: .all, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
//        print("HTTPHandler errorCaught:\(error.localizedDescription) -- \(proxyContext.request?.host ?? "")")
        context.close(mode: .all, promise: nil)
        proxyContext.clientChannel?.close(mode: .all, promise: nil)
        context.fireErrorCaught(error)
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
//        print("HTTPHandler event:\(event) - \(proxyContext.request?.host ?? "")")
    }
}
