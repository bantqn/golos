import Foundation
import UniformTypeIdentifiers

/// Форматы, в которые можно выгрузить расшифровку.
enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, markdown, srt, vtt, json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: return "Текст"
        case .markdown: return "Markdown"
        case .srt: return "Субтитры SRT"
        case .vtt: return "Субтитры WebVTT"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .json: return "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .txt: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .srt, .vtt: return .plainText
        case .json: return .json
        }
    }
}

enum Exporter {

    static func render(_ transcript: Transcript, recording: Recording, format: ExportFormat) -> String {
        switch format {
        case .txt: return plainText(transcript, recording: recording)
        case .markdown: return markdown(transcript, recording: recording)
        case .srt: return srt(transcript, recording: recording)
        case .vtt: return vtt(transcript, recording: recording)
        case .json: return json(transcript)
        }
    }

    private static func plainText(_ transcript: Transcript, recording: Recording) -> String {
        transcript.paragraphs.map { paragraph in
            let stamp = Fmt.duration(paragraph.start)
            let speaker = paragraph.speaker == .unknown
                ? "" : "\(recording.speakerTitle(for: paragraph.speaker)): "
            return "[\(stamp)] \(speaker)\(paragraph.text)"
        }.joined(separator: "\n\n")
    }

    private static func markdown(_ transcript: Transcript, recording: Recording) -> String {
        TranscriptMarkdown.render(transcript, recording: recording)
    }

    private static func srt(_ transcript: Transcript, recording: Recording) -> String {
        transcript.segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(Fmt.srtTimestamp(segment.start)) --> \(Fmt.srtTimestamp(segment.end))
            \(prefixed(segment, recording: recording))
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private static func vtt(_ transcript: Transcript, recording: Recording) -> String {
        let body = transcript.segments.map { segment in
            """
            \(Fmt.vttTimestamp(segment.start)) --> \(Fmt.vttTimestamp(segment.end))
            \(prefixed(segment, recording: recording))
            """
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n" + body + "\n"
    }

    private static func prefixed(_ segment: Segment, recording: Recording) -> String {
        guard segment.speaker != .unknown else { return segment.text }
        return "\(recording.speakerTitle(for: segment.speaker)): \(segment.text)"
    }

    private static func json(_ transcript: Transcript) -> String {
        guard let data = try? JSONEncoder.golos.encode(transcript),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// Записывает файл в папку экспорта внутри контейнера и возвращает путь.
    static func writeToContainer(_ text: String, recording: Recording, format: ExportFormat) throws -> URL {
        try FileManager.default.createDirectory(at: Container.exports, withIntermediateDirectories: true)
        let safeTitle = recording.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = Container.exports.appendingPathComponent("\(safeTitle).\(format.fileExtension)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
