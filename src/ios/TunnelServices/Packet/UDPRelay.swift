import Foundation
import NetworkExtension
import NIO

/// UDP relay — currently record-only mode.
/// NWConnection forwarding is disabled to avoid VPN routing loops.
/// Tracks datagram metadata (5-tuple, payload size) in Session.
public class UDPRelay {
    let key: ConnectionKey
    let session: Session
    weak var packetFlow: NEPacketTunnelFlow?

    var uploadBytes: Int = 0
    var downloadBytes: Int = 0
    var lastActivityTime: Date
    static let idleTimeout: TimeInterval = 30

    var onClose: (() -> Void)?

    private let relayQueue: DispatchQueue
    private let allocator = ByteBufferAllocator()
    private var isClosed = false

    init(key: ConnectionKey, session: Session, packetFlow: NEPacketTunnelFlow) {
        self.key = key
        self.session = session
        self.packetFlow = packetFlow
        self.lastActivityTime = Date()
        self.relayQueue = DispatchQueue(label: "com.packethound.udp.\(key.srcPort)-\(key.dstPort)")

        session.state = "active"
        persistSession()
    }

    /// Record UDP datagram — no forwarding
    func forward(_ packet: ParsedPacket) {
        relayQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }

            self.lastActivityTime = Date()
            let payload = packet.payload

            if !payload.isEmpty {
                self.writeBody(payload, isRequest: true)
                self.uploadBytes += payload.count
                self.session.uploadTraffic = NSNumber(value: self.uploadBytes)
                self.persistSession()
            }
        }
    }

    func close() {
        relayQueue.async { [weak self] in
            self?.closeLocked()
        }
    }

    func isClosedState() -> Bool {
        relayQueue.sync { isClosed }
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
        guard !isClosed else { return }
        isClosed = true

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
