import SwiftUI
import AppKit

/// Содержимое панели диктовки: плашка и скрытая под ней панель настроек.
struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: Settings
    @ObservedObject var models: ModelStore
    /// Панель обтягивает содержимое: размер сообщаем наружу, чтобы прозрачные
    /// поля не перехватывали щелчки мимо плашки.
    let onSizeChange: (NSSize) -> Void

    var body: some View {
        VStack(spacing: 8) {
            DictationPill(
                phase: controller.phase,
                level: controller.level,
                waveform: controller.waveform,
                elapsed: controller.elapsed,
                partialText: controller.partialText,
                opacity: settings.hudOpacity,
                accent: settings.accent,
                settingsExpanded: controller.hudSettingsExpanded,
                onToggleSettings: { controller.hudSettingsExpanded.toggle() }
            )

            if controller.hudSettingsExpanded {
                HUDSettingsPanel(settings: settings, models: models)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Оставляем только место под мягкую тень. Большие поля увеличивали
        // прозрачное окно и делали AppKit-артефакт особенно заметным.
        .padding(6)
        .fixedSize()
        .background(sizeReporter)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: controller.hudSettingsExpanded)
    }

    private var sizeReporter: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: geometry.size, initial: true) { _, size in
                    onSizeChange(NSSize(width: size.width, height: size.height))
                }
        }
    }
}

/// Тёмная пилюля с состоянием диктовки.
struct DictationPill: View {
    let phase: DictationController.Phase
    var level: Float = 0
    var waveform: [Float] = Array(repeating: 0, count: 40)
    var elapsed: TimeInterval = 0
    var partialText: String = ""
    var opacity: Double = 0.86
    let accent: Settings.AccentTheme
    var settingsExpanded: Bool = false
    var onToggleSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                content
                if onToggleSettings != nil { trailingControls }
            }
            // Черновик по ходу речи — под основной строкой, чтобы не растягивать её.
            if phase == .listening, !partialText.isEmpty {
                Text(partialText)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        // Радиус 19 при высоте 38 pt даёт ровно капсулу, а когда появляется
        // черновик и плашка становится выше — аккуратный скруглённый
        // прямоугольник. Одна фигура вместо двух ветвей.
        .background(shape.fill(Color.black.opacity(opacity)))
        .overlay(shape.strokeBorder(accentBorder.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.28 * opacity), radius: 8, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: phase)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 19, style: .continuous)
    }

    private var accentBorder: Color {
        switch phase {
        case .listening: return Theme.primary(accent)
        case .recognizing, .processing: return Theme.primary(accent).opacity(0.7)
        case .inserted, .copiedOnly: return Theme.success
        case .failed: return Theme.danger
        case .idle: return Theme.primary(accent).opacity(0.4)
        }
    }

    /// Ручка перемещения и шестерёнка настроек.
    private var trailingControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))
                .help("Потяните, чтобы переместить")

            Button {
                onToggleSettings?()
            } label: {
                Image(systemName: settingsExpanded ? "chevron.down" : "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Настройки диктовки")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Text("Готов")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

        case .listening:
            Circle()
                .fill(Theme.gradient(accent))
                .frame(width: 8, height: 8)
                .scaleEffect(1 + CGFloat(level) * 0.9)
                .animation(.spring(response: 0.18, dampingFraction: 0.55), value: level)

            LiveWaveform(levels: waveform, accent: accent,
                         barWidth: 2, spacing: 2, minHeight: 2)
                .frame(width: 120, height: 18)

            Text(Fmt.duration(elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            Text("esc")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.1)))

        case .processing:
            ThinkingDots(accent: accent)
            Text("Обрабатываю")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

        case .recognizing:
            ThinkingDots(accent: accent)
            Text("Распознаю")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

        case .inserted(let text):
            resultRow(symbol: "checkmark", tint: Theme.success, text: text)

        case .copiedOnly(let text):
            resultRow(symbol: "doc.on.clipboard", tint: Theme.warning, text: text)

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: 240, alignment: .leading)
        }
    }

    private func resultRow(symbol: String, tint: Color, text: String) -> some View {
        Group {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 230, alignment: .leading)
        }
    }
}

/// Основные настройки прямо в плашке. По умолчанию скрыты.
struct HUDSettingsPanel: View {
    @ObservedObject var settings: Settings
    @ObservedObject var models: ModelStore

    private var installed: [ModelSpec] { models.installedSpeechModels }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            slider

            divider
            modelRow
            divider

            segmented(title: "Активация",
                      options: DictationMode.allCases.map { ($0.title, $0) },
                      selection: $settings.dictationMode)

            segmented(title: "Вставка",
                      options: InsertionMode.allCases.map { ($0.title, $0) },
                      selection: $settings.insertionMode)

            divider

            toggle("Текст по ходу речи", isOn: $settings.livePreview)
            toggle("Оставлять в буфере обмена", isOn: $settings.keepTextInClipboard)
            toggle("Звуковые сигналы", isOn: $settings.dictationSound)

            Text("Сочетание: \(settings.dictationHotKey.displayString) · Escape — отмена")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(14)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(settings.hudOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }

    private var slider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Прозрачность")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("\(Int((1 - settings.hudOpacity) * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            // Значение хранится как непрозрачность фона, а показываем
            // прозрачность — так понятнее: больше процент, больше видно насквозь.
            Slider(value: Binding(
                get: { 1 - settings.hudOpacity },
                set: { settings.hudOpacity = 1 - $0 }
            ), in: 0...0.75)
            .controlSize(.mini)
            .tint(Theme.primary(settings.accent))
        }
    }

    private var modelRow: some View {
        HStack(spacing: 8) {
            Text("Модель")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            if installed.isEmpty {
                Text("не скачана")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
            } else {
                Menu {
                    ForEach(installed) { spec in
                        Button {
                            settings.dictationModelID = spec.id
                            Engines.unloadAll()
                        } label: {
                            Label(spec.title, systemImage: settings.dictationModelID == spec.id
                                  ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Text(ModelCatalog.spec(id: settings.dictationModelID)?.title ?? settings.dictationModelID)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: 170, alignment: .trailing)
            }
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.primary(settings.accent))
        }
    }

    private func segmented<T: Hashable>(title: String,
                                        options: [(String, T)],
                                        selection: Binding<T>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 4) {
                ForEach(options, id: \.1) { option in
                    Button {
                        selection.wrappedValue = option.1
                    } label: {
                        Text(option.0)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(selection.wrappedValue == option.1
                                             ? Color.white : Color.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selection.wrappedValue == option.1
                                          ? Theme.primary(settings.accent).opacity(0.75)
                                          : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
