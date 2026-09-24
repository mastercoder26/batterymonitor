import Foundation
import Darwin

/// Samples process CPU activity. CPU share is a share of observed CPU time, not battery power.
struct ProcessReader {
    private let state = SampleState()

    func sample() -> [ProcessImpact] {
        state.sample()
    }

    private final class SampleState {
        private let lock = NSLock()
        private var previous: [pid_t: UInt64] = [:]
        private var previousTime: TimeInterval?

        func sample() -> [ProcessImpact] {
            lock.lock()
            defer { lock.unlock() }

            let now = ProcessInfo.processInfo.systemUptime
            let current = taskTimes()
            defer {
                previous = current
                previousTime = now
            }
            guard let previousTime, now > previousTime else { return [] }
            let elapsed = now - previousTime
            // Discard a stale interval after sleep or a long pause.
            guard elapsed >= 0.5, elapsed <= 300 else { return [] }

            var activity: [(pid: pid_t, cpu: Double)] = []
            for (pid, ticks) in current {
                guard let old = previous[pid], ticks >= old else { continue }
                let cpu = Double(ticks - old) / (elapsed * 1_000_000_000) * 100
                if cpu.isFinite, cpu >= 0.1 { activity.append((pid, cpu)) }
            }
            let total = activity.reduce(0) { $0 + $1.cpu }
            guard total > 0 else { return [] }

            return activity.sorted { $0.cpu > $1.cpu }.prefix(12).map { item in
                ProcessImpact(
                    pid: Int(item.pid),
                    name: processName(item.pid),
                    cpuPercent: item.cpu,
                    estimatedShare: item.cpu / total * 100
                )
            }
        }

        private func taskTimes() -> [pid_t: UInt64] {
            // The first call returns the required byte count. Processes can appear between calls.
            let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard byteCount > 0 else { return [:] }
            var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.stride + 128)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard count > 0 else { return [:] }

            var result: [pid_t: UInt64] = [:]
            for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.stride) where pid > 0 {
                var info = proc_taskinfo()
                let size = withUnsafeMutablePointer(to: &info) { pointer in
                    proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, Int32(MemoryLayout<proc_taskinfo>.size))
                }
                guard size == MemoryLayout<proc_taskinfo>.size else { continue }
                result[pid] = info.pti_total_user &+ info.pti_total_system
            }
            return result
        }

        private func processName(_ pid: pid_t) -> String {
            var buffer = [CChar](repeating: 0, count: 256)
            let count = buffer.withUnsafeMutableBytes { bytes in
                proc_name(pid, bytes.baseAddress, UInt32(bytes.count))
            }
            guard count > 0 else { return "Process \(pid)" }
            return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
