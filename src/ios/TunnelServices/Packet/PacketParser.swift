import Foundation

/// 解析后的网络包结构
public struct ParsedPacket {
    public let ipVersion: UInt8          // 4 or 6
    public let protocolNumber: UInt8     // 6=TCP, 17=UDP, 1=ICMP
    public let sourceIP: String
    public let destIP: String
    public let sourcePort: UInt16        // TCP/UDP 端口
    public let destPort: UInt16
    public let payload: Data             // TCP/UDP payload (不含 IP/传输层头部)
    public let rawPacket: Data           // 完整原始包
    public let tcpFlags: UInt8?          // SYN/ACK/FIN/RST (仅 TCP)
    public let tcpSeqNum: UInt32?        // TCP 序列号
    public let tcpAckNum: UInt32?        // TCP 确认号
    public let ipHeaderLength: Int       // IP 头长度
    public let transportHeaderLength: Int // TCP/UDP 头长度
    public let totalLength: Int          // IP 包总长度
}

public struct PacketParser {
    /// 解析原始 IP 包
    public static func parse(_ data: Data) -> ParsedPacket? {
        guard let first = readUInt8(data, at: 0) else {
            return nil
        }

        let version = first >> 4
        switch version {
        case 4:
            return parseIPv4(data)
        case 6:
            return parseIPv6(data)
        default:
            return nil
        }
    }

    private static func parseIPv4(_ data: Data) -> ParsedPacket? {
        guard data.count >= 20 else {
            return nil
        }

        let first = data[0]
        let ihl = Int(first & 0x0F) * 4
        guard ihl >= 20, data.count >= ihl else {
            return nil
        }

        guard
            let totalLengthField = readUInt16(data, at: 2),
            let proto = readUInt8(data, at: 9)
        else {
            return nil
        }

        let totalLength = Int(totalLengthField)
        guard totalLength >= ihl else {
            return nil
        }

        let packetEnd = min(totalLength, data.count)
        guard packetEnd >= ihl else {
            return nil
        }

        let sourceIP = ipv4String(data, start: 12)
        let destIP = ipv4String(data, start: 16)

        return parseTransport(
            data,
            ipVersion: 4,
            protocolNumber: proto,
            sourceIP: sourceIP,
            destIP: destIP,
            ipHeaderLength: ihl,
            payloadEnd: packetEnd,
            totalLength: totalLength
        )
    }

    private static func parseIPv6(_ data: Data) -> ParsedPacket? {
        let headerLength = 40
        guard data.count >= headerLength else {
            return nil
        }

        guard
            let payloadLengthField = readUInt16(data, at: 4),
            let nextHeader = readUInt8(data, at: 6)
        else {
            return nil
        }

        let totalLength = headerLength + Int(payloadLengthField)
        let packetEnd = min(totalLength, data.count)
        guard packetEnd >= headerLength else {
            return nil
        }

        let sourceIP = ipv6String(data, start: 8)
        let destIP = ipv6String(data, start: 24)

        return parseTransport(
            data,
            ipVersion: 6,
            protocolNumber: nextHeader,
            sourceIP: sourceIP,
            destIP: destIP,
            ipHeaderLength: headerLength,
            payloadEnd: packetEnd,
            totalLength: totalLength
        )
    }

    private static func parseTransport(
        _ data: Data,
        ipVersion: UInt8,
        protocolNumber: UInt8,
        sourceIP: String,
        destIP: String,
        ipHeaderLength: Int,
        payloadEnd: Int,
        totalLength: Int
    ) -> ParsedPacket? {
        let transportStart = ipHeaderLength
        guard payloadEnd >= transportStart else {
            return nil
        }

        switch protocolNumber {
        case 6:
            return parseTCP(
                data,
                ipVersion: ipVersion,
                sourceIP: sourceIP,
                destIP: destIP,
                transportStart: transportStart,
                payloadEnd: payloadEnd,
                totalLength: totalLength,
                ipHeaderLength: ipHeaderLength
            )
        case 17:
            return parseUDP(
                data,
                ipVersion: ipVersion,
                sourceIP: sourceIP,
                destIP: destIP,
                transportStart: transportStart,
                payloadEnd: payloadEnd,
                totalLength: totalLength,
                ipHeaderLength: ipHeaderLength
            )
        default:
            return ParsedPacket(
                ipVersion: ipVersion,
                protocolNumber: protocolNumber,
                sourceIP: sourceIP,
                destIP: destIP,
                sourcePort: 0,
                destPort: 0,
                payload: sliceData(data, start: transportStart, end: payloadEnd),
                rawPacket: data,
                tcpFlags: nil,
                tcpSeqNum: nil,
                tcpAckNum: nil,
                ipHeaderLength: ipHeaderLength,
                transportHeaderLength: 0,
                totalLength: totalLength
            )
        }
    }

    private static func parseTCP(
        _ data: Data,
        ipVersion: UInt8,
        sourceIP: String,
        destIP: String,
        transportStart: Int,
        payloadEnd: Int,
        totalLength: Int,
        ipHeaderLength: Int
    ) -> ParsedPacket? {
        guard payloadEnd >= transportStart + 20 else {
            return nil
        }

        guard
            let sourcePort = readUInt16(data, at: transportStart),
            let destPort = readUInt16(data, at: transportStart + 2),
            let seqNum = readUInt32(data, at: transportStart + 4),
            let ackNum = readUInt32(data, at: transportStart + 8),
            let dataOffsetAndReserved = readUInt8(data, at: transportStart + 12),
            let flags = readUInt8(data, at: transportStart + 13)
        else {
            return nil
        }

        let transportHeaderLength = Int(dataOffsetAndReserved >> 4) * 4
        guard transportHeaderLength >= 20, payloadEnd >= transportStart + transportHeaderLength else {
            return nil
        }

        let payloadStart = transportStart + transportHeaderLength
        let payload = sliceData(data, start: payloadStart, end: payloadEnd)

        return ParsedPacket(
            ipVersion: ipVersion,
            protocolNumber: 6,
            sourceIP: sourceIP,
            destIP: destIP,
            sourcePort: sourcePort,
            destPort: destPort,
            payload: payload,
            rawPacket: data,
            tcpFlags: flags,
            tcpSeqNum: seqNum,
            tcpAckNum: ackNum,
            ipHeaderLength: ipHeaderLength,
            transportHeaderLength: transportHeaderLength,
            totalLength: totalLength
        )
    }

    private static func parseUDP(
        _ data: Data,
        ipVersion: UInt8,
        sourceIP: String,
        destIP: String,
        transportStart: Int,
        payloadEnd: Int,
        totalLength: Int,
        ipHeaderLength: Int
    ) -> ParsedPacket? {
        let udpHeaderLength = 8
        guard payloadEnd >= transportStart + udpHeaderLength else {
            return nil
        }

        guard
            let sourcePort = readUInt16(data, at: transportStart),
            let destPort = readUInt16(data, at: transportStart + 2),
            let udpLengthField = readUInt16(data, at: transportStart + 4)
        else {
            return nil
        }

        let udpLength = Int(udpLengthField)
        let declaredEnd: Int
        if udpLength >= udpHeaderLength {
            declaredEnd = min(transportStart + udpLength, payloadEnd)
        } else {
            declaredEnd = payloadEnd
        }

        let payloadStart = transportStart + udpHeaderLength
        let payload = sliceData(data, start: payloadStart, end: declaredEnd)

        return ParsedPacket(
            ipVersion: ipVersion,
            protocolNumber: 17,
            sourceIP: sourceIP,
            destIP: destIP,
            sourcePort: sourcePort,
            destPort: destPort,
            payload: payload,
            rawPacket: data,
            tcpFlags: nil,
            tcpSeqNum: nil,
            tcpAckNum: nil,
            ipHeaderLength: ipHeaderLength,
            transportHeaderLength: udpHeaderLength,
            totalLength: totalLength
        )
    }

    private static func readUInt8(_ data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else {
            return nil
        }
        return data[offset]
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else {
            return nil
        }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else {
            return nil
        }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func ipv4String(_ data: Data, start: Int) -> String {
        guard start >= 0, start + 3 < data.count else {
            return ""
        }
        return "\(data[start]).\(data[start + 1]).\(data[start + 2]).\(data[start + 3])"
    }

    private static func ipv6String(_ data: Data, start: Int) -> String {
        guard start >= 0, start + 15 < data.count else {
            return ""
        }

        var groups: [String] = []
        groups.reserveCapacity(8)
        for i in stride(from: start, to: start + 16, by: 2) {
            let value = (UInt16(data[i]) << 8) | UInt16(data[i + 1])
            groups.append(String(format: "%x", value))
        }
        return groups.joined(separator: ":")
    }

    private static func sliceData(_ data: Data, start: Int, end: Int) -> Data {
        guard start >= 0, end >= start, start <= data.count else {
            return Data()
        }
        let clampedEnd = min(end, data.count)
        guard clampedEnd >= start else {
            return Data()
        }
        return data.subdata(in: start ..< clampedEnd)
    }
}
