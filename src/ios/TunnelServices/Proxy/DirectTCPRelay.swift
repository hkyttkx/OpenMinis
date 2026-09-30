// PH3模式不需要此文件，已禁用编译
#if false
import Foundation
import NetworkExtension

final class DirectTCPRelay: NSObject, TransparentTCPRelay, TSTCPSocketDelegate {
    enum RelayState {
        case connectingRemote
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
    private var state: RelayState = .connectingRemote
    private var isClosed = false

    private var pendingClientData: [Data] = []
    private var uploadBytes = 0
    private var downloadBytes = 0
    private let session: Session
    private var frameIndex = 0
    private var detectedProto: String?

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
        newSession.schemes = "TCP"
        newSession.methods = "TCP"
        newSession.host = targetHost
        newSession.uri = "\(targetHost):\(targetPort)"
        newSession.localAddress = "\(sourceIP):\(sourcePort)"
        newSession.remoteAddress = "\(targetHost):\(targetPort)"
        newSession.srcIP = sourceIP
        newSession.srcPort = "\(sourcePort)"
        newSession.dstIP = destinationIP
        newSession.dstPort = "\(targetPort)"
        newSession.protoDetail = "TCP"
        newSession.sstate = "tunnel"
        newSession.note = "transparent direct relay"
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

        let endpoint = NWHostEndpoint(hostname: targetHost, port: "\(targetPort)")
        let tcpConnection = provider.createTCPConnection(to: endpoint, enableTLS: false, tlsParameters: nil, delegate: nil)
        connection = tcpConnection
        state = .connectingRemote

        stateObservation = tcpConnection.observe(\.state, options: [.initial, .new]) { [weak self] conn, _ in
            TSIPStack.stack.processQueue.async {
                self?.handleConnectionState(conn.state)
            }
        }

        NSLog("[PH-RELAY] direct relay start %@ -> %@:%d", relayID, targetHost, targetPort)
    }

    private func handleConnectionState(_ newState: NWTCPConnectionState) {
        NSLog("[PH-RELAY] direct %@ NWTCPConnection state=%ld", relayID, newState.rawValue)
        guard !isClosed else { return }

        switch newState {
        case .connected:
            state = .relaying
            session.connectedTime = NSNumber(value: Date().timeIntervalSince1970)
            try? session.saveToDB()
            flushPendingClientData()
            readRemoteLoop()
        case .disconnected, .cancelled, .invalid:
            closeOnProcessQueue(reason: "remote connection state=\(newState.rawValue)", closeSocket: true)
        case .waiting, .connecting:
            break
        @unknown default:
            break
        }
    }

    private func flushPendingClientData() {
        guard state == .relaying else { return }
        for pending in pendingClientData {
            writeToRemote(pending)
        }
        pendingClientData.removeAll(keepingCapacity: false)
    }

    private func writeToRemote(_ data: Data) {
        guard !isClosed, let connection else { return }
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
                self.session.writeBodyData(type: .RSP, data: data)
                self.saveFrame(data: data, direction: "recv")
                NSLog("[PH-RELAY] direct %@ remote -> app %d bytes (total down=%d)", self.relayID, data.count, self.downloadBytes)
                self.socket.writeData(data)

                self.readRemoteLoop()
            }
        }
    }

    private func closeOnProcessQueue(reason: String, closeSocket: Bool) {
        guard !isClosed else { return }
        isClosed = true
        state = .closed

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
        NSLog("[PH-RELAY] direct relay closed %@ reason=%@", relayID, reason)
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
        session.writeBodyData(type: .REQ, data: data)
        saveFrame(data: data, direction: "send")
        NSLog("[PH-RELAY] direct %@ app -> remote %d bytes state=%d (total up=%d)", relayID, data.count, state == .relaying ? 1 : 0, uploadBytes)

        switch state {
        case .relaying:
            writeToRemote(data)
        case .connectingRemote:
            pendingClientData.append(data)
        case .closed:
            break
        }
    }

    func didWriteData(_ length: Int, from: TSTCPSocket) {
        if length > 0 { lastActivity = Date() }
    }

    private func saveFrame(data: Data, direction: String) {
        guard let sessionId = session.id else { return }

        let contentType = TCPContentDetector.detect(data)
        if detectedProto == nil {
            detectedProto = contentType.rawValue
            session.protoDetail = contentType.rawValue.uppercased()
            try? session.saveToDB()
        }

        let frame = TCPFrame()
        frame.session_id = sessionId
        frame.idx = NSNumber(value: frameIndex)
        frame.direction = direction
        frame.size = NSNumber(value: data.count)
        frame.contentType = contentType.rawValue
        frame.timestamp = NSNumber(value: Date().timeIntervalSince1970)

        if data.count < 4096, let text = TCPContentDetector.formatPayload(data, contentType: contentType) {
            frame.payload = text
        } else {
            let fileName = "tcpframe_\(sessionId.stringValue)_\(frameIndex)"
            frame.payload_file = fileName
            let folder = session.fileFolder ?? "error"
            let filePath = "\(MitmService.getStoreFolder())\(folder)/\(fileName)"
            FileManager.default.createFile(atPath: filePath, contents: data, attributes: nil)
        }

        frameIndex += 1
        try? frame.save()
    }
}
#endif
