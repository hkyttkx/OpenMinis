import Foundation

@objcMembers
public final class RewriteRule: ASModel {
    public var enabled: NSNumber = 1
    public var name: String = ""
    public var url_pattern: String = ""
    public var match_type: String = "glob"
    public var action_type: String = ""
    public var action_config: String = "{}"
    public var priority: NSNumber = 0

    public override class var nameOfTable: String {
        "rewrite_rules"
    }

    public override class var isSaveDefaulttimestamp: Bool {
        true
    }

    public var isEnabled: Bool {
        enabled.intValue != 0
    }

    public static func enabledRules() -> [RewriteRule] {
        findAll(["enabled": NSNumber(value: 1)], ["priority": false, "id": false])
    }
}
