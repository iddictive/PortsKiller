import Darwin
import Foundation

final class SystemResourceMonitor {
    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
    }

    private var previousCPUTicks: CPUTicks?

    func sample() -> SystemResourceUsage {
        let currentTicks = readCPUTicks()
        defer { previousCPUTicks = currentTicks }

        return SystemResourceUsage(
            cpuPercent: cpuPercent(current: currentTicks, previous: previousCPUTicks),
            memoryUsedBytes: readMemoryUsedBytes(),
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            swap: readSwapUsage()
        )
    }

    private func readCPUTicks() -> CPUTicks? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return CPUTicks(
            user: UInt64(load.cpu_ticks.0),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2),
            nice: UInt64(load.cpu_ticks.3)
        )
    }

    private func cpuPercent(current: CPUTicks?, previous: CPUTicks?) -> Double? {
        guard let current, let previous else { return nil }
        let userDelta = tickDelta(current.user, previous.user)
        let systemDelta = tickDelta(current.system, previous.system)
        let idleDelta = tickDelta(current.idle, previous.idle)
        let niceDelta = tickDelta(current.nice, previous.nice)
        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard totalDelta > 0 else { return nil }
        let busyDelta = userDelta + systemDelta + niceDelta
        return min(Double(busyDelta) / Double(totalDelta) * 100, 100)
    }

    private func tickDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        return current + (UInt64(UInt32.max) - previous) + 1
    }

    private func readMemoryUsedBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }

        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        return min(usedPages * UInt64(pageSize), ProcessInfo.processInfo.physicalMemory)
    }

    private func readSwapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else {
            return nil
        }

        return SwapUsage(
            usedBytes: UInt64(usage.xsu_used),
            totalBytes: UInt64(usage.xsu_total)
        )
    }
}
