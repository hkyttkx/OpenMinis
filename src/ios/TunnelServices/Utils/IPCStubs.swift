import Foundation

protocol GCDAsyncUdpSocketDelegate: AnyObject {}

final class GCDAsyncUdpSocket {
    init(delegate: GCDAsyncUdpSocketDelegate?, delegateQueue: DispatchQueue?) {}

    func send(_ data: Data, toHost host: String, port: UInt16, withTimeout timeout: TimeInterval, tag: Int) {
        // no-op in the current Phase 2 integration
    }
}

final class MMWormhole {
    private let applicationGroupIdentifier: String
    private let optionalDirectory: String?

    init(applicationGroupIdentifier: String, optionalDirectory: String?) {
        self.applicationGroupIdentifier = applicationGroupIdentifier
        self.optionalDirectory = optionalDirectory
    }

    func listenForMessage(withIdentifier identifier: String, listener: @escaping (Any?) -> Void) {
        // no-op placeholder; host app messaging can be wired in a later phase.
        _ = applicationGroupIdentifier
        _ = optionalDirectory
        _ = identifier
        _ = listener
    }

    func passMessageObject(_ messageObject: Any?, identifier: String) {
        // no-op placeholder; host app messaging can be wired in a later phase.
        _ = applicationGroupIdentifier
        _ = optionalDirectory
        _ = messageObject
        _ = identifier
    }
}
