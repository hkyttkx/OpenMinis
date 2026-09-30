import Foundation

@objcMembers
public final class WSFrame: ASModel {
    public var session_id: NSNumber?
    public var direction: String = ""
    public var opcode: NSNumber = 0
    public var payload: String = ""
    public var payload_file: String = ""
    public var timestamp: NSNumber = 0

    public override class var nameOfTable: String {
        "ws_frames"
    }

    public override func doubleTypes() -> [String] {
        ["timestamp"]
    }

    public static func frames(sessionID: NSNumber) -> [WSFrame] {
        findAll(["session_id": sessionID], ["timestamp": true, "id": true])
    }
}
