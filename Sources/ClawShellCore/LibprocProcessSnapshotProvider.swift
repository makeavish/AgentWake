import Darwin
import Foundation

public protocol ProcessSnapshotProviding {
    func snapshots() throws -> [ProcessSnapshot]
}

public enum ProcessSnapshotProviderError: Error, Equatable {
    case unableToListProcesses
}

public struct LibprocProcessSnapshotProvider: ProcessSnapshotProviding {
    public init() {}

    public func snapshots() throws -> [ProcessSnapshot] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            throw ProcessSnapshotProviderError.unableToListProcesses
        }

        let pidCapacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: pidCapacity)
        let filledByteCount = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }

        guard filledByteCount > 0 else {
            throw ProcessSnapshotProviderError.unableToListProcesses
        }

        let filledCount = min(Int(filledByteCount) / MemoryLayout<pid_t>.stride, pids.count)
        return pids.prefix(filledCount).compactMap { pid in
            guard pid > 0 else {
                return nil
            }

            return snapshot(for: pid)
        }
    }

    private func snapshot(for pid: pid_t) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(infoSize))
        }

        guard result == Int32(infoSize) else {
            return nil
        }

        let processName = cString(from: info.pbi_comm)
        let path = executablePath(for: pid)
        let startTime = Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )

        return ProcessSnapshot(
            pid: Int32(pid),
            processName: processName,
            executablePath: path,
            processStartTime: startTime,
            cpuPercent: nil
        )
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }

        return string(from: buffer.prefix(Int(length)))
    }

    private func cString<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let characters = rawBuffer.bindMemory(to: CChar.self)
            let endIndex = characters.firstIndex(of: 0) ?? characters.endIndex
            return string(from: characters[..<endIndex])
        }
    }

    private func string<C: Collection>(from characters: C) -> String where C.Element == CChar {
        String(decoding: characters.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
