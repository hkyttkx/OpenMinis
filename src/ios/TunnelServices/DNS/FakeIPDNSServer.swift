// PH3模式不需要此文件，已禁用编译
#if false
import Foundation

public final class FakeIPDNSServer {
    private struct DNSQuestion {
        let hostname: String
        let qType: UInt16
        let qClass: UInt16
        let rawQuestion: Data
    }

    private let fakeIPPool: FakeIPPool

    public init(fakeIPPool: FakeIPPool) {
        self.fakeIPPool = fakeIPPool
    }

    public func handleDNSQuery(packet: ParsedPacket) -> Data? {
        guard packet.protocolNumber == 17, packet.destPort == 53 else {
            return nil
        }

        guard packet.ipVersion == 4 else {
            return nil
        }

        let query = packet.payload
        guard query.count >= 12,
              let transactionID = readUInt16(query, at: 0),
              let qdCount = readUInt16(query, at: 4),
              qdCount > 0
        else {
            return nil
        }

        guard let question = parseQuestion(from: query, startOffset: 12) else {
            return nil
        }

        // Only handle A record queries (type 1, class IN)
        guard question.qClass == 1 else {
            return nil
        }

        // For non-A queries (AAAA=28, etc), return empty response to stop retries
        guard question.qType == 1 else {
            let emptyResponse = buildEmptyResponse(
                transactionID: transactionID,
                questionRawData: question.rawQuestion
            )
            return ResponsePacketBuilder.buildUDPPacket(
                srcIP: packet.destIP,
                dstIP: packet.sourceIP,
                srcPort: packet.destPort,
                dstPort: packet.sourcePort,
                payload: emptyResponse
            )
        }

        let fakeIP = fakeIPPool.allocate(hostname: question.hostname)
        guard !fakeIP.isEmpty else {
            return nil
        }

        let dnsResponse = buildResponse(
            transactionID: transactionID,
            questionRawData: question.rawQuestion,
            fakeIP: fakeIP
        )

        NSLog("[PH-DNS] %@ -> %@", question.hostname, fakeIP)

        return ResponsePacketBuilder.buildUDPPacket(
            srcIP: packet.destIP,
            dstIP: packet.sourceIP,
            srcPort: packet.destPort,
            dstPort: packet.sourcePort,
            payload: dnsResponse
        )
    }

    private func parseQuestion(from payload: Data, startOffset: Int) -> DNSQuestion? {
        var offset = startOffset
        var labels: [String] = []

        while offset < payload.count {
            let length = Int(payload[offset])
            offset += 1

            if length == 0 {
                break
            }

            if (length & 0xC0) == 0xC0 {
                return nil
            }

            guard offset + length <= payload.count,
                  let label = String(data: payload[offset ..< offset + length], encoding: .utf8),
                  !label.isEmpty
            else {
                return nil
            }

            labels.append(label)
            offset += length
        }

        guard offset + 4 <= payload.count,
              let qType = readUInt16(payload, at: offset),
              let qClass = readUInt16(payload, at: offset + 2)
        else {
            return nil
        }

        let hostname = labels.joined(separator: ".").lowercased()
        let endOffset = offset + 4
        let rawQuestion = payload.subdata(in: startOffset ..< endOffset)

        return DNSQuestion(
            hostname: hostname,
            qType: qType,
            qClass: qClass,
            rawQuestion: rawQuestion
        )
    }

    private func buildEmptyResponse(transactionID: UInt16, questionRawData: Data) -> Data {
        var response = Data(capacity: 12 + questionRawData.count)

        appendUInt16(transactionID, to: &response)
        appendUInt16(0x8180, to: &response) // standard response, no error
        appendUInt16(1, to: &response) // QDCOUNT
        appendUInt16(0, to: &response) // ANCOUNT = 0 (no answers)
        appendUInt16(0, to: &response) // NSCOUNT
        appendUInt16(0, to: &response) // ARCOUNT

        response.append(questionRawData)

        return response
    }

    private func buildResponse(transactionID: UInt16, questionRawData: Data, fakeIP: String) -> Data {
        var response = Data(capacity: 12 + questionRawData.count + 16)

        appendUInt16(transactionID, to: &response)
        appendUInt16(0x8180, to: &response)
        appendUInt16(1, to: &response) // QDCOUNT
        appendUInt16(1, to: &response) // ANCOUNT
        appendUInt16(0, to: &response) // NSCOUNT
        appendUInt16(0, to: &response) // ARCOUNT

        response.append(questionRawData)

        appendUInt16(0xC00C, to: &response) // name pointer
        appendUInt16(1, to: &response)      // type A
        appendUInt16(1, to: &response)      // class IN
        appendUInt32(600, to: &response)    // TTL
        appendUInt16(4, to: &response)      // RDLENGTH
        response.append(ipv4Bytes(from: fakeIP))

        return response
    }

    private func ipv4Bytes(from ip: String) -> Data {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else {
            return Data([0, 0, 0, 0])
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            bytes.append(UInt8(part) ?? 0)
        }
        return Data(bytes)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else {
            return nil
        }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}
#endif
