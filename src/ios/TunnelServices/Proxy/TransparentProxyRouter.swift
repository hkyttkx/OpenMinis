// PH3模式不需要此文件，已禁用编译
#if false
import Foundation
import NetworkExtension
import Darwin

protocol TransparentTCPRelay: AnyObject {
    var relayID: String { get }
    var lastActivity: Date { get }
    func start()
    func close()
}

public final class TransparentProxyRouter: NSObject, TSIPStackDelegate {
    private weak var provider: NEPacketTunnelProvider?
    private let task: Task
    private let fakeIPPool: FakeIPPool

    private var activeRelays: [String: TransparentTCPRelay] = [:]
    private var relayOrder: [String] = []
    private let maxActiveRelays = 500

    public init(provider: NEPacketTunnelProvider, task: Task, fakeIPPool: FakeIPPool) {
        self.provider = provider
        self.task = task
        self.fakeIPPool = fakeIPPool
        super.init()
    }

    public func didAcceptTCPSocket(_ sock: TSTCPSocket) {
        let processQueue = TSIPStack.stack.processQueue

        let sourceIP = ipv4String(from: sock.sourceAddress)
        let destinationIP = ipv4String(from: sock.destinationAddress)
        let sourcePort = sock.sourcePort
        let destinationPort = sock.destinationPort
        let relayID = "\(sourceIP):\(sourcePort)->\(destinationIP):\(destinationPort)"

        guard let provider else {
            NSLog("[PH-RELAY] provider released, reset %@", relayID)
            processQueue.async { sock.reset() }
            return
        }

        if activeRelays[relayID] != nil {
            NSLog("[PH-RELAY] duplicate relay %@, reset socket", relayID)
            processQueue.async { sock.reset() }
            return
        }

        let mappedHost = fakeIPPool.lookup(fakeIP: destinationIP)
        if fakeIPPool.isFakeIP(destinationIP), mappedHost == nil {
            NSLog("[PH-RELAY] unresolved fake-ip %@, reset %@", destinationIP, relayID)
            processQueue.async { sock.reset() }
            return
        }

        let targetHost = mappedHost ?? destinationIP

        if activeRelays.count >= maxActiveRelays,
           let oldest = relayOrder.first,
           let relay = activeRelays[oldest] {
            NSLog("[PH-RELAY] relay cap reached, closing oldest %@", oldest)
            relay.close()
            activeRelays.removeValue(forKey: oldest)
            relayOrder.removeFirst()
        }

        let onClose: (String) -> Void = { [weak self] key in
            TSIPStack.stack.processQueue.async {
                self?.removeRelay(key)
            }
        }

        let relay: TransparentTCPRelay
        if destinationPort == 80 || destinationPort == 443 {
            relay = MitmTCPRelay(
                relayID: relayID,
                socket: sock,
                provider: provider,
                task: task,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                targetHost: targetHost,
                targetPort: destinationPort,
                onClose: onClose
            )
        } else {
            relay = DirectTCPRelay(
                relayID: relayID,
                socket: sock,
                provider: provider,
                task: task,
                sourceIP: sourceIP,
                sourcePort: sourcePort,
                destinationIP: destinationIP,
                targetHost: targetHost,
                targetPort: destinationPort,
                onClose: onClose
            )
        }

        activeRelays[relayID] = relay
        relayOrder.append(relayID)

        NSLog("[PH-RELAY] accepted %@ target=%@:%d type=%@ activeCount=%d",
              relayID, targetHost, destinationPort,
              (destinationPort == 80 || destinationPort == 443) ? "mitm" : "direct",
              activeRelays.count)
        relay.start()
    }

    public func shutdown() {
        TSIPStack.stack.processQueue.async {
            for relay in self.activeRelays.values {
                relay.close()
            }
            self.activeRelays.removeAll()
            self.relayOrder.removeAll()
            NSLog("[PH-RELAY] router shutdown complete")
        }
    }

    private func removeRelay(_ relayID: String) {
        activeRelays.removeValue(forKey: relayID)
        if let idx = relayOrder.firstIndex(of: relayID) {
            relayOrder.remove(at: idx)
        }
    }

    private func ipv4String(from address: in_addr) -> String {
        var mutableAddress = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = inet_ntop(AF_INET, &mutableAddress, &buffer, socklen_t(INET_ADDRSTRLEN))
        guard result != nil else { return "0.0.0.0" }
        return String(cString: buffer)
    }
}
#endif
