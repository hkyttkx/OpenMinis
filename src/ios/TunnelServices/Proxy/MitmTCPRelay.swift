// PH3模式不需要此文件，已禁用编译
#if false
import Foundation
import NetworkExtension

final class MitmTCPRelay: NSObject, TransparentTCPRelay, TSTCPSocketDelegate {
    enum RelayState {
        case connectingProxy
        case waitingConnectResponse
        case relaying
        case closed
    }

    let relayID: String
    private let socket: TSTCPSocket
    private weak var provider: NEPacketTunnelProvider?
    private let task: Task
    private let sourceIP: String
    private let sourcePort: UInt16
    private let destinationIP: String
    private let targetHost: String
    private let targetPort: UInt16
    private let onClose: (String) -> Void

    private var connection: NWTCPConnection?
    private var stateObservation: NSKeyValueObservation?
    private var state: RelayState = .connectingProxy
    private var isClosed = false

    private var pendingClientData: [Data] = []
    private var connectResponseBuffer = Data()

    private var uploadBytes = 0
    private var downloadBytes = 0
    private let session: Session

    var lastActivity: Date = Date()

    init(
        relayID: String,
        socket: TSTCPSocket,
        provider: NEPacketTunnelProvider,
        task: Task,
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        targetHost: String,
        targetPort: UInt16,
        onClose: @escaping (String) -> Void
    ) {
        self.relayID = relayID
        self.socket = socket
        self.provider = provider
        self.task = task
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destinationIP = destinationIP
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.onClose = onClose

        let newSession = Session.newSession(task)
        newSession.schemes = targetPort == 443 ? "Https" : "Http"
        newSession.methods = "TCP"
        newSession.host = targetHost
        newSession.uri = "\(targetHost):\(targetPort)"
        newSession.localAddress = "\(sourceIP):\(sourcePort)"
        newSession.remoteAddress = "\(targetHost):\(targetPort)"
        newSession.srcIP = sourceIP
        newSession.srcPort = "\(sourcePort)"
        newSession.dstIP = destinationIP
        newSession.dstPort = "\(targetPort)"
        newSession.protoDetail = targetPort == 443 ? "TLS" : "HTTP"
        newSession.sstate = "tunnel"
        newSession.note = "transparent mitm relay"
        self.session = newSession

        super.init()
        try? session.saveToDB()
    }

    func start() {
        // MUST run synchronously — called from didAcceptTCPSocket which is already on processQueue.
        // If we dispatch async, the delegate is set too late and lwIP drops the first data packet.
        self.startOnProcessQueue()
    }

    func close() {
        TSIPStack.stack.processQueue.async {
            self.closeOnProcessQueue(reason: "router close", closeSocket: true)
        }
    }

    private func startOnProcessQueue() {
        guard !isClosed else { return }

        socket.delegate = self
        session.connectTime = NSNumber(value: Date().timeIntervalSince1970)

        guard let provider else {
            closeOnProcessQueue(reason: "provider released", closeSocket: true)
            return
        }

        let endpoint = NWHostEndpoint(hostname: "127.0.0.1", port: "8034")
        let tcpConnection = provider.createTCPConnection(to: endpoint, enableTLS: false, tlsParameters: nil, delegate: nil)
        connection = tcpConnection
        state = .connectingProxy

        stateObservation = tcpConnection.observe(\.state, options: [.initial, .new]) { [weak self] conn, _ in
            TSIPStack.stack.processQueue.async {
                self?.handleConnectionState(conn.state)
            }
        }

        NSLog("[PH-RELAY] mitm relay start %@ via 127.0.0.1:8034", relayID)
    }

    private func handleConnectionState(_ newState: NWTCPConnectionState) {
        NSLog("[PH-RELAY] mitm %@ NWTCPConnection state=%ld", relayID, newState.rawValue)
        guard !isClosed else {
            NSLog("[PH-RELAY] mitm %@ ignoring state change (already closed)", relayID)
            return
        }

        switch newState {
        case .connected:
            NSLog("[PH-RELAY] mitm %@ proxy connected, targetPort=%d", relayID, targetPort)
            session.connectedTime = NSNumber(value: Date().timeIntervalSince1970)
            onProxyConnected()
        case .disconnected, .cancelled, .invalid:
            closeOnProcessQueue(reason: "proxy connection state=\(newState.rawValue)", closeSocket: true)
        case .waiting:
            NSLog("[PH-RELAY] mitm %@ waiting", relayID)
        case .connecting:
            NSLog("[PH-RELAY] mitm %@ connecting to proxy...", relayID)
        @unknown default:
            break
        }
    }

    // FIX: Port 443 needs CONNECT handshake, port 80 goes directly to relay
    private func onProxyConnected() {
        if targetPort == 443 {
            NSLog("[PH-RELAY] mitm %@ sending CONNECT to %@:%d", relayID, targetHost, targetPort)
            sendConnectRequest()
        } else {
            // Port 80: direct relay, HttpMatcher in MitmService will detect HTTP method
            NSLog("[PH-RELAY] mitm %@ port 80 direct relay mode", relayID)
            state = .relaying
            session.note = "transparent mitm relay direct"
            try? session.saveToDB()
            flushPendingClientData()
            readRemoteLoop()
        }
    }

    private func sendConnectRequest() {
        guard !isClosed, let connection else { return }

        state = .waitingConnectResponse
        let connectRequest = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n\r\n"
        guard let requestData = connectRequest.data(using: .utf8) else {
            closeOnProcessQueue(reason: "build CONNECT failed", closeSocket: true)
            return
        }

        connection.write(requestData) { [weak self] error in
            TSIPStack.stack.processQueue.async {
                guard let self, !self.isClosed else { return }
                if let error {
                    NSLog("[PH-RELAY] mitm %@ CONNECT write error: %@", self.relayID, error.localizedDescription)
                    self.closeOnProcessQueue(reason: "CONNECT write failed: \(error.localizedDescription)", closeSocket: true)
                    return
                }
                NSLog("[PH-RELAY] mitm %@ CONNECT request sent, reading response...", self.relayID)
                self.readConnectResponse()
            }
        }
    }

    private func readConnectResponse() {
        guard !isClosed, let connection else { return }

        connection.readMinimumLength(1, maximumLength: 8192) { [weak self] data, error in
            TSIPStack.stack.processQueue.async {
                guard let self, !self.isClosed else { return }

                if let error {
                    self.closeOnProcessQueue(reason: "CONNECT read failed: \(error.localizedDescription)", closeSocket: true)
                    return
                }

                guard let data, !data.isEmpty else {
                    self.closeOnProcessQueue(reason: "CONNECT response EOF", closeSocket: true)
                    return
                }

                self.lastActivity = Date()
                self.connectResponseBuffer.append(data)

                guard let delimiter = self.connectResponseBuffer.range(of: Data([13, 10, 13, 10])) else {
                    self.readConnectResponse()
                    return
                }

                let headerData = self.connectResponseBuffer.subdata(in: 0 ..< delimiter.upperBound)
                let tailData = self.connectResponseBuffer.suffix(from: delimiter.upperBound)
                self.connectResponseBuffer.removeAll(keepingCapacity: false)

                guard self.connectSucceeded(headerData) else {
                    let headerStr = String(data: headerData, encoding: .utf8) ?? "<non-utf8>"
                    NSLog("[PH-RELAY] mitm %@ CONNECT rejected: %@", self.relayID, headerStr)
                    self.closeOnProcessQueue(reason: "proxy CONNECT rejected", closeSocket: true)
                    return
                }

                NSLog("[PH-RELAY] mitm %@ CONNECT success, entering relay mode (pending=%d tail=%d)",
                      self.relayID, self.pendingClientData.count, tailData.count)

                self.state = .relaying
                self.session.note = "transparent mitm relay CONNECT ok"
                try? self.session.saveToDB()
                self.flushPendingClientData()

                if !tailData.isEmpty {
                    self.socket.writeData(Data(tailData))
                }

                self.readRemoteLoop()
            }
        }
    }

    private func connectSucceeded(_ headerData: Data) -> Bool {
        guard let text = String(data: headerData, encoding: .utf8),
              let statusLine = text.components(separatedBy: "\r\n").first
        else {
            return false
        }
        return statusLine.contains("200")
    }

    private func flushPendingClientData() {
        guard state == .relaying else { return }
        for pending in pendingClientData {
            writeToRemote(pending)
        }
        pendingClientData.removeAll(keepingCapacity: false)
    }

    private func writeToRemote(_ data: Data) {
        guard !isClosed, let connection else {
            NSLog("[PH-RELAY] mitm %@ writeToRemote SKIP (closed=%d conn=%d) len=%d",
                  relayID, isClosed ? 1 : 0, self.connection == nil ? 0 : 1, data.count)
            return
        }
        NSLog("[PH-RELAY] mitm %@ -> proxy %d bytes", relayID, data.count)
        connection.write(data) { [weak self] error in
            TSIPStack.stack.processQueue.async {
                guard let self, !self.isClosed else { return }
                if let error {
                    self.closeOnProcessQueue(reason: "remote write failed: \(error.localizedDescription)", closeSocket: true)
                }
            }
        }
    }

    private func readRemoteLoop() {
        guard !isClosed, state == .relaying, let connection else { return }

        connection.readMinimumLength(1, maximumLength: 65_536) { [weak self] data, error in
            TSIPStack.stack.processQueue.async {
                guard let self, !self.isClosed else { return }

                if let error {
                    self.closeOnProcessQueue(reason: "remote read failed: \(error.localizedDescription)", closeSocket: true)
                    return
                }

                guard let data, !data.isEmpty else {
                    self.closeOnProcessQueue(reason: "remote EOF", closeSocket: true)
                    return
                }

                self.lastActivity = Date()
                self.downloadBytes += data.count
                self.session.downloadFlow = NSNumber(value: self.downloadBytes)
                NSLog("[PH-RELAY] mitm %@ proxy -> app %d bytes (total down=%d)", self.relayID, data.count, self.downloadBytes)
                self.socket.writeData(data)

                self.readRemoteLoop()
            }
        }
    }

    private func closeOnProcessQueue(reason: String, closeSocket: Bool) {
        guard !isClosed else { return }
        isClosed = true
        state = .closed

        NSLog("[PH-RELAY] mitm CLOSE %@ reason=%@ up=%d down=%d", relayID, reason, uploadBytes, downloadBytes)

        stateObservation = nil
        connection?.cancel()
        connection = nil

        if closeSocket, socket.isConnected {
            socket.close()
        }

        session.uploadTraffic = NSNumber(value: uploadBytes)
        session.downloadFlow = NSNumber(value: downloadBytes)
        session.endTime = NSNumber(value: Date().timeIntervalSince1970)
        try? session.saveToDB()

        onClose(relayID)
        NSLog("[PH-RELAY] mitm relay closed %@ reason=%@", relayID, reason)
    }

    // MARK: - TSTCPSocketDelegate

    func localDidClose(_ socket: TSTCPSocket) {
        closeOnProcessQueue(reason: "local did close", closeSocket: false)
    }

    func socketDidReset(_ socket: TSTCPSocket) {
        closeOnProcessQueue(reason: "local reset", closeSocket: false)
    }

    func socketDidAbort(_ socket: TSTCPSocket) {
        closeOnProcessQueue(reason: "local abort", closeSocket: false)
    }

    func socketDidClose(_ socket: TSTCPSocket) {
        closeOnProcessQueue(reason: "local close", closeSocket: false)
    }

    func didReadData(_ data: Data, from: TSTCPSocket) {
        guard !isClosed else { return }

        lastActivity = Date()
        uploadBytes += data.count
        session.uploadTraffic = NSNumber(value: uploadBytes)
        NSLog("[PH-RELAY] mitm %@ app -> relay %d bytes state=%d (total up=%d)", relayID, data.count, state == .relaying ? 1 : 0, uploadBytes)

        switch state {
        case .relaying:
            writeToRemote(data)
        case .connectingProxy, .waitingConnectResponse:
            pendingClientData.append(data)
        case .closed:
            break
        }
    }

    func didWriteData(_ length: Int, from: TSTCPSocket) {
        if length > 0 { lastActivity = Date() }
    }
}
#endif
