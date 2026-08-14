import Foundation
import Darwin

/// Учёт оперативной памяти: сколько её осталось, сколько можно занять
/// и что делать, когда система начинает задыхаться.
///
/// Распознавание речи — самая память-ёмкая часть приложения: модель, KV-кэши
/// декодеров и буферы Metal легко дают несколько гигабайт. Поэтому решение
/// «грузить или не грузить» принимается здесь, а не по факту.
enum MemoryGuard {

    static var totalBytes: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Память, которую система готова отдать без свопа: свободные страницы
    /// плюс те, что можно немедленно переиспользовать.
    static var availableBytes: Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return totalBytes / 4 }

        let pageSize = Int64(vm_kernel_page_size)
        let reclaimable = Int64(stats.free_count)
            + Int64(stats.inactive_count)
            + Int64(stats.speculative_count)
        // purgeable-страницы система освободит сама под давлением.
        return (reclaimable + Int64(stats.purgeable_count)) * pageSize
    }

    /// Сколько занимает сам процесс.
    static var footprintBytes: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    // MARK: - Бюджет

    /// Запас, который приложение обязано оставить системе.
    /// Пользователь задаёт его в настройках; ниже гигабайта не опускаемся.
    static func headroom(_ settings: Settings) -> Int64 {
        let requested = Int64(settings.memoryHeadroomGB * 1024 * 1024 * 1024)
        return max(1024 * 1024 * 1024, requested)
    }

    /// Сколько байт приложение может занять прямо сейчас, не съедая запас.
    static func budget(_ settings: Settings) -> Int64 {
        max(0, availableBytes - headroom(settings))
    }

    /// Помещается ли модель вместе со служебными буферами.
    static func fits(_ bytes: Int64, settings: Settings) -> Bool {
        bytes <= budget(settings)
    }

    /// Причина отказа человеческим языком — или `nil`, если всё в порядке.
    static func rejection(for spec: ModelSpec, settings: Settings) -> String? {
        let need = spec.estimatedRAM
        guard !fits(need, settings: settings) else { return nil }
        return "Модели «\(spec.title)» нужно ≈\(Fmt.bytes(need)), а свободно \(Fmt.bytes(availableBytes)) "
            + "при запасе \(Fmt.bytes(headroom(settings))). Закройте что-нибудь или возьмите модель поменьше."
    }

    /// Ширина луча напрямую умножает число декодеров, а значит и KV-кэши.
    /// Если памяти в обрез — сужаем, вместо того чтобы уронить машину в своп.
    static func clampBeamSize(_ requested: Int, model spec: ModelSpec, settings: Settings) -> Int {
        guard requested > 1 else { return 1 }
        let perDecoder = decoderCost(spec)
        let available = budget(settings) - spec.estimatedRAM
        guard available > 0 else { return 1 }
        let affordable = Int(available / max(1, perDecoder))
        return max(1, min(requested, affordable))
    }

    /// Грубая оценка KV-кэша и буферов одного декодера.
    private static func decoderCost(_ spec: ModelSpec) -> Int64 {
        switch spec.family {
        // Parakeet — транcдьюсер: лучевого поиска у него нет, лишних кэшей тоже.
        case .parakeet: return 32 * 1024 * 1024
        case .large: return spec.id.contains("turbo") ? 40 * 1024 * 1024 : 260 * 1024 * 1024
        case .medium: return 180 * 1024 * 1024
        case .small: return 70 * 1024 * 1024
        case .base, .tiny, .tool: return 24 * 1024 * 1024
        }
    }

    /// Длина окна для нарезки длинного аудио. Окно целиком лежит в памяти
    /// дважды (накопитель и выданная копия), поэтому подбираем под бюджет.
    static func windowSeconds(_ settings: Settings) -> Int {
        let bytesPerSecond = Int64(AudioFormat.sampleRate) * 4
        let allowance = budget(settings) / 8          // на аудио — не больше восьмой части бюджета
        let seconds = Int(allowance / (bytesPerSecond * 2))
        // Меньше двух минут дробить бессмысленно, больше десяти — уже не экономно.
        return max(120, min(600, seconds))
    }

    /// Возвращает системе страницы, которые аллокатор освободил, но придержал.
    /// После часовой расшифровки это снимает больше сотни мегабайт: malloc по
    /// умолчанию оставляет их себе на будущее, и в Мониторинге системы
    /// приложение выглядит толще, чем есть.
    static func releaseFreedPages() {
        malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: - Давление памяти

    private static var pressureSource: DispatchSourceMemoryPressure?

    /// Подписка на системное давление памяти. Обработчик вызывается на главном потоке.
    static func startMonitoring(onPressure: @escaping (Bool) -> Void) {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            let critical = source.data.contains(.critical)
            Log.warn("Система сообщает о нехватке памяти (\(critical ? "критично" : "предупреждение"))")
            onPressure(critical)
        }
        source.resume()
        pressureSource = source
    }
}
