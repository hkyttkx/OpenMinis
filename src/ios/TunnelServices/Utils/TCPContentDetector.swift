// PH3模式不需要此文件，已禁用编译
#if false
import Foundation

public enum TCPContentType: String {
    case json = "json"
    case text = "text"
    case xml = "xml"
    case html = "html"
    case urlEncoded = "urlEncoded"
    case formData = "formData"
    case binary = "binary"
    case tls = "tls"
    case http = "http"
}

public struct TCPContentDetector {
    public static func detect(_ data: Data) -> TCPContentType {
        guard !data.isEmpty else { return .binary }

        if data.count >= 3 {
            let first = data[data.startIndex]
            if first == 0x16 || first == 0x17 {
                let major = data[data.startIndex + 1]
                let minor = data[data.startIndex + 2]
                if major == 0x03 && (minor >= 0x00 && minor <= 0x04) {
                    return .tls
                }
            }
        }

        if let prefix = String(data: data.prefix(16), encoding: .utf8) {
            let upper = prefix.uppercased()
            if upper.hasPrefix("GET ") || upper.hasPrefix("POST ") || upper.hasPrefix("PUT ") ||
                upper.hasPrefix("HEAD ") || upper.hasPrefix("DELETE ") || upper.hasPrefix("PATCH ") ||
                upper.hasPrefix("OPTIONS ") || upper.hasPrefix("CONNECT ") || upper.hasPrefix("HTTP/") {
                return .http
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .binary
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .json
            }
        }

        let lower = trimmed.lowercased()
        if trimmed.hasPrefix("<") {
            if lower.contains("<html") || lower.contains("<!doctype html") {
                return .html
            }
            if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<") {
                return .xml
            }
        }

        if lower.contains("content-disposition: form-data") ||
            (trimmed.hasPrefix("--") && lower.contains("form-data")) {
            return .formData
        }

        if trimmed.contains("=") && !trimmed.contains(" ") &&
            trimmed.range(of: "^[\\w%+.-]+=.*$", options: .regularExpression) != nil {
            return .urlEncoded
        }

        let printableCount = text.unicodeScalars.filter {
            ($0.value >= 0x20 && $0.value < 0x7F) ||
                $0.value == 0x0A ||
                $0.value == 0x0D ||
                $0.value == 0x09
        }.count

        if !text.isEmpty, Double(printableCount) / Double(text.count) > 0.85 {
            return .text
        }

        return .binary
    }

    public static func formatPayload(_ data: Data, contentType: TCPContentType) -> String? {
        switch contentType {
        case .json:
            if let obj = try? JSONSerialization.jsonObject(with: data),
                let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                let str = String(data: pretty, encoding: .utf8) {
                return str
            }
            return String(data: data, encoding: .utf8)
        case .text, .xml, .html, .http, .urlEncoded, .formData:
            return String(data: data, encoding: .utf8)
        case .tls:
            return "[TLS Record - \(data.count) bytes]"
        case .binary:
            return nil
        }
    }
}
#endif
