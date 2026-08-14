import Foundation
import Combine
import IOKit
import Darwin

/// Снимок нагрузки на машину.
struct LoadSnapshot: Equatable {
    var timestamp: Date = Date()
    var cpuTotal: Double = 0          // 0…100 по всей машине
    var perCore: [Double] = []
    var gpu: Double = 0               // 0…100, −1 если недоступно
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var memoryPressure: Double = 0    // 0…100
    var appCPU: Double = 0            // 0…100, вклад самого приложения
    var appMemory: Int64 = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode: Bool = false

    var memoryFraction: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
    }

    var thermalTitle: String {
        switch thermal {
        case .nominal: return "Норма"
        case .fair: return "Слегка тёплый"
        case .serious: return "Горячий"
        case .critical: return "Перегрев"
        @unknown default: return "—"
        }
    }
}

/// Опрос системных счётчиков раз в секунду.
/// Значения нужны и для красивого экрана нагрузки, и для честного предупреждения,
/// что тяжёлая модель на этой машине будет считать долго.
@MainActor
final class SystemMonitor: ObservableObject {

    @Published private(set) var snapshot = LoadSnapshot()
    /// История для графиков — 90 последних секунд.
    @Published private(set) var history: [LoadSnapshot] = []

    private var timer: Timer?
    private var previousCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var previousAppTime: (user: Double, system: Double, at: Date)?
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        var next = LoadSnapshot()
        let cpu = readCPU()
        next.cpuTotal = cpu.total
        next.perCore = cpu.perCore
        next.gpu = Self.readGPU()

        let memory = readMemory()
        next.memoryUsed = memory.used
        next.memoryTotal = memory.total
        next.memoryPressure = memory.pressure

        let app = readApp()
        next.appCPU = app.cpu
        next.appMemory = app.memory

        next.thermal = ProcessInfo.processInfo.thermalState
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        snapshot = next
        history.append(next)
        if history.count > 90 { history.removeFirst(history.count - 90) }
    }

    // MARK: - CPU

    private func readCPU() -> (total: Double, perCore: [Double]) {
        var count = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        current.reserveCapacity(Int(count))
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            current.append((
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }

        defer { previousCPUTicks = current }
        guard previousCPUTicks.count == current.count else { return (0, Array(repeating: 0, count: current.count)) }

        var perCore: [Double] = []
        var busySum = 0.0
        for (index, now) in current.enumerated() {
            let before = previousCPUTicks[index]
            let user = Double(now.user &- before.user)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let nice = Double(now.nice &- before.nice)
            let total = user + system + idle + nice
            let busy = total > 0 ? (user + system + nice) / total * 100 : 0
            perCore.append(busy)
            busySum += busy
        }
        return (perCore.isEmpty ? 0 : busySum / Double(perCore.count), perCore)
    }

    // MARK: - Память

    private func readMemory() -> (used: Int64, total: Int64, pressure: Double) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0) }

        let pageSize = Int64(vm_kernel_page_size)
        // «Занято» в терминах Мониторинга системы: активные + связанные + сжатые.
        let used = (Int64(stats.active_count) + Int64(stats.wire_count)
                    + Int64(stats.compressor_page_count)) * pageSize
        let pressure = total > 0 ? Double(used) / Double(total) * 100 : 0
        return (used, total, pressure)
    }

    // MARK: - Само приложение

    private func readApp() -> (cpu: Double, memory: Int64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memory = memoryResult == KERN_SUCCESS ? Int64(info.resident_size) : 0

        var times = task_thread_times_info()
        var timesCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let timesResult = withUnsafeMutablePointer(to: &times) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(timesCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &timesCount)
            }
        }
        guard timesResult == KERN_SUCCESS else { return (0, memory) }

        let user = Double(times.user_time.seconds) + Double(times.user_time.microseconds) / 1_000_000
        let system = Double(times.system_time.seconds) + Double(times.system_time.microseconds) / 1_000_000
        let now = Date()

        defer { previousAppTime = (user, system, now) }
        guard let previous = previousAppTime else { return (0, memory) }

        let wall = now.timeIntervalSince(previous.at)
        guard wall > 0.05 else { return (snapshot.appCPU, memory) }
        let cpuDelta = (user - previous.user) + (system - previous.system)
        // Нормируем на число ядер: 100% = вся машина занята нами.
        let percent = cpuDelta / wall / Double(coreCount) * 100
        return (max(0, min(100, percent)), memory)
    }

    // MARK: - GPU

    /// Загрузка GPU читается из IORegistry. На Apple Silicon это `AGXAccelerator`.
    /// Если ключа нет — возвращаем −1, и интерфейс просто не показывает плитку.
    private static func readGPU() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return -1 }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any]
            else { continue }

            for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                if let value = statistics[key] as? Int { return Double(value) }
                if let value = statistics[key] as? Double { return value }
            }
        }
        return -1
    }
}
