//
//  FileHandle.swift
//  LegacyCompat
//
//  The throwing FileHandle API is iOS 13 / 13.4; the older calls raise an
//  Objective-C exception on failure, which Swift cannot catch. These go to
//  the file descriptor directly and throw instead.
//

import Darwin
import Foundation

extension FileHandle {
    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// `write(contentsOf:)`.
    public func compatWrite(contentsOf data: Data) throws {
        let descriptor = fileDescriptor
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                if written == 0 { throw POSIXError(.EIO) }
                cursor += written
                remaining -= written
            }
        }
    }

    /// `read(upToCount:)`: nil at end of file.
    public func compatRead(upToCount count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let descriptor = fileDescriptor
        let read: Int = try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var total = 0
            while total < count {
                let n = Darwin.read(descriptor, buffer.baseAddress! + total, count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                if n == 0 { break }
                total += n
            }
            return total
        }
        if read == 0 { return nil }
        data.count = read
        return data
    }

    /// `readToEnd()`: nil when nothing was left.
    public func compatReadToEnd() throws -> Data? {
        var result = Data()
        while let chunk = try compatRead(upToCount: 1 << 16) {
            result.append(chunk)
        }
        return result.isEmpty ? nil : result
    }

    /// `seekToEnd()`.
    @discardableResult
    public func compatSeekToEnd() throws -> UInt64 {
        let offset = lseek(fileDescriptor, 0, SEEK_END)
        if offset < 0 { throw posixError() }
        return UInt64(offset)
    }

    /// `seek(toOffset:)`.
    public func compatSeek(toOffset offset: UInt64) throws {
        if lseek(fileDescriptor, off_t(offset), SEEK_SET) < 0 { throw posixError() }
    }

    /// `offset()`.
    public func compatOffset() throws -> UInt64 {
        let offset = lseek(fileDescriptor, 0, SEEK_CUR)
        if offset < 0 { throw posixError() }
        return UInt64(offset)
    }

    /// `synchronize()`.
    public func compatSynchronize() throws {
        if fsync(fileDescriptor) != 0 { throw posixError() }
    }

    /// `truncate(atOffset:)`.
    public func compatTruncate(atOffset offset: UInt64) throws {
        if ftruncate(fileDescriptor, off_t(offset)) != 0 { throw posixError() }
    }

    /// `close()`.
    public func compatClose() throws {
        closeFile()
    }
}
