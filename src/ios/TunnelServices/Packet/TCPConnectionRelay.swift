import Foundation
import NetworkExtension
import NIO

/// TCP connection relay — currently record-only mode.
/// NWConnection forwarding is disabled to avoid VPN routing loops.
/// Tracks connection metadata (5-tuple, flags, payload size) in Session.
public class TCPConnectionRelay {
    let key: ConnectionKey
    let session: Session
    weak var packetFlow: NEPacketTunnelFlow?

    var uploadBytes: Int = 0
    var downloadBytes: Int = 0
    var lastActivityTime: Date

    private var state: TCPState
    var onClose: (() -> Void)?

    private let relayQueue: DispatchQueue
    private let allocator = ByteBufferAllocator()

    enum TCPState {
        case active
        case closed
    }

    init(key: ConnectionKey, session: Session, initialPacket: ParsedPacket, packetFlow: NEPacketTunnelFlow) {
        self.key = key
        self.session = session
        self.packetFlow = packetFlow
        self.state = .active
        self.lastActivityTime = Date()
        self.relayQueue = DispatchQueue(label: "com.packethound.tcp.\(key.srcPort)-\(key.dstPort)")

        // Record initial SYN
        let payloadSize = initialPacket.payload.count
        if payloadSize > 0 {
            writeBody(initialPacket.payload, isRequest: true)
            uploadBytes += payloadSize
        }
        session.uploadTraffic = NSNumber(value: uploadBytes)
        session.state = "active"
        persistSession()
    }

    /// Handle packet from client — record metadata only
    func handleClientPacket(_ packet: ParsedPacket) {
        relayQueue.async { [weak self] in
            guard let self, self.state != .closed else { return }

            self.lastActivityTime = Date()
            let flags = packet.tcpFlags ?? 0

            // Record payload
            if !packet.payload.isEmpty {
                self.writeBody(packet.payload, isRequest: true)
                self.uploadBytes += packet.payload.count
                self.session.uploadTraffic = NSNumber(value: self.uploadBytes)
                self.persistSession()
            }

            // Detect connection close
            let hasRST = (flags & 0x04) != 0
            let hasFIN = (flags & 0x01) != 0
            if hasRST || hasFIN {
                self.closeLocked()
            }
        }
    }

    func close() {
        relayQueue.async { [weak self] in
            self?.closeLocked()
        }
    }

    func isClosedState() -> Bool {
        relayQueue.sync { state == .closed }
    }

    func lastActivitySnapshot() -> Date {
        relayQueue.sync { lastActivityTime }
    }

    private func writeBody(_ data: Data, isRequest: Bool) {
        guard !data.isEmpty else { return }
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        session.writeBody(type: isRequest ? .REQ : .RSP, buffer: buffer)
    }

    private func persistSession() {
        try? session.saveToDB()
    }

    private func closeLocked() {
        guard state != .closed else { return }
        state = .closed

        session.uploadTraffic = NSNumber(value: uploadBytes)
        session.downloadFlow = NSNumber(value: downloadBytes)
        session.endTime = NSNumber(value: Date().timeIntervalSince1970)
        session.state = "closed"
        persistSession()

        let cb = onClose
        onClose = nil
        cb?()
    }
}
