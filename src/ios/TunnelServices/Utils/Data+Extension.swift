//
//  Data+Extension.swift
//  TunnelServices
//
//  Created by LiuJie on 2019/5/10.
//  Copyright © 2019 Lojii. All rights reserved.
//

import Foundation
import Compression

extension Data {
    func append(fileURL: URL) throws {
        if let fileHandle = FileHandle(forWritingAtPath: fileURL.path) {
            defer {
                fileHandle.closeFile()
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(self)
        }
        else {
            try write(to: fileURL, options: .atomic)
        }
    }

    var isGzipped: Bool {
        guard count >= 2 else { return false }
        return self[startIndex] == 0x1f && self[index(after: startIndex)] == 0x8b
    }

    func gunzipped() throws -> Data {
        guard count > 18, isGzipped else { return self }

        // Skip gzip header (minimum 10 bytes)
        var headerSize = 10
        let flags = self[3]
        if flags & 0x04 != 0 { // FEXTRA
            guard count > headerSize + 2 else { return self }
            let extraLen = Int(self[headerSize]) | (Int(self[headerSize + 1]) << 8)
            headerSize += 2 + extraLen
        }
        if flags & 0x08 != 0 { // FNAME
            while headerSize < count && self[headerSize] != 0 { headerSize += 1 }
            headerSize += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while headerSize < count && self[headerSize] != 0 { headerSize += 1 }
            headerSize += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            headerSize += 2
        }

        guard headerSize < count - 8 else { return self }

        let deflateData = Data(self[headerSize ..< (count - 8)])
        if let result = deflateData.rawDeflateDecompress() {
            return result
        }
        return self
    }

    func unzip() -> Data? {
        return rawDeflateDecompress()
    }

    private func rawDeflateDecompress() -> Data? {
        guard !isEmpty else { return nil }

        let bufferSize = Swift.max(count * 4, 4096)
        var result = Data()

        return withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcPtr.baseAddress else { return nil }

            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dstBuffer.deallocate() }

            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }

            var status = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard status == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(stream) }

            stream.pointee.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = count
            stream.pointee.dst_ptr = dstBuffer
            stream.pointee.dst_size = bufferSize

            repeat {
                status = compression_stream_process(stream, 0)
                let outputSize = bufferSize - stream.pointee.dst_size
                if outputSize > 0 {
                    result.append(dstBuffer, count: outputSize)
                    stream.pointee.dst_ptr = dstBuffer
                    stream.pointee.dst_size = bufferSize
                }
            } while status == COMPRESSION_STATUS_OK

            guard status == COMPRESSION_STATUS_END else { return nil }

            let finalOutput = bufferSize - stream.pointee.dst_size
            if finalOutput > 0 {
                result.append(dstBuffer, count: finalOutput)
            }

            return result
        }
    }
}
