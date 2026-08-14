import SwiftUI

/// Первый запуск: объясняем принцип, просим разрешения, качаем стартовую модель.
struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var models: ModelStore
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0

    private let steps = ["Как это работает", "Разрешения", "Первая модель"]

    var body: some View {
        ZStack {
            AuroraBackground(accent: settings.accent,
                                 animated: settings.animatedBackground && !settings.reduceMotion)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                progressBar
                Divider().opacity(0.3)

                Group {
                    switch step {
                    case 0: intro
                    case 1: permissions
                    default: modelsStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                Divider().opacity(0.3)
                footer
            }
        }
        .frame(width: 640, height: 560)
    }

    private var progressBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(index <= step
                                  ? AnyShapeStyle(Theme.gradient(settings.accent))
                                  : AnyShapeStyle(Color.primary.opacity(0.1)))
                            .frame(width: 22, height: 22)
                        if index < step {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index <= step ? .white : .secondary)
                        }
                    }
                    Text(title)
                        .font(.system(.caption, design: .rounded,
                                      weight: index == step ? .semibold : .regular))
                        .foregroundStyle(index == step ? .primary : .secondary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < step ? Theme.primary(settings.accent) : Color.primary.opacity(0.1))
                        .frame(height: 1.5)
                        .padding(.horizontal, 9)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
    }

    // MARK: - Шаги

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.gradient(settings.accent).opacity(0.18))
                    .frame(width: 108, height: 108)
                GolosMark().frame(width: 68, height: 42)
            }

            Text("голос")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Распознавание речи, которое не выходит за пределы вашего мака")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 13) {
                bullet("person.2.wave.2.fill", "Запись встреч",
                       "Zoom, Телемост в браузере, Telegram, что угодно — пишется системный звук и ваш микрофон отдельными дорожками")
                bullet("waveform.badge.mic", "Диктовка в любую программу",
                       "Зажали сочетание, сказали, отпустили — текст появился в активном поле ввода")
                bullet("lock.fill", "Одна папка на диске",
                       "Модели, записи и расшифровки лежат в контейнере приложения. Удалить всё — удалить папку")
            }
            .frame(maxWidth: 460)
            .padding(.top, 6)

            Spacer()
        }
        .padding(30)
    }

    private func bullet(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.gradient(settings.accent))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.callout, design: .rounded, weight: .semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Три разрешения")
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text("macOS спросит их сама. Без них часть функций просто не заработает — приложение честно скажет, чего не хватает.")
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionCard(
                symbol: "mic.fill",
                title: "Микрофон",
                text: "Нужен для записи вашего голоса и для диктовки.",
                granted: MicRecorder.permissionStatus == .authorized,
                action: { Task { _ = await MicRecorder.requestPermission() } }
            )
            permissionCard(
                symbol: "rectangle.inset.filled.and.person.filled",
                title: "Запись экрана",
                text: "Так macOS отдаёт системный звук — без него не записать собеседника. Видео не пишется: кадр 2×2 пикселя выбрасывается.",
                granted: SystemAudioRecorder.hasPermission,
                action: {
                    SystemAudioRecorder.requestPermission()
                    SystemAudioRecorder.openPermissionSettings()
                }
            )
            permissionCard(
                symbol: "hand.point.up.left.fill",
                title: "Универсальный доступ",
                text: "Нужен, чтобы вставлять распознанный текст в другие программы.",
                granted: TextInjector.isTrusted,
                action: {
                    TextInjector.requestTrust()
                    TextInjector.openAccessibilitySettings()
                }
            )
            Spacer()
        }
        .padding(30)
    }

    private func permissionCard(symbol: String, title: String, text: String,
                                granted: Bool, action: @escaping () -> Void) -> some View {
        Card(padding: 15) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(granted ? Theme.success : Theme.primary(settings.accent))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(.callout, design: .rounded, weight: .semibold))
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Разрешить", action: action)
                        .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: granted)
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Скачайте модель")
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text("Без модели распознавать нечем. Рекомендуем эти три — вместе меньше гигабайта.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(ModelCatalog.starterPack, id: \.self) { id in
                if let spec = ModelCatalog.spec(id: id) {
                    ModelRow(
                        spec: spec,
                        state: models.state(for: id),
                        isActiveForTranscription: settings.transcriptionModelID == id,
                        isActiveForDictation: settings.dictationModelID == id,
                        onDownload: { models.download(spec) },
                        onPause: { models.pause(spec) },
                        onCancel: { models.cancel(spec) },
                        onDelete: { models.delete(spec) }
                    )
                }
            }

            Text("Остальные модели — от 32 МБ до 3 ГБ — в разделе «Модели». Их можно скачивать и удалять когда угодно.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(30)
    }

    // MARK: - Низ

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Назад") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { step -= 1 }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if step < steps.count - 1 {
                Button("Дальше") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { step += 1 }
                }
                .buttonStyle(AccentButtonStyle(accent: settings.accent))
            } else {
                Button(models.hasAnyModel ? "Начать работу" : "Пропустить пока") {
                    env.showOnboarding = false
                    if models.hasAnyModel { env.warmUpEngine() }
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle(accent: settings.accent))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }
}
