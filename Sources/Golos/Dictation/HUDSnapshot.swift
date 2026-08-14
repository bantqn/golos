import SwiftUI
import AppKit

/// Отрисовка плашки диктовки в PNG — диагностика внешнего вида.
///
/// Запуск с `GOLOS_HUD_SNAPSHOT=/путь/картинка.png` рисует все состояния плашки
/// и завершает приложение. Нужно, чтобы проверять оформление, не гоняя диктовку
/// вживую: плашка живёт в отдельном окне поверх всех, и поймать её иначе трудно.
@MainActor
enum HUDSnapshot {

    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["GOLOS_HUD_SNAPSHOT"] else { return false }
        render(to: URL(fileURLWithPath: path))
        return true
    }

    private static func render(to url: URL) {
        // Волна с осмысленными значениями: на нулях её не видно.
        var waveform: [Float] = []
        for index in 0..<40 {
            let angle: Double = Double(index) / 6.0
            let envelope: Double = 0.4 + Double(index) / 60.0
            let value: Double = 0.25 + 0.7 * abs(sin(angle)) * envelope
            waveform.append(Float(value))
        }

        // Явная структура вместо массива кортежей: на кортежах с ассоциированными
        // значениями компилятор не укладывается в разумное время проверки типов.
        struct Sample: Identifiable {
            let id: Int
            let caption: String
            let phase: DictationController.Phase
            let level: Float
            let elapsed: TimeInterval
            var partial: String = ""
            var opacity: Double = 0.86
        }

        let samples: [Sample] = [
            Sample(id: 0, caption: "слушаю", phase: .listening, level: 0.7, elapsed: 3),
            Sample(id: 5, caption: "слушаю · черновик по ходу речи",
                   phase: .listening, level: 0.55, elapsed: 7,
                   partial: "Добавь возможность перемещать окошко при диктовке и показывать текст"),
            Sample(id: 6, caption: "прозрачность 50%",
                   phase: .listening, level: 0.4, elapsed: 2, opacity: 0.5),
            Sample(id: 7, caption: "в покое, с ручкой и шестерёнкой",
                   phase: .idle, level: 0, elapsed: 0),
            Sample(id: 1, caption: "распознаю", phase: .recognizing, level: 0, elapsed: 0),
            Sample(id: 2, caption: "вставлено",
                   phase: .inserted("Проверка распознавания речи в любом приложении"),
                   level: 0, elapsed: 0),
            Sample(id: 3, caption: "только буфер",
                   phase: .copiedOnly("Текст скопирован, вставить было некуда"),
                   level: 0, elapsed: 0),
            Sample(id: 4, caption: "ошибка",
                   phase: .failed("Речь не распознана. Попробуйте ближе к микрофону."),
                   level: 0, elapsed: 0)
        ]

        let accent = AppEnvironment.sharedSettings.accent
        let content = VStack(spacing: 0) {
            ForEach(samples) { sample in
                VStack(spacing: 3) {
                    Text(sample.caption)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.45))
                    DictationPill(
                        phase: sample.phase,
                        level: sample.level,
                        waveform: waveform,
                        elapsed: sample.elapsed,
                        partialText: sample.partial,
                        opacity: sample.opacity,
                        accent: accent,
                        settingsExpanded: false,
                        onToggleSettings: {}
                    )
                    .frame(width: 380)
                }
            }
        }
        .padding(14)
        // Ярко-малиновая подложка: на ней сразу видно любой непрозрачный
        // прямоугольник, который плашка нарисовала бы вокруг себя.
        .background(Color(red: 0.85, green: 0.1, blue: 0.55))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("Не удалось отрисовать плашку\n".utf8))
            Log.flush()
            _exit(1)
        }
        try? png.write(to: url)
        print("Плашка отрисована: \(url.path)")
        // Минуя деструкторы: ggml падает в них при живом Metal-контексте.
        Log.flush()
        _exit(0)
    }
}
