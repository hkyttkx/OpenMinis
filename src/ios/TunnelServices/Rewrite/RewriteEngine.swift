import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat

public let RewriteRulesDidChange = "RewriteRulesDidChange"

public final class RewriteEngine {
    public static let shared = RewriteEngine()

    private let lock = NSLock()
    private var cachedRules: [RewriteRule] = []
    private var wormhole: MMWormhole?

    private init() {
        setupWormhole()
        reloadRules()
    }

    public func reloadRules() {
        let loadedRules = RewriteRule.enabledRules().sorted {
            if $0.priority.intValue == $1.priority.intValue {
                return ($0.id?.intValue ?? 0) < ($1.id?.intValue ?? 0)
            }
            return $0.priority.intValue > $1.priority.intValue
        }

        lock.lock()
        cachedRules = loadedRules
        lock.unlock()
    }

    public func notifyRulesChanged() {
        wormhole?.passMessageObject(Date().timeIntervalSince1970, identifier: RewriteRulesDidChange)
        reloadRules()
    }

    public func matchRules(for url: String, method: String) -> [RewriteRule] {
        let methodUpper = method.uppercased()
        let rules = currentRulesSnapshot()

        return rules.filter { rule in
            guard rule.isEnabled else {
                return false
            }

            let config = parseConfig(rule.action_config)
            if let methods = config["methods"] as? [String], !methods.isEmpty {
                let matchedMethod = methods.contains { $0.uppercased() == methodUpper }
                if !matchedMethod {
                    return false
                }
            }

            return urlMatches(url, pattern: rule.url_pattern, matchType: rule.match_type)
        }
    }

    public func applyRequestRewrite(request: inout HTTPRequestHead, rules: [RewriteRule]) {
        guard !rules.isEmpty else {
            return
        }

        for rule in rules {
            let config = parseConfig(rule.action_config)
            switch rule.action_type {
            case "modify_req_header":
                applyHeaderMutation(headers: &request.headers, config: config)
            case "redirect":
                if let redirectURL = config["url"] as? String {
                    applyRedirect(to: redirectURL, request: &request)
                }
            default:
                continue
            }
        }
    }

    public func applyRequestBodyRewrite(body: inout ByteBuffer, rules: [RewriteRule]) {
        guard !rules.isEmpty else {
            return
        }

        for rule in rules where rule.action_type == "modify_body" {
            let config = parseConfig(rule.action_config)
            let target = (config["target"] as? String)?.lowercased() ?? "response"
            guard target == "request" else {
                continue
            }

            guard
                let find = config["find"] as? String,
                let replace = config["replace"] as? String,
                !find.isEmpty
            else {
                continue
            }

            replaceBody(body: &body, find: find, replace: replace)
        }
    }

    public func applyResponseRewrite(response: inout HTTPResponseHead, body: inout ByteBuffer?, rules: [RewriteRule]) {
        guard !rules.isEmpty else {
            return
        }

        for rule in rules {
            let config = parseConfig(rule.action_config)
            switch rule.action_type {
            case "modify_rsp_header":
                applyHeaderMutation(headers: &response.headers, config: config)
            case "modify_body":
                let target = (config["target"] as? String)?.lowercased() ?? "response"
                guard target == "response" else {
                    continue
                }

                guard
                    var payload = body,
                    let find = config["find"] as? String,
                    let replace = config["replace"] as? String,
                    !find.isEmpty
                else {
                    continue
                }

                replaceBody(body: &payload, find: find, replace: replace)
                body = payload
            default:
                continue
            }
        }
    }

    public func shouldBlock(rules: [RewriteRule]) -> (Bool, Int?) {
        for rule in rules where rule.action_type == "block" {
            let config = parseConfig(rule.action_config)
            let statusCode = intValue(config["status_code"]) ?? 403
            return (true, statusCode)
        }
        return (false, nil)
    }

    public func blockBody(rules: [RewriteRule]) -> String? {
        for rule in rules where rule.action_type == "block" {
            let config = parseConfig(rule.action_config)
            if let body = config["body"] as? String {
                return body
            }
            return nil
        }
        return nil
    }

    private func setupWormhole() {
        wormhole = MMWormhole(applicationGroupIdentifier: GROUPNAME, optionalDirectory: "wormhole")
        wormhole?.listenForMessage(withIdentifier: RewriteRulesDidChange) { [weak self] _ in
            self?.reloadRules()
        }
    }

    private func currentRulesSnapshot() -> [RewriteRule] {
        lock.lock()
        let snapshot = cachedRules
        lock.unlock()

        if snapshot.isEmpty {
            reloadRules()
            lock.lock()
            let refreshed = cachedRules
            lock.unlock()
            return refreshed
        }

        return snapshot
    }

    private func parseConfig(_ rawJSON: String) -> [String: Any] {
        guard let data = rawJSON.data(using: .utf8), !data.isEmpty else {
            return [:]
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            return [:]
        }

        return dict
    }

    private func urlMatches(_ url: String, pattern: String, matchType: String) -> Bool {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else {
            return true
        }

        if matchType.lowercased() == "regex" {
            return regexMatch(url, pattern: trimmedPattern)
        }

        return globMatch(url, pattern: trimmedPattern)
    }

    private func regexMatch(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: fullRange) != nil
    }

    private func globMatch(_ text: String, pattern: String) -> Bool {
        if !pattern.contains("*") && !pattern.contains("?") {
            return text.lowercased().contains(pattern.lowercased())
        }

        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")

        let regexPattern = "^\(escaped)$"
        return regexMatch(text, pattern: regexPattern)
    }

    private func applyHeaderMutation(headers: inout HTTPHeaders, config: [String: Any]) {
        if let remove = config["remove"] as? [String] {
            for name in remove {
                headers.remove(name: name)
            }
        }

        if let add = stringMap(config["add"]) {
            for (name, value) in add {
                headers.add(name: name, value: value)
            }
        }

        if let replace = stringMap(config["replace"]) {
            for (name, value) in replace {
                headers.remove(name: name)
                headers.add(name: name, value: value)
            }
        }
    }

    private func applyRedirect(to rawURL: String, request: inout HTTPRequestHead) {
        guard let components = URLComponents(string: rawURL),
              let host = components.host,
              let scheme = components.scheme else {
            return
        }

        request.uri = rawURL

        var hostValue = host
        if let port = components.port {
            let isDefaultPort = (scheme.lowercased() == "http" && port == 80) ||
                (scheme.lowercased() == "https" && port == 443)
            if !isDefaultPort {
                hostValue = "\(host):\(port)"
            }
        }

        request.headers.remove(name: "Host")
        request.headers.add(name: "Host", value: hostValue)
    }

    private func replaceBody(body: inout ByteBuffer, find: String, replace: String) {
        guard let data = body.getData(at: body.readerIndex, length: body.readableBytes),
              let bodyString = String(data: data, encoding: .utf8) else {
            return
        }

        let replaced = bodyString.replacingOccurrences(of: find, with: replace)
        guard replaced != bodyString else {
            return
        }

        var buffer = ByteBufferAllocator().buffer(capacity: replaced.utf8.count)
        buffer.writeString(replaced)
        body = buffer
    }

    private func stringMap(_ value: Any?) -> [String: String]? {
        guard let rawMap = value as? [String: Any] else {
            return nil
        }

        var result: [String: String] = [:]
        for (key, value) in rawMap {
            result[key] = "\(value)"
        }
        return result
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
