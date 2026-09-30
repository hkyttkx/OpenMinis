// PH3模式不需要此文件，已禁用编译
#if false
import Foundation

public final class FakeIPPool {
    private static let baseOctet0: UInt8 = 198
    private static let baseOctet1: UInt8 = 18
    private static let maxHosts: UInt32 = 65_534

    private let queue = DispatchQueue(label: "com.packethound.fakeip.pool")
    private var hostToIP: [String: String] = [:]
    private var ipToHost: [String: String] = [:]
    private var allocationOrder: [String] = []
    private var nextIndex: UInt32 = 1

    public init() {}

    @discardableResult
    public func allocate(hostname: String) -> String {
        queue.sync {
            let normalized = normalize(hostname: hostname)
            guard !normalized.isEmpty else {
                return ""
            }

            if let cached = hostToIP[normalized] {
                return cached
            }

            if hostToIP.count >= Int(Self.maxHosts),
               let evictHost = allocationOrder.first,
               let reusedIP = hostToIP.removeValue(forKey: evictHost) {
                allocationOrder.removeFirst()
                ipToHost.removeValue(forKey: reusedIP)
                hostToIP[normalized] = reusedIP
                ipToHost[reusedIP] = normalized
                allocationOrder.append(normalized)
                NSLog("[PH-DNS] fake-ip pool full, evict %@ -> %@", evictHost, reusedIP)
                return reusedIP
            }

            var attempt: UInt32 = 0
            while attempt < Self.maxHosts {
                let candidateIndex = nextIndex
                nextIndex = (nextIndex % Self.maxHosts) + 1
                let candidateIP = ipString(for: candidateIndex)
                if ipToHost[candidateIP] == nil {
                    hostToIP[normalized] = candidateIP
                    ipToHost[candidateIP] = normalized
                    allocationOrder.append(normalized)
                    NSLog("[PH-DNS] fake-ip allocate %@ -> %@", normalized, candidateIP)
                    return candidateIP
                }
                attempt += 1
            }

            NSLog("[PH-DNS] fake-ip allocate failed for %@", normalized)
            return ""
        }
    }

    public func lookup(fakeIP: String) -> String? {
        queue.sync {
            ipToHost[fakeIP]
        }
    }

    public func isFakeIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              let a = UInt8(parts[0]),
              let b = UInt8(parts[1]),
              a == Self.baseOctet0,
              b == Self.baseOctet1
        else {
            return false
        }

        guard let c = UInt8(parts[2]), let d = UInt8(parts[3]) else {
            return false
        }
        let index = UInt32(c) << 8 | UInt32(d)
        return index >= 1 && index <= Self.maxHosts
    }

    private func normalize(hostname: String) -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return ""
        }
        if trimmed.hasSuffix(".") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private func ipString(for index: UInt32) -> String {
        let octet2 = UInt8((index >> 8) & 0xFF)
        let octet3 = UInt8(index & 0xFF)
        return "\(Self.baseOctet0).\(Self.baseOctet1).\(octet2).\(octet3)"
    }
}
#endif
