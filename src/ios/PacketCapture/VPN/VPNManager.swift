import Foundation
import NetworkExtension

final class VPNManager: ObservableObject {
    static let providerBundleIdentifier = "com.openminis.app.PacketTunnel"
    static let appGroupIdentifier = "group.com.openminis.app"

    @Published var isConnected: Bool = false
    @Published var status: NEVPNStatus = .invalid

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        loadManager()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func loadManager(completion: (() -> Void)? = nil) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }

            if let error {
                NSLog("Failed to load VPN managers: \(error.localizedDescription)")
                return
            }

            let selectedManager = managers?.first ?? NETunnelProviderManager()
            self.configure(manager: selectedManager)

            selectedManager.saveToPreferences { [weak self] error in
                guard let self else { return }

                if let error {
                    NSLog("Failed to save VPN manager: \(error.localizedDescription)")
                    return
                }

                selectedManager.loadFromPreferences { [weak self] error in
                    guard let self else { return }

                    if let error {
                        NSLog("Failed to reload VPN manager: \(error.localizedDescription)")
                        return
                    }

                    self.manager = selectedManager
                    self.refreshStatus()
                    completion?()
                }
            }
        }
    }

    func startVPN() {
        guard let manager else {
            loadManager { [weak self] in
                self?.startVPN()
            }
            return
        }

        guard let session = manager.connection as? NETunnelProviderSession else {
            NSLog("Failed to start VPN: invalid tunnel provider session")
            return
        }

        do {
            try session.startTunnel(options: nil)
            refreshStatus()
        } catch {
            NSLog("Failed to start VPN: \(error.localizedDescription)")
        }
    }

    func stopVPN() {
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    private func configure(manager: NETunnelProviderManager) {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
        tunnelProtocol.serverAddress = "VPN抓包"
        tunnelProtocol.disconnectOnSleep = false
        tunnelProtocol.providerConfiguration = [
            "appGroup": Self.appGroupIdentifier
        ]

        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "VPN抓包"
        manager.isEnabled = true
    }

    private func refreshStatus() {
        let connectionStatus = manager?.connection.status ?? .invalid
        DispatchQueue.main.async {
            self.status = connectionStatus
            self.isConnected = connectionStatus == .connected
        }
    }
}
