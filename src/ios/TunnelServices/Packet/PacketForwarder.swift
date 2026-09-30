import Foundation
import Network
import NetworkExtension

struct ConnectionKey: Hashable {
    let srcIP: String
    let srcPort: UInt16
    let dstIP: String
    let dstPort: UInt16
    let proto: UInt8 // 6=TCP, 17=UDP
}

public class PacketForwarder {
    private var tcpConnections: [ConnectionKey: TCPConnectionRelay] = [:]
    private var udpRelays: [ConnectionKey: UDPRelay] = [:]
    private let queue = DispatchQueue(label: "com.packethound.packet-forwarder")
    private weak var packetFlow: NEPacketTunnelFlow?
    private let task: Task

    // 清理定时器
    private var cleanupTimer: DispatchSourceTimer?
    private let maxTCPConnections = 500
    private let maxUDPRelays = 200
    private let tcpIdleTimeout: TimeInterval = 120
    private let udpIdleTimeout: TimeInterval = 30

    public init(packetFlow: NEPacketTunnelFlow, task: Task) {
        self.packetFlow = packetFlow
        self.task = task
        startCleanupTimer()
    }

    /// 处理一个解析后的包
    public func handlePacket(_ packet: ParsedPacket) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            switch packet.protocolNumber {
            case 6:
                self.handleTCP(packet)
            case 17:
                self.handleUDP(packet)
            default:
                break
            }
        }
    }

    /// 关闭所有连接
    public func shutdown() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.cleanupTimer?.cancel()
            self.cleanupTimer = nil

            for (_, relay) in self.tcpConnections {
                relay.close()
            }
            self.tcpConnections.removeAll()

            for (_, relay) in self.udpRelays {
                relay.close()
            }
            self.udpRelays.removeAll()
        }
    }

    // 内部方法
    private func handleTCP(_ packet: ParsedPacket) {
        guard packet.protocolNumber == 6 else {
            return
        }

        guard !isProxyLoopbackDestination(packet) else {
            return
        }

        let key = ConnectionKey(
            srcIP: packet.sourceIP,
            srcPort: packet.sourcePort,
            dstIP: packet.destIP,
            dstPort: packet.destPort,
            proto: 6
        )

        if let relay = tcpConnections[key] {
            relay.handleClientPacket(packet)
            return
        }

        let flags = packet.tcpFlags ?? 0
        let isSYN = (flags & 0x02) != 0
        if !isSYN {
            return
        }

        guard let packetFlow else {
            return
        }

        if tcpConnections.count >= maxTCPConnections {
            trimTCPConnections(to: maxTCPConnections - 1)
        }

        let session = createSession(for: packet)
        let relay = TCPConnectionRelay(key: key, session: session, initialPacket: packet, packetFlow: packetFlow)
        relay.onClose = { [weak self] in
            self?.queue.async {
                self?.tcpConnections.removeValue(forKey: key)
            }
        }
        tcpConnections[key] = relay
    }

    private func handleUDP(_ packet: ParsedPacket) {
        guard packet.protocolNumber == 17 else {
            return
        }

        guard !isProxyLoopbackDestination(packet) else {
            return
        }

        let key = ConnectionKey(
            srcIP: packet.sourceIP,
            srcPort: packet.sourcePort,
            dstIP: packet.destIP,
            dstPort: packet.destPort,
            proto: 17
        )

        if let relay = udpRelays[key] {
            relay.forward(packet)
            return
        }

        guard let packetFlow else {
            return
        }

        if udpRelays.count >= maxUDPRelays {
            trimUDPRelays(to: maxUDPRelays - 1)
        }

        let session = createSession(for: packet)
        let relay = UDPRelay(key: key, session: session, packetFlow: packetFlow)
        relay.onClose = { [weak self] in
            self?.queue.async {
                self?.udpRelays.removeValue(forKey: key)
            }
        }
        udpRelays[key] = relay
        relay.forward(packet)
    }

    private func cleanupIdleConnections() {
        let now = Date()

        var expiredTCPKeys: [ConnectionKey] = []
        for (key, relay) in tcpConnections {
            let idle = now.timeIntervalSince(relay.lastActivitySnapshot())
            if relay.isClosedState() || idle > tcpIdleTimeout {
                relay.close()
                expiredTCPKeys.append(key)
            }
        }
        for key in expiredTCPKeys {
            tcpConnections.removeValue(forKey: key)
        }

        var expiredUDPKeys: [ConnectionKey] = []
        for (key, relay) in udpRelays {
            let idle = now.timeIntervalSince(relay.lastActivitySnapshot())
            if relay.isClosedState() || idle > min(udpIdleTimeout, UDPRelay.idleTimeout) {
                relay.close()
                expiredUDPKeys.append(key)
            }
        }
        for key in expiredUDPKeys {
            udpRelays.removeValue(forKey: key)
        }

        if tcpConnections.count > maxTCPConnections {
            trimTCPConnections(to: maxTCPConnections)
        }

        if udpRelays.count > maxUDPRelays {
            trimUDPRelays(to: maxUDPRelays)
        }
    }

    private func createSession(for packet: ParsedPacket) -> Session {
        let session = Session.newSession(task)
        session.schemes = packet.protocolNumber == 6 ? "TCP" : "UDP"
        session.methods = session.schemes
        session.host = packet.destIP
        session.uri = "\(packet.destIP):\(packet.destPort)"
        session.remoteAddress = "\(packet.destIP):\(packet.destPort)"
        session.localAddress = "\(packet.sourceIP):\(packet.sourcePort)"
        session.srcIP = packet.sourceIP
        session.srcPort = "\(packet.sourcePort)"
        session.dstIP = packet.destIP
        session.dstPort = "\(packet.destPort)"
        session.protoDetail = detectProtoDetail(for: packet)
        session.note = "packet-forwarder"

        try? session.saveToDB()

        task.interceptCount = NSNumber(value: task.interceptCount.intValue + 1)
        try? task.update()

        return session
    }

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.cleanupIdleConnections()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func isProxyLoopbackDestination(_ packet: ParsedPacket) -> Bool {
        packet.destIP == "127.0.0.1" && packet.destPort == 8034
    }

    private func detectProtoDetail(for packet: ParsedPacket) -> String {
        let srcPort = packet.sourcePort
        let dstPort = packet.destPort

        if packet.protocolNumber == 17 {
            if srcPort == 53 || dstPort == 53 {
                return "DNS"
            }
            if srcPort == 443 || dstPort == 443 {
                return "QUIC"
            }
        }

        if packet.protocolNumber == 6 {
            if srcPort == 443 || dstPort == 443 {
                return "TLS"
            }
        }

        return "UNKNOWN"
    }

    private func trimTCPConnections(to limit: Int) {
        guard tcpConnections.count > limit else {
            return
        }

        let sorted = tcpConnections.sorted { lhs, rhs in
            lhs.value.lastActivitySnapshot() < rhs.value.lastActivitySnapshot()
        }

        let removeCount = tcpConnections.count - limit
        for index in 0 ..< max(0, removeCount) {
            let (key, relay) = sorted[index]
            relay.close()
            tcpConnections.removeValue(forKey: key)
        }
    }

    private func trimUDPRelays(to limit: Int) {
        guard udpRelays.count > limit else {
            return
        }

        let sorted = udpRelays.sorted { lhs, rhs in
            lhs.value.lastActivitySnapshot() < rhs.value.lastActivitySnapshot()
        }

        let removeCount = udpRelays.count - limit
        for index in 0 ..< max(0, removeCount) {
            let (key, relay) = sorted[index]
            relay.close()
            udpRelays.removeValue(forKey: key)
        }
    }
}
