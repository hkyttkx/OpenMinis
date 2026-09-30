import Foundation

public struct ResponsePacketBuilder {
    /// 构造 IPv4 + TCP 响应包
    public static func buildTCPPacket(
        srcIP: String,
        dstIP: String,
        srcPort: UInt16,
        dstPort: UInt16,
        seqNum: UInt32,
        ackNum: UInt32,
        flags: UInt8,
        payload: Data,
        windowSize: UInt16 = 65_535
    ) -> Data {
        let srcIPBytes = ipStringToBytes(srcIP)
        let dstIPBytes = ipStringToBytes(dstIP)

        var tcpSegment = Data()
        appendUInt16(srcPort, to: &tcpSegment)
        appendUInt16(dstPort, to: &tcpSegment)
        appendUInt32(seqNum, to: &tcpSegment)
        appendUInt32(ackNum, to: &tcpSegment)
        tcpSegment.append(0x50) // Data offset = 5 (20-byte header), no options
        tcpSegment.append(flags)
        appendUInt16(windowSize, to: &tcpSegment)
        appendUInt16(0, to: &tcpSegment) // checksum placeholder
        appendUInt16(0, to: &tcpSegment) // urgent pointer
        tcpSegment.append(payload)

        let tcpChecksumValue = tcpChecksum(srcIP: srcIPBytes, dstIP: dstIPBytes, tcpSegment: tcpSegment)
        storeUInt16(tcpChecksumValue, at: 16, in: &tcpSegment)

        let totalLength = 20 + tcpSegment.count
        var ipHeader = Data()
        ipHeader.append(0x45) // Version=4, IHL=5
        ipHeader.append(0x00) // DSCP/ECN
        appendUInt16(UInt16(clamping: totalLength), to: &ipHeader)
        appendUInt16(0, to: &ipHeader) // identification
        appendUInt16(0x4000, to: &ipHeader) // flags + fragment offset (DF)
        ipHeader.append(64) // TTL
        ipHeader.append(6) // TCP
        appendUInt16(0, to: &ipHeader) // checksum placeholder
        ipHeader.append(srcIPBytes)
        ipHeader.append(dstIPBytes)

        let ipChecksumValue = ipChecksum(ipHeader)
        storeUInt16(ipChecksumValue, at: 10, in: &ipHeader)

        var packet = Data()
        packet.append(ipHeader)
        packet.append(tcpSegment)
        return packet
    }

    /// 构造 IPv4 + UDP 响应包
    public static func buildUDPPacket(
        srcIP: String,
        dstIP: String,
        srcPort: UInt16,
        dstPort: UInt16,
        payload: Data
    ) -> Data {
        let srcIPBytes = ipStringToBytes(srcIP)
        let dstIPBytes = ipStringToBytes(dstIP)

        var udpSegment = Data()
        appendUInt16(srcPort, to: &udpSegment)
        appendUInt16(dstPort, to: &udpSegment)
        let udpLength = 8 + payload.count
        appendUInt16(UInt16(clamping: udpLength), to: &udpSegment)
        appendUInt16(0, to: &udpSegment) // checksum placeholder
        udpSegment.append(payload)

        let udpChecksumValue = udpChecksum(srcIP: srcIPBytes, dstIP: dstIPBytes, udpSegment: udpSegment)
        storeUInt16(udpChecksumValue, at: 6, in: &udpSegment)

        let totalLength = 20 + udpSegment.count
        var ipHeader = Data()
        ipHeader.append(0x45) // Version=4, IHL=5
        ipHeader.append(0x00)
        appendUInt16(UInt16(clamping: totalLength), to: &ipHeader)
        appendUInt16(0, to: &ipHeader)
        appendUInt16(0x4000, to: &ipHeader)
        ipHeader.append(64)
        ipHeader.append(17) // UDP
        appendUInt16(0, to: &ipHeader)
        ipHeader.append(srcIPBytes)
        ipHeader.append(dstIPBytes)

        let ipChecksumValue = ipChecksum(ipHeader)
        storeUInt16(ipChecksumValue, at: 10, in: &ipHeader)

        var packet = Data()
        packet.append(ipHeader)
        packet.append(udpSegment)
        return packet
    }

    static func ipChecksum(_ header: Data) -> UInt16 {
        checksum(header)
    }

    static func tcpChecksum(srcIP: Data, dstIP: Data, tcpSegment: Data) -> UInt16 {
        var pseudo = Data()
        pseudo.append(srcIP.prefix(4))
        pseudo.append(dstIP.prefix(4))
        pseudo.append(0)
        pseudo.append(6)
        appendUInt16(UInt16(clamping: tcpSegment.count), to: &pseudo)
        pseudo.append(tcpSegment)
        let sum = checksum(pseudo)
        return sum == 0 ? 0xFFFF : sum
    }

    static func udpChecksum(srcIP: Data, dstIP: Data, udpSegment: Data) -> UInt16 {
        var pseudo = Data()
        pseudo.append(srcIP.prefix(4))
        pseudo.append(dstIP.prefix(4))
        pseudo.append(0)
        pseudo.append(17)
        appendUInt16(UInt16(clamping: udpSegment.count), to: &pseudo)
        pseudo.append(udpSegment)

        let result = checksum(pseudo)
        // IPv4 UDP allows checksum=0 (disabled), keep zero if computed zero.
        return result
    }

    static func ipStringToBytes(_ ip: String) -> Data {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else {
            return Data([0, 0, 0, 0])
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard let value = UInt8(part) else {
                return Data([0, 0, 0, 0])
            }
            bytes.append(value)
        }
        return Data(bytes)
    }

    private static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < data.count {
            let word = (UInt16(data[index]) << 8) | UInt16(data[index + 1])
            sum += UInt32(word)
            index += 2
        }

        if index < data.count {
            let lastWord = UInt16(data[index]) << 8
            sum += UInt32(lastWord)
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return ~UInt16(sum & 0xFFFF)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func storeUInt16(_ value: UInt16, at offset: Int, in data: inout Data) {
        guard offset >= 0, offset + 1 < data.count else {
            return
        }
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }
}
