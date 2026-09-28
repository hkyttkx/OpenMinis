//
//  MachOPatcher.swift
//  KyTuT
//
//  原生 Swift 的 Mach-O 64 补丁器：往主二进制头部追加
//  LC_LOAD_DYLIB（加载 FridaGadget.dylib）。
//
//  原理与 insert_dylib 相同：现代 arm64 Mach-O 的 load commands 之后、
//  第一个 section 之前有页对齐留白（通常 0x4000），新命令写入留白区，
//  再更新头部 ncmds / sizeofcmds，其余字节零移动。
//  重签由 TrollStore 安装时完成，这里不做代码签名处理。
//

import Foundation

enum MachOPatchError: Error, LocalizedError {
    case notMachO64
    case fatBinary
    case alreadyInjected
    case noPadding(needed: Int, available: Int)
    case encrypted
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .notMachO64: return "不是 arm64 Mach-O 二进制"
        case .fatBinary: return "Fat 二进制暂不支持（请用 thin arm64 包）"
        case .alreadyInjected: return "该二进制已注入过 Gadget"
        case .noPadding(let n, let a): return "头部留白不足（需 \(n) 字节，仅 \(a)）"
        case .encrypted: return "二进制带 FairPlay 加密（cryptid≠0），请先砸壳再注入"
        case .ioFailure(let m): return "文件读写失败：\(m)"
        }
    }
}

enum MachOPatcher {

    /// 头部结构尺寸（Mach-O 64）
    private static let headerSize = 32
    /// LC_LOAD_DYLIB 固定前缀（cmd/cmdsize/name.offset/timestamp/current/compat）
    private static let dylibPrefixSize = 24

    /// 检查并注入 `@executable_path/<dylibName>` 加载命令。
    /// 幂等：已存在同名 LC_LOAD_DYLIB 时抛 alreadyInjected。
    @discardableResult
    static func insertLoadDylib(at binaryURL: URL, dylibName: String) throws -> URL {
        var data = try Data(contentsOf: binaryURL)
        guard data.count > headerSize else { throw MachOPatchError.notMachO64 }

        let magic = data.readLE32(0)
        if magic == 0xCAFEBABE || magic == 0xBEBAFECA { throw MachOPatchError.fatBinary }
        guard magic == 0xFEEDFACF else { throw MachOPatchError.notMachO64 }

        var ncmds = Int(data.readLE32(16))
        var sizeofcmds = Int(data.readLE32(20))

        // 遍历 load commands：找加密标记 / 重复注入 / 可用留白上界
        var cryptid: UInt32 = 0
        var off = headerSize
        var lastCmdEnd = headerSize
        var minSectionOffset = Int.max
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { throw MachOPatchError.notMachO64 }
            let cmd = data.readLE32(off)
            let cmdsize = Int(data.readLE32(off + 4))
            guard cmdsize >= 8, off + cmdsize <= data.count else { throw MachOPatchError.notMachO64 }

            switch cmd {
            case 0x2C: // LC_ENCRYPTION_INFO_64：cryptid 在 +16
                if off + 20 <= data.count { cryptid = data.readLE32(off + 16) }
            case 0x21: // LC_ENCRYPTION_INFO (32位)：cryptid 同样在 +16
                if off + 20 <= data.count { cryptid = data.readLE32(off + 16) }
            case 0xC:  // LC_LOAD_DYLIB
                if let name = readDylibName(data, cmdOffset: off) {
                    let installName = "@executable_path/\(dylibName)"
                    if name == installName { throw MachOPatchError.alreadyInjected }
                }
            case 0x19: // LC_SEGMENT_64：收集全部 section file offset 最小值
                guard off + cmdsize <= data.count, cmdsize >= 72 else { break }
                let nsects = Int(data.readLE32(off + 64))
                var p = off + 72 // section_64 数组起点，每个 80 字节
                for _ in 0..<nsects {
                    guard p + 80 <= off + cmdsize else { break }
                    let sectOffset = Int(data.readLE32(p + 48)) // section_64.offset
                    if sectOffset > 0 { minSectionOffset = min(minSectionOffset, sectOffset) }
                    p += 80
                }
            default:
                break
            }
            off += cmdsize
            lastCmdEnd = off
        }

        if cryptid != 0 { throw MachOPatchError.encrypted }

        // 留白上界：load commands 结束位置必须 <= 第一个 section 起点。
        // 没有 section（极罕见）时退回保守的 0x4000。
        let bound = minSectionOffset == Int.max ? 0x4000 : minSectionOffset

        let installName = "@executable_path/\(dylibName)"
        let nameLen = installName.utf8.count
        let cmdsize = (dylibPrefixSize + nameLen + 1 + 7) & ~7  // 8 字节对齐

        let needed = sizeofcmds + cmdsize
        let available = bound - headerSize
        guard needed <= available else {
            throw MachOPatchError.noPadding(needed: needed, available: available)
        }
        guard lastCmdEnd == headerSize + sizeofcmds else {
            // 头部与实际命令总长不一致，拒绝盲写
            throw MachOPatchError.ioFailure("sizeofcmds(\(sizeofcmds)) 与实际命令区不匹配")
        }

        // 写入新 LC_LOAD_DYLIB
        var cmd = Data(capacity: cmdsize)
        cmd.appendLE32(0xC)                 // cmd
        cmd.appendLE32(UInt32(cmdsize))     // cmdsize
        cmd.appendLE32(UInt32(dylibPrefixSize)) // name.offset（相对本命令起点）
        cmd.appendLE32(2)                   // timestamp
        cmd.appendLE32(0)                   // current_version
        cmd.appendLE32(0)                   // compatibility_version
        cmd.append(installName.data(using: .utf8)!)
        cmd.append(0)
        while cmd.count < cmdsize { cmd.append(0) }

        let insertAt = headerSize + sizeofcmds
        data.replaceSubrange(Range(uncheckedBounds: (insertAt, insertAt)), with: cmd)
        // 更新头部 ncmds / sizeofcmds
        data.writeLE32(UInt32(ncmds + 1), at: 16)
        data.writeLE32(UInt32(sizeofcmds + cmdsize), at: 20)

        do {
            try data.write(to: binaryURL, options: .atomic)
            return binaryURL
        } catch {
            throw MachOPatchError.ioFailure(error.localizedDescription)
        }
    }

    /// 读取 LC_LOAD_DYLIB 的 dylib 名。
    private static func readDylibName(_ data: Data, cmdOffset: Int) -> String? {
        guard cmdOffset + 24 <= data.count else { return nil }
        let nameOffset = Int(data.readLE32(cmdOffset + 8))
        let cmdsize = Int(data.readLE32(cmdOffset + 4))
        let strStart = cmdOffset + nameOffset
        guard strStart < cmdOffset + cmdsize, strStart < data.count else { return nil }
        var end = strStart
        let limit = min(cmdOffset + cmdsize, data.count)
        while end < limit, data[data.startIndex + end] != 0 { end += 1 }
        return String(data: data[data.startIndex + strStart..<data.startIndex + end], encoding: .utf8)
    }
}

private extension Data {
    func readLE32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }

    mutating func writeLE32(_ value: UInt32, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)
        self[i + 1] = UInt8((value >> 8) & 0xFF)
        self[i + 2] = UInt8((value >> 16) & 0xFF)
        self[i + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
