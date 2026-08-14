import Foundation

/// Период, по которому группируется статистика.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "По дням"
        case .week: return "По неделям"
        case .month: return "По месяцам"
        }
    }

    /// Сколько отрезков показываем на графике.
    var bucketCount: Int {
        switch self {
        case .day: return 14
        case .week: return 12
        case .month: return 12
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// Одна точка на графике.
struct StatsBucket: Identifiable, Equatable {
    let start: Date
    var label: String
    /// Диктовка.
    var dictationCount: Int = 0
    var dictationSeconds: TimeInterval = 0
    var dictationWords: Int = 0
    /// Записи и их расшифровки.
    var recordingCount: Int = 0
    var recordedSeconds: TimeInterval = 0
    var transcribedWords: Int = 0

    var id: Date { start }

    var totalWords: Int { dictationWords + transcribedWords }
    var totalSeconds: TimeInterval { dictationSeconds + recordedSeconds }
}

/// Подсчёт статистики по библиотеке и истории диктовок.
///
/// Считается на месте из уже загруженных метаданных: количество слов
/// расшифровок лежит в статусе записи, поэтому файлы расшифровок читать
/// не приходится и экран открывается мгновенно.
enum Stats {

    static func buckets(period: StatsPeriod,
                        recordings: [Recording],
                        dictations: [DictationEntry],
                        calendar: Calendar = .current,
                        now: Date = Date()) -> [StatsBucket] {

        let starts = bucketStarts(period: period, calendar: calendar, now: now)
        guard let earliest = starts.first else { return [] }

        var byStart: [Date: StatsBucket] = [:]
        for start in starts {
            byStart[start] = StatsBucket(start: start, label: label(for: start, period: period, calendar: calendar))
        }

        for entry in dictations where entry.createdAt >= earliest {
            guard let start = bucketStart(for: entry.createdAt, period: period, calendar: calendar),
                  byStart[start] != nil else { continue }
            byStart[start]?.dictationCount += 1
            byStart[start]?.dictationSeconds += entry.seconds
            byStart[start]?.dictationWords += wordCount(entry.text)
        }

        for recording in recordings where recording.createdAt >= earliest {
            guard let start = bucketStart(for: recording.createdAt, period: period, calendar: calendar),
                  byStart[start] != nil else { continue }
            byStart[start]?.recordingCount += 1
            byStart[start]?.recordedSeconds += recording.duration
            if case .done(_, let words) = recording.transcriptStatus {
                byStart[start]?.transcribedWords += words
            }
        }

        return starts.compactMap { byStart[$0] }
    }

    /// Итоги за всё время — для плиток над графиком.
    static func total(recordings: [Recording], dictations: [DictationEntry]) -> StatsBucket {
        var bucket = StatsBucket(start: .distantPast, label: "Всего")
        for entry in dictations {
            bucket.dictationCount += 1
            bucket.dictationSeconds += entry.seconds
            bucket.dictationWords += wordCount(entry.text)
        }
        for recording in recordings {
            bucket.recordingCount += 1
            bucket.recordedSeconds += recording.duration
            if case .done(_, let words) = recording.transcriptStatus {
                bucket.transcribedWords += words
            }
        }
        return bucket
    }

    /// Итоги за сегодня — для сводки на главном экране.
    static func today(recordings: [Recording], dictations: [DictationEntry],
                      calendar: Calendar = .current, now: Date = Date()) -> StatsBucket {
        var bucket = StatsBucket(start: calendar.startOfDay(for: now), label: "Сегодня")
        for entry in dictations where calendar.isDate(entry.createdAt, inSameDayAs: now) {
            bucket.dictationCount += 1
            bucket.dictationSeconds += entry.seconds
            bucket.dictationWords += wordCount(entry.text)
        }
        for recording in recordings where calendar.isDate(recording.createdAt, inSameDayAs: now) {
            bucket.recordingCount += 1
            bucket.recordedSeconds += recording.duration
            if case .done(_, let words) = recording.transcriptStatus {
                bucket.transcribedWords += words
            }
        }
        return bucket
    }

    // MARK: - Границы отрезков

    private static func bucketStarts(period: StatsPeriod, calendar: Calendar, now: Date) -> [Date] {
        guard let current = bucketStart(for: now, period: period, calendar: calendar) else { return [] }
        var result: [Date] = []
        for offset in stride(from: period.bucketCount - 1, through: 0, by: -1) {
            if let date = calendar.date(byAdding: period.component, value: -offset, to: current) {
                result.append(date)
            }
        }
        return result
    }

    private static func bucketStart(for date: Date, period: StatsPeriod, calendar: Calendar) -> Date? {
        switch period {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
        }
    }

    private static func label(for date: Date, period: StatsPeriod, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        switch period {
        case .day: formatter.dateFormat = "d MMM"
        case .week: formatter.dateFormat = "d MMM"
        case .month: formatter.dateFormat = "LLL"
        }
        return formatter.string(from: date)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
