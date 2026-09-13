import Foundation

/// 内存压力监控（Implementation Plan §29：ResourceMonitor）。
///
/// 上层（资源管理策略）只依赖本协议；测试注入假实现，生产用系统实现。
public protocol MemoryPressureMonitoring: Sendable {
    /// 当前系统可供本进程使用的内存字节数；系统不告知时返回 nil（调用方按「不紧张」保守处理）。
    func availableMemoryBytes() -> UInt64?
}

/// 基于 Mach `host_statistics64` 的系统实现（macOS 通用，无废弃风险）。
///
/// ⚠️ 不能用 `os_proc_available_memory()`——它在 macOS SDK 里标注
/// `API_UNAVAILABLE(macos)`（仅 iOS/tvOS/watchOS），编译器会拒绝。
/// macOS 上「可用内存」的通行算法是**可立即回收的物理页**：
/// free + inactive + purgeable + speculative（与活动监视器的「可用」口径一致的近似值）。
public struct OSMemoryPressureMonitor: MemoryPressureMonitoring {

    public init() {}

    public func availableMemoryBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            UInt32(MemoryLayout<vm_statistics64_data_t>.size) / UInt32(MemoryLayout<natural_t>.size)
        )
        let host = mach_host_self()
        defer { _ = mach_port_deallocate(mach_task_self_, host) }
        let kern = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kern == KERN_SUCCESS else { return nil }
        // vm_kernel_page_size 是全局可变变量，Swift 6 并发检查不让直接引用；sysconf 等价且线程安全。
        let pageSizeRaw = sysconf(Int32(_SC_PAGESIZE))
        guard pageSizeRaw > 0 else { return nil }
        let pageSize = UInt64(pageSizeRaw)
        let reclaimablePages = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        return reclaimablePages * pageSize
    }
}
