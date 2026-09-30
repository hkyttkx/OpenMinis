import Foundation
import Network
import NetworkExtension
import TunnelServices

private enum PacketTunnelError: LocalizedError {
    case servicePreparationFailed

    var errorDescription: String? {
        switch self {
        case .servicePreparationFailed:
            return "Failed to prepare MitmService."
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let startStateQueue = DispatchQueue(label: "com.openminis.app.packet-tunnel.start-state")
    private var didStartApplyingSettings = false
    private var didSendStartCompletion = false

    private var mitmService: MitmService?
    private var packetForwarder: PacketForwarder?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        _ = options
        NSLog("[PH-DEBUG] startTunnel called")
        resetStartState()

        guard let service = MitmService.prepare() else {
            NSLog("[PH-DEBUG] MitmService.prepare() returned nil!")
            finishStartOnce(error: PacketTunnelError.servicePreparationFailed, completionHandler: completionHandler)
            return
        }

        NSLog("[PH-DEBUG] MitmService prepared, running...")
        mitmService = service
        service.run { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                NSLog("[PH-DEBUG] MitmService.run() success")
                guard self.markSettingsApplicationStartedIfNeeded() else {
                    NSLog("[PH-DEBUG] markSettingsApplicationStartedIfNeeded returned false")
                    return
                }
                self.applyTunnelSettings(with: service, completionHandler: completionHandler)
            case .failure(let error):
                NSLog("[PH-DEBUG] MitmService.run() failure: %@", error.localizedDescription)
                service.close(nil)
                self.mitmService = nil
                self.finishStartOnce(error: error, completionHandler: completionHandler)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        _ = reason
        packetForwarder?.shutdown()
        packetForwarder = nil

        let service = mitmService
        mitmService = nil

        guard let service else {
            completionHandler()
            return
        }

        service.close {
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        _ = messageData
        completionHandler?(nil)
    }

    private func applyTunnelSettings(with service: MitmService, completionHandler: @escaping (Error?) -> Void) {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.169.89.2")
        networkSettings.mtu = 1500

        let proxySettings = NEProxySettings()
        proxySettings.httpEnabled = true
        proxySettings.httpServer = NEProxyServer(address: "127.0.0.1", port: 8034)
        proxySettings.httpsEnabled = true
        proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: 8034)
        proxySettings.matchDomains = [""]
        proxySettings.excludeSimpleHostnames = true
        proxySettings.exceptionList = ["127.0.0.1", "localhost", "*.local"]
        networkSettings.proxySettings = proxySettings

        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "8.8.4.4"])
        dnsSettings.matchDomains = [""]
        networkSettings.dnsSettings = dnsSettings

        let ipv4Settings = NEIPv4Settings(addresses: ["192.169.89.1"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        networkSettings.ipv4Settings = ipv4Settings

        setTunnelNetworkSettings(networkSettings) { [weak self] error in
            guard let self else { return }

            if let error {
                NSLog("[PH-DEBUG] setTunnelNetworkSettings error: %@", error.localizedDescription)
                service.close(nil)
                self.mitmService = nil
                self.packetForwarder = nil
                self.finishStartOnce(error: error, completionHandler: completionHandler)
                return
            }

            NSLog("[PH-DEBUG] Tunnel settings applied, starting packet drain")
            self.packetForwarder = PacketForwarder(packetFlow: self.packetFlow, task: service.task)
            self.startPacketDrain()
            self.finishStartOnce(error: nil, completionHandler: completionHandler)
            NSLog("[PH-DEBUG] Tunnel fully started")
        }
    }

    private func startPacketDrain() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }

            for packetData in packets {
                if let parsed = PacketParser.parse(packetData) {
                    self.packetForwarder?.handlePacket(parsed)
                }
            }

            self.startPacketDrain()
        }
    }

    private func resetStartState() {
        startStateQueue.sync {
            didStartApplyingSettings = false
            didSendStartCompletion = false
        }
    }

    private func markSettingsApplicationStartedIfNeeded() -> Bool {
        startStateQueue.sync {
            guard !didSendStartCompletion, !didStartApplyingSettings else {
                return false
            }
            didStartApplyingSettings = true
            return true
        }
    }

    private func finishStartOnce(error: Error?, completionHandler: @escaping (Error?) -> Void) {
        let shouldComplete = startStateQueue.sync { () -> Bool in
            guard !didSendStartCompletion else {
                return false
            }
            didSendStartCompletion = true
            return true
        }

        if shouldComplete {
            completionHandler(error)
        }
    }
}
