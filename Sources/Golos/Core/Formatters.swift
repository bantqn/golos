import Foundation

enum Fmt {

    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: value)
    }

    /// «1:23:45» либо «4:07» — без ведущего нуля у часов.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Метка времени для субтитров: «00:01:23,456».
    static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let ms = Int((clamped - Double(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    static func vttTimestamp(_ seconds: TimeInterval) -> String {
        srtTimestamp(seconds).replacingOccurrences(of: ",", with: ".")
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f.string(from: date)
    }

    static func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня, " + shortTime(date) }
        if cal.isDateInYesterday(date) { return "Вчера, " + shortTime(date) }
        return Fmt.date(date)
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", max(0, min(100, value)))
    }

    /// Множественное число по-русски: 1 модель, 2 модели, 5 моделей.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n = abs(count) % 100
        let n1 = n % 10
        if n > 10 && n < 20 { return "\(count) \(many)" }
        if n1 > 1 && n1 < 5 { return "\(count) \(few)" }
        if n1 == 1 { return "\(count) \(one)" }
        return "\(count) \(many)"
    }
}
