import SwiftUI

/// Кто говорит на записи: сколько человек и как их зовут.
///
/// Смысл в том, что автоопределение числа голосов — самая шаткая часть
/// разделения: приложение решает по звуку, где кончается один голос и начинается
/// другой, и на короткой записи или похожих голосах может ошибиться. Если число
/// известно, оно задаётся здесь и угадывать больше не приходится: реплики
/// раскладываются ровно на столько ролей, сколько сказано. Имена — просто
/// подписи вместо «голос 1», но в расшифровке, которая уходит в LLM, они
/// заметно полезнее номеров.
struct SpeakerSetupView: View {
    /// `nil` — определить число голосов автоматически.
    @Binding var expected: Int?
    @Binding var names: [String]

    /// Показывать пояснение сверху — в диалоге импорта оно нужно, в карточке нет.
    var showsExplanation = true

    private let limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if showsExplanation {
                Text("Если сказать, сколько человек говорит, роли разделятся точнее: "
                     + "приложению не придётся угадывать их число по звуку.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Говорящих")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                Picker("", selection: Binding(
                    get: { expected ?? 0 },
                    set: { apply(count: $0) }
                )) {
                    Text("Определить самому").tag(0)
                    ForEach(1...limit, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
                Spacer()
            }

            if let expected, expected > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Имена — необязательно")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(0..<expected, id: \.self) { index in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 14, alignment: .trailing)
                            TextField("голос \(index + 1)", text: name(at: index))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                        }
                    }
                }
            } else if expected == 1 {
                Text("Одна дорожка, один голос — делить нечего.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func apply(count: Int) {
        expected = count == 0 ? nil : count
        // Список имён держим ровно по числу голосов, иначе лишние строки
        // всплывут, когда пользователь снова увеличит число.
        if let expected {
            if names.count < expected {
                names.append(contentsOf: Array(repeating: "", count: expected - names.count))
            } else if names.count > expected {
                names.removeSubrange(expected..<names.count)
            }
        }
    }

    private func name(at index: Int) -> Binding<String> {
        Binding(
            get: { index < names.count ? names[index] : "" },
            set: { value in
                while names.count <= index { names.append("") }
                names[index] = value
            }
        )
    }
}

/// Диалог после импорта файла. Отдельный тип, потому что в нём есть свои
/// кнопки и он ведёт себя как лист, а сама форма переиспользуется в карточке.
struct ImportSpeakersSheet: View {
    let recordings: [Recording]
    /// Возвращает выбранное. `nil` вместо числа — определять автоматически.
    let onDone: (Int?, [String]) -> Void
    let onSkip: () -> Void

    @State private var expected: Int?
    @State private var names: [String] = []
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            SpeakerSetupView(expected: $expected, names: $names)

            Divider().opacity(0.4)

            HStack {
                Toggle("Больше не спрашивать", isOn: Binding(
                    get: { !settings.askSpeakersOnImport },
                    set: { settings.askSpeakersOnImport = !$0 }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .fixedSize()

                Spacer()

                Button("Определить самому") { onSkip() }
                Button(startTitle) { onDone(expected, names) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private var title: String {
        recordings.count == 1 ? "Кто говорит на записи?" : "Кто говорит на этих записях?"
    }

    private var subtitle: String {
        recordings.count == 1
            ? (recordings.first?.title ?? "")
            : "Файлов: \(recordings.count) — настройка применится ко всем"
    }

    private var startTitle: String {
        settings.autoTranscribeAfterRecording ? "Расшифровать" : "Сохранить"
    }
}
