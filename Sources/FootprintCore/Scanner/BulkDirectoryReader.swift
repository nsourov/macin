import Darwin
import Foundation

struct RawEntry {
    enum Kind { case file, directory, symlink, other }

    let name: String
    let kind: Kind
    let device: Int32
    let fileID: UInt64
    let modified: Date?
    let linkCount: UInt32
    let logicalSize: Int64
    let allocatedSize: Int64
}

enum DirectoryReadError: Error {
    case permissionDenied
    case disappeared
    case other(Int32)

    init(errno code: Int32) {
        switch code {
        case EACCES, EPERM: self = .permissionDenied
        case ENOENT, ENOTDIR: self = .disappeared
        default: self = .other(code)
        }
    }
}

final class BulkDirectoryReader {
    private static let cmnReturnedAttrs: attrgroup_t = 0x8000_0000
    private static let cmnName: attrgroup_t = 0x0000_0001
    private static let cmnDevID: attrgroup_t = 0x0000_0002
    private static let cmnObjType: attrgroup_t = 0x0000_0008
    private static let cmnModTime: attrgroup_t = 0x0000_0400
    private static let cmnFileID: attrgroup_t = 0x0200_0000
    private static let cmnError: attrgroup_t = 0x2000_0000
    private static let fileLinkCount: attrgroup_t = 0x0000_0001
    private static let fileTotalSize: attrgroup_t = 0x0000_0002
    private static let fileAllocSize: attrgroup_t = 0x0000_0004

    private static let vReg: UInt32 = 1
    private static let vDir: UInt32 = 2
    private static let vLnk: UInt32 = 5

    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    func read(_ path: String) throws -> [RawEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryReadError(errno: errno) }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnError | Self.cmnDevID | Self.cmnObjType | Self.cmnModTime | Self.cmnFileID
        list.fileattr = Self.fileLinkCount | Self.fileTotalSize | Self.fileAllocSize

        var entries: [RawEntry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if entries.isEmpty { throw DirectoryReadError(errno: errno) }
                break
            }
            var cursor = buffer
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                if let entry = parse(cursor) { entries.append(entry) }
                cursor += length
            }
        }
        return entries
    }

    private func parse(_ start: UnsafeMutableRawPointer) -> RawEntry? {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & Self.cmnError != 0 {
            let err = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            if err != 0 { return nil }
        }

        guard returned.commonattr & Self.cmnName != 0 else { return nil }
        let nameRef = field.loadUnaligned(as: attrreference_t.self)
        let namePtr = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePtr)
        field += MemoryLayout<attrreference_t>.size

        var device: Int32 = 0
        if returned.commonattr & Self.cmnDevID != 0 {
            device = field.loadUnaligned(as: Int32.self)
            field += MemoryLayout<Int32>.size
        }

        var objType: UInt32 = 0
        if returned.commonattr & Self.cmnObjType != 0 {
            objType = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var modified: Date?
        if returned.commonattr & Self.cmnModTime != 0 {
            let ts = field.loadUnaligned(as: timespec.self)
            modified = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
            field += MemoryLayout<timespec>.size
        }

        var fileID: UInt64 = 0
        if returned.commonattr & Self.cmnFileID != 0 {
            fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        var linkCount: UInt32 = 1
        var logical: Int64 = 0
        var allocated: Int64 = 0
        if returned.fileattr & Self.fileLinkCount != 0 {
            linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if returned.fileattr & Self.fileTotalSize != 0 {
            logical = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }
        if returned.fileattr & Self.fileAllocSize != 0 {
            allocated = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }

        let kind: RawEntry.Kind
        switch objType {
        case Self.vReg: kind = .file
        case Self.vDir: kind = .directory
        case Self.vLnk: kind = .symlink
        default: kind = .other
        }
        return RawEntry(name: name, kind: kind, device: device, fileID: fileID, modified: modified,
                        linkCount: linkCount, logicalSize: logical, allocatedSize: allocated)
    }
}
