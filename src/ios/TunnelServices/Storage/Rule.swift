import Foundation

public enum RuleDefaultStrategy: Int {
    case INTERCEPT = 0
    case COPY = 1
}

@objcMembers
public final class Rule: ASModel {
    public var name: String = "Default"
    public var defaultStrategyValue: NSNumber = NSNumber(value: RuleDefaultStrategy.INTERCEPT.rawValue)
    public var hostFilters: String = ""
    public var uriFilters: String = ""
    public var targetFilters: String = ""
    public var extra: String = ""

    public var defaultStrategy: RuleDefaultStrategy = .INTERCEPT
    private var parsedHostFilters: [String] = []
    private var parsedURIFilters: [String] = []
    private var parsedTargetFilters: [String] = []

    public override class var isSaveDefaulttimestamp: Bool {
        true
    }

    public override func transientTypes() -> [String] {
        ["defaultStrategy", "parsedHostFilters", "parsedURIFilters", "parsedTargetFilters"]
    }

    public static func defaultRule() -> Rule {
        let rule = Rule()
        rule.name = "Default"
        rule.defaultStrategyValue = NSNumber(value: RuleDefaultStrategy.INTERCEPT.rawValue)
        rule.hostFilters = ""
        rule.uriFilters = ""
        rule.targetFilters = ""
        rule.extra = ""
        rule.configParse()
        return rule
    }

    public func configParse() {
        if let parsedStrategy = RuleDefaultStrategy(rawValue: defaultStrategyValue.intValue) {
            defaultStrategy = parsedStrategy
        } else {
            defaultStrategy = .INTERCEPT
        }

        parsedHostFilters = parseFilters(hostFilters)
        parsedURIFilters = parseFilters(uriFilters)
        parsedTargetFilters = parseFilters(targetFilters)
    }

    public func saveToDB() throws {
        try save()
    }

    public func matching(host: String, uri: String, target: String) -> Bool {
        if parsedHostFilters.isEmpty && parsedURIFilters.isEmpty && parsedTargetFilters.isEmpty {
            configParse()
        }

        if parsedHostFilters.contains(where: { host.lowercased().contains($0) }) {
            return true
        }
        if parsedURIFilters.contains(where: { uri.lowercased().contains($0) }) {
            return true
        }
        if parsedTargetFilters.contains(where: { target.lowercased().contains($0) }) {
            return true
        }
        return false
    }

    private func parseFilters(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ",", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
