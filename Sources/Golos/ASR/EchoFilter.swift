import Foundation

/// Куда отдавать предпочтение, когда одна и та же фраза попала в обе дорожки.
enum EchoPriority: String, Codable, CaseIterable, Identifiable {
    case system, microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Звук системы"
        case .microphone: return "Микрофон"
        }
    }

    var explanation: String {
        switch self {
        case .system:
            return "Системная дорожка чище передаёт голос собеседника — микрофонный дубль убирается."
        case .microphone:
            return "Оставлять микрофонную версию. Имеет смысл, если системный звук записывается с помехами."
        }
    }
}

/// Убирает дубли между дорожкой микрофона и дорожкой системы.
///
/// Проблема физическая: если собеседника слушают через динамики, его голос
/// попадает и в системную запись, и обратно в микрофон. Обе дорожки
/// распознаются, и одна фраза оказывается в расшифровке дважды — один раз
/// как «Собеседник», второй как «Я».
///
/// Определяем дубль по двум признакам сразу: реплики пересекаются во времени
/// и их текст достаточно похож. Одного времени мало — люди перебивают друг
/// друга, и это не эхо; одного текста мало — фразу могли повторить осознанно.
enum EchoFilter {

    /// Насколько реплики должны пересекаться, чтобы считаться одним моментом.
    private static let timeTolerance: TimeInterval = 1.5

    static func deduplicate(_ segments: [Segment],
                            priority: EchoPriority,
                            similarityThreshold: Double) -> (kept: [Segment], removed: Int) {

        let loserSpeaker: Segment.Speaker = priority == .system ? .me : .others
        let winnerSpeaker: Segment.Speaker = priority == .system ? .others : .me

        let winners = segments.filter { $0.speaker == winnerSpeaker }
        guard !winners.isEmpty else { return (segments, 0) }

        // Токены победителей считаем один раз: сравнений будет много.
        let winnerTokens = winners.map { (segment: $0, tokens: tokenize($0.text)) }

        var kept: [Segment] = []
        var removed = 0

        for segment in segments {
            guard segment.speaker == loserSpeaker else {
                kept.append(segment)
                continue
            }
            let tokens = tokenize(segment.text)
            guard !tokens.isEmpty else {
                kept.append(segment)
                continue
            }

            let isEcho = winnerTokens.contains { candidate in
                overlaps(segment, candidate.segment)
                    && similarity(tokens, candidate.tokens) >= similarityThreshold
            }
            if isEcho {
                removed += 1
            } else {
                kept.append(segment)
            }
        }
        return (kept, removed)
    }

    private static func overlaps(_ left: Segment, _ right: Segment) -> Bool {
        left.start < right.end + timeTolerance && right.start < left.end + timeTolerance
    }

    /// Слова в нижнем регистре без знаков: распознавание одной и той же фразы
    /// с двух дорожек различается пунктуацией и мелочами, а не словами.
    private static func tokenize(_ text: String) -> Set<String> {
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        return Set(cleaned)
    }

    /// Мера Жаккара: доля общих слов. Устойчива к разной длине реплик,
    /// которые движок нарезал по-своему на каждой дорожке.
    private static func similarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        guard intersection > 0 else { return 0 }
        let union = left.union(right).count
        return Double(intersection) / Double(union)
    }
}
