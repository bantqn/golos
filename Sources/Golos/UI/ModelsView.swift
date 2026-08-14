import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var models: ModelStore

    @State private var filter: Filter = .all
    @State private var pendingDeletion: ModelSpec?
    @Namespace private var selectionNamespace

    enum Filter: String, CaseIterable, Identifiable {
        case all, installed, multilingual, tools
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Все"
            case .installed: return "Скачанные"
            case .multilingual: return "Многоязычные"
            case .tools: return "Дополнения"
            }
        }
    }


    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                activeModels
                filterBar
                modelList
            }
            .padding(24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Удалить модель «\(pendingDeletion?.title ?? "")»?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let spec = pendingDeletion {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { models.delete(spec) }
                }
                pendingDeletion = nil
            }
            Button("Отмена", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Освободится \(Fmt.bytes(pendingDeletion?.sizeBytes ?? 0)). Скачать заново можно в любой момент.")
        }
    }

    // MARK: - Шапка

    private var header: some View {
        Card {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Модели распознавания")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("Всё считается на этом маке. Модели скачиваются один раз и лежат внутри контейнера приложения.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Fmt.bytes(models.totalSizeOnDisk))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("занято моделями")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("свободно \(Fmt.bytes(Container.freeDiskSpace()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Выбранные модели

    private var activeModels: some View {
        HStack(spacing: 12) {
            activeSlot(
                title: "Для записей и файлов",
                subtitle: "качество важнее скорости",
                symbol: "rectangle.stack.fill",
                selection: $settings.transcriptionModelID
            )
            activeSlot(
                title: "Для диктовки",
                subtitle: "скорость важнее всего",
                symbol: "waveform.badge.mic",
                selection: $settings.dictationModelID
            )
        }
    }

    private func activeSlot(title: String, subtitle: String, symbol: String,
                            selection: Binding<String>) -> some View {
        let installed = models.installedSpeechModels
        let current = ModelCatalog.spec(id: selection.wrappedValue)
        let isReady = models.isInstalled(selection.wrappedValue)

        return Card(padding: 15) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.gradient(settings.accent))
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                    Spacer()
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if installed.isEmpty {
                    Text("Ни одной модели ещё не скачано")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(installed) { spec in
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                    selection.wrappedValue = spec.id
                                }
                                Engines.unloadAll()
                                env.banner = .init(text: "Активная модель: \(spec.title)", kind: .success)
                            } label: {
                                Label(spec.title, systemImage: selection.wrappedValue == spec.id
                                      ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            // Плитка модели «переезжает» между слотами при смене выбора.
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.gradient(settings.accent).opacity(isReady ? 0.2 : 0.08))
                                    .frame(width: 30, height: 30)
                                Image(systemName: isReady ? "cube.fill" : "cube")
                                    .font(.system(size: 12))
                                    .foregroundStyle(isReady
                                                     ? AnyShapeStyle(Theme.gradient(settings.accent))
                                                     : AnyShapeStyle(Color.secondary))
                            }
                            .matchedGeometryEffect(id: "slot-\(title)", in: selectionNamespace)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(current?.title ?? selection.wrappedValue)
                                    .font(.system(.callout, design: .rounded, weight: .medium))
                                    .contentTransition(.opacity)
                                Text(isReady
                                     ? Fmt.bytes(current?.sizeBytes ?? 0)
                                     : "не скачана — будет выбрана другая")
                                    .font(.caption2)
                                    .foregroundStyle(isReady ? .secondary : Theme.warning)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .id(selection.wrappedValue)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Фильтр

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { filter = item }
                } label: {
                    Text(item.title)
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background {
                            if filter == item {
                                Capsule()
                                    .fill(Theme.gradient(settings.accent).opacity(0.9))
                                    .matchedGeometryEffect(id: "filter", in: selectionNamespace)
                            } else {
                                Capsule().fill(Color.primary.opacity(0.06))
                            }
                        }
                        .foregroundStyle(filter == item ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Список

    private var modelList: some View {
        VStack(spacing: 20) {
            ForEach(visibleGroups, id: \.family) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.family.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.secondary)
                    ForEach(group.models) { spec in
                        ModelRow(
                            spec: spec,
                            state: models.state(for: spec.id),
                            isActiveForTranscription: settings.transcriptionModelID == spec.id,
                            isActiveForDictation: settings.dictationModelID == spec.id,
                            isDownloadAlive: models.hasActiveDownload(spec.id),
                            memoryNote: spec.kind == .vad
                                ? nil
                                : MemoryGuard.rejection(for: spec, settings: settings),
                            onDownload: { withAnimation { models.download(spec) } },
                            onPause: { models.pause(spec) },
                            onCancel: { withAnimation { models.cancel(spec) } },
                            onDelete: { pendingDeletion = spec }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: filter)
    }

    private var visibleGroups: [(family: ModelSpec.Family, models: [ModelSpec])] {
        ModelCatalog.grouped.compactMap { group in
            let filtered = group.models.filter(matches)
            return filtered.isEmpty ? nil : (family: group.family, models: filtered)
        }
    }

    private func matches(_ spec: ModelSpec) -> Bool {
        switch filter {
        case .all: return true
        case .installed: return models.isInstalled(spec.id)
        case .multilingual: return !spec.englishOnly && spec.kind == .speech
        case .tools: return spec.kind != .speech
        }
    }
}

/// Строка каталога с кнопкой загрузки и живым прогрессом.
struct ModelRow: View {
    let spec: ModelSpec
    let state: ModelState
    let isActiveForTranscription: Bool
    let isActiveForDictation: Bool
    /// Жива ли задача загрузки. Если нет, а состояние всё ещё «загружается», —
    /// показываем кнопку сброса вместо паузы.
    var isDownloadAlive: Bool = true
    /// Заполнено, если модель сейчас не влезает в память с учётом запаса.
    var memoryNote: String? = nil
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var settings: Settings
    @State private var hovering = false

    var body: some View {
        Card(padding: 15) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    icon

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(spec.title)
                                .font(.system(.headline, design: .rounded, weight: .medium))
                            if isActiveForTranscription {
                                Pill(text: "записи", color: Theme.primary(settings.accent), filled: true)
                            }
                            if isActiveForDictation {
                                Pill(text: "диктовка", color: Theme.success, filled: true)
                            }
                            if spec.englishOnly {
                                Pill(text: "EN", color: .secondary)
                            }
                            if spec.quantized {
                                Pill(text: "Q", color: .secondary)
                            }
                        }
                        Text(spec.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 16) {
                            metric(title: "Размер", value: Fmt.bytes(spec.sizeBytes))
                            if spec.kind == .speech {
                                HStack(spacing: 6) {
                                    Text("Скорость").font(.caption2).foregroundStyle(.tertiary)
                                    RatingBars(value: spec.speed, tint: Theme.success)
                                }
                                HStack(spacing: 6) {
                                    Text("Точность").font(.caption2).foregroundStyle(.tertiary)
                                    RatingBars(value: spec.quality, tint: Theme.primary(settings.accent))
                                }
                                metric(title: "ОЗУ", value: "≈" + Fmt.bytes(spec.estimatedRAM))
                            }
                        }
                    }

                    Spacer(minLength: 8)
                    actionArea
                }

                if case .downloading(let progress, let received, let speed) = state {
                    VStack(spacing: 5) {
                        GradientProgress(value: progress, accent: settings.accent, height: 6)
                        HStack {
                            Text("\(Fmt.bytes(received)) из \(Fmt.bytes(spec.sizeBytes))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if speed > 0 {
                                Text("\(Fmt.bytes(Int64(speed)))/с · осталось \(remaining(received: received, speed: speed))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if case .failed(let message) = state {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                        Spacer()
                    }
                }

                if let memoryNote {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "memorychip")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                        Text(memoryNote)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(
                    (isActiveForTranscription || isActiveForDictation)
                        ? AnyShapeStyle(Theme.gradient(settings.accent).opacity(0.55))
                        : AnyShapeStyle(Color.clear),
                    lineWidth: 1.5
                )
        )
        .scaleEffect(hovering ? 1.004 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .animation(.easeOut(duration: 0.25), value: state)
        .onHover { hovering = $0 }
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(state.isInstalled
                      ? AnyShapeStyle(Theme.gradient(settings.accent).opacity(0.18))
                      : AnyShapeStyle(Color.primary.opacity(0.05)))
                .frame(width: 42, height: 42)

            if case .downloading(let progress, _, _) = state {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Theme.gradient(settings.accent),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 30, height: 30)
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 16))
                    .foregroundStyle(state.isInstalled
                                     ? AnyShapeStyle(Theme.gradient(settings.accent))
                                     : AnyShapeStyle(Color.secondary))
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var symbolName: String {
        switch spec.kind {
        case .vad: return "waveform.badge.magnifyingglass"
        case .diarization: return "person.2.badge.gearshape"
        case .speech: return state.isInstalled ? "cube.fill" : "cube"
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch state {
        case .notInstalled:
            Button("Скачать", action: onDownload)
                .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))

        case .downloading:
            HStack(spacing: 6) {
                if isDownloadAlive {
                    Button(action: onPause) { Image(systemName: "pause.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Приостановить")
                }
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(isDownloadAlive ? "Отменить" : "Сбросить застрявшую загрузку")
            }

        case .paused(let received):
            HStack(spacing: 8) {
                Text(Fmt.bytes(received)).font(.caption2).foregroundStyle(.tertiary)
                Button("Продолжить", action: onDownload)
                    .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
            }

        case .installed:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .transition(.scale.combined(with: .opacity))
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(hovering ? Theme.danger : .secondary)
                    .help("Удалить модель")
            }

        case .failed:
            Button("Повторить", action: onDownload)
                .buttonStyle(AccentButtonStyle(accent: settings.accent, prominent: false))
        }
    }

    private func metric(title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func remaining(received: Int64, speed: Double) -> String {
        let left = Double(spec.sizeBytes - received)
        guard speed > 1, left > 0 else { return "—" }
        return Fmt.duration(left / speed)
    }
}
