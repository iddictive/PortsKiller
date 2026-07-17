import Darwin
import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let ownerUID: UInt32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

enum ProcessIdentityReader {
    static func read(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize else { return nil }
        return ProcessIdentity(
            ownerUID: info.pbi_uid,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }
}
