// PH3模式不需要此文件，已禁用编译
#if false
import Foundation

@objcMembers
public final class TCPFrame: ASModel {
    public var session_id: NSNumber?
    public var idx: NSNumber = 0
    public var direction: String = ""
    public var size: NSNumber = 0
    public var contentType: String = ""
    public var payload: String = ""
    public var payload_file: String = ""
    public var timestamp: NSNumber = 0

    public override class var nameOfTable: String {
        "tcp_frames"
    }

    public override func doubleTypes() -> [String] {
        ["timestamp"]
    }

    public static func frames(sessionID: NSNumber) -> [TCPFrame] {
        findAll(["session_id": sessionID], ["idx": true, "timestamp": true, "id": true])
    }
}
#endif
