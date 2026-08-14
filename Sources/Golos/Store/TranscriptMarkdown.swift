import Foundation

/// Сборка расшифровки в Markdown: легенда, этапы, реплики.
///
/// Легенда сверху существует ради машинного чтения: файл потом уходит в LLM,
/// и без объяснения, что «Я» — это микрофон, а «Собеседник» — звук системы,
/// модель не поймёт, кто есть кто и откуда взялась запись.
enum TranscriptMarkdown {

    /// Разрыв, после которого начинается новый этап.
    private static let stageGap: TimeInterval = 180

    static func render(_ transcript: Transcript, recording: Recording,
                       includeLegend: Bool = true, includeStages: Bool = true) -> String {
        var lines: [String] = []

        lines.append("# \(recording.title)")
        lines.append("")

        if includeLegend {
            lines.append(contentsOf: legend(transcript, recording: recording))
            lines.append("")
        }

        lines.append("## Расшифровка")
        lines.append("")

        let stages = includeStages ? self.stages(transcript, recording: recording) : [
            Stage(index: 1, start: 0, end: recording.duration, paragraphs: transcript.paragraphs)
        ]

        for stage in stages {
            if includeStages && stages.count > 1 {
                lines.append("### Этап \(stage.index) · \(clock(stage.start, recording: recording))–\(clock(stage.end, recording: recording))")
                lines.append("")
            }
            for paragraph in stage.paragraphs {
                let stamp = clock(paragraph.start, recording: recording)
                if paragraph.speaker == .unknown {
                    lines.append("`\(stamp)` \(paragraph.text)")
                } else {
                    lines.append("**\(recording.speakerTitle(for: paragraph.speaker))** `\(stamp)`  ")
                    lines.append(paragraph.text)
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Легенда

    static func legend(_ transcript: Transcript, recording: Recording) -> [String] {
        var lines: [String] = ["## Как это записано", ""]

        lines.append("- **Тип записи:** \(typeDescription(recording))")
        lines.append("- **Начало:** \(Fmt.date(recording.createdAt))")
        lines.append("- **Длительность:** \(Fmt.duration(recording.duration))")

        if let hint = recording.appHint {
            lines.append("- **Источник звука:** приложение «\(hint)» на этом Mac; "
                         + "его звук снят с системного вывода, отдельного доступа к приложению не требовалось")
        }

        let kinds = Set(recording.tracks.map(\.kind))
        if !kinds.isEmpty {
            lines.append("- **Дорожки и говорящие:**")
            if kinds.contains(.mic) {
                let device = recording.micDeviceName ?? "микрофон по умолчанию"
                lines.append("  - **«Я»** — микрофон Mac: \(device). Это владелец компьютера.")
            }
            if kinds.contains(.system) {
                lines.append("  - **«Собеседник»** — захват звука системы: всё, что звучало в динамиках "
                             + "или наушниках, то есть голоса остальных участников."
                             + (recording.appHint.map { " В данном случае — из «\($0)»." } ?? ""))
            }
            if kinds.contains(.original) {
                lines.append("  - **«Речь»** — импортированный файл, разделения по источникам нет.")
            }
            if kinds.contains(.mixed) {
                lines.append("  - **«Речь»** — смикшированная дорожка, разделения по источникам нет.")
            }
        }

        let voices = Set(transcript.segments.compactMap { segment -> Int? in
            if case .voice(let index) = segment.speaker { return index } else { return nil }
        })
        if voices.isEmpty {
            lines.append("- **Разделение говорящих:** по источнику звука. Если с одного микрофона "
                         + "говорят несколько человек, они попадут в одну реплику.")
        } else {
            let named = voices.sorted().map { index in
                recording.speakerTitle(for: .voice(index))
            }
            let how = recording.expectedSpeakers != nil
                ? "число говорящих было задано вручную"
                : "число говорящих определено по звуку"
            lines.append("- **Говорящие:** \(named.joined(separator: ", ")) — \(how). "
                         + "Разделение акустическое, по высоте и тембру голоса; "
                         + "одновременную речь двоих оно не разделяет.")
        }

        let modelTitle = ModelCatalog.spec(id: transcript.modelID)?.title ?? transcript.modelID
        lines.append("- **Распознавание:** \(modelTitle), локально на этом Mac")
        lines.append("- **Язык:** \(Languages.title(for: transcript.language))")
        lines.append("- **Реплик:** \(transcript.segments.count), слов: \(transcript.wordCount)")

        if recording.isContinuous {
            lines.append("- **Замечание:** это непрерывная запись за день, нарезанная на отрезки. "
                         + "Таймкоды считаются от начала записи.")
        }
        return lines
    }

    private static func typeDescription(_ recording: Recording) -> String {
        switch recording.source {
        case .meeting:
            return "разговор или встреча" + (recording.appHint.map { " в «\($0)»" } ?? "")
        case .continuous:
            return "непрерывная запись за день"
        case .microphone:
            return "запись с микрофона"
        case .imported:
            return "импортированный файл"
        }
    }

    // MARK: - Этапы

    struct Stage {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
        let paragraphs: [(speaker: Segment.Speaker, start: TimeInterval, text: String)]
    }

    /// Делит расшифровку на этапы по паузам. Без всякой модели: если три минуты
    /// никто не говорил, это почти наверняка другой разговор или другое занятие.
    static func stages(_ transcript: Transcript, recording: Recording) -> [Stage] {
        let paragraphs = transcript.paragraphs
        guard !paragraphs.isEmpty else { return [] }

        var stages: [Stage] = []
        var current: [(speaker: Segment.Speaker, start: TimeInterval, text: String)] = []
        var stageStart = paragraphs[0].start
        var previousStart = paragraphs[0].start

        for paragraph in paragraphs {
            if !current.isEmpty, paragraph.start - previousStart > stageGap {
                stages.append(Stage(index: stages.count + 1, start: stageStart,
                                    end: previousStart, paragraphs: current))
                current = []
                stageStart = paragraph.start
            }
            current.append(paragraph)
            previousStart = paragraph.start
        }
        if !current.isEmpty {
            stages.append(Stage(index: stages.count + 1, start: stageStart,
                                end: previousStart, paragraphs: current))
        }
        return stages
    }

    /// Для дневной записи полезнее время суток, для остальных — от начала записи.
    private static func clock(_ offset: TimeInterval, recording: Recording) -> String {
        guard recording.isContinuous else { return Fmt.duration(offset) }
        return Fmt.shortTime(recording.createdAt.addingTimeInterval(offset))
    }
}
