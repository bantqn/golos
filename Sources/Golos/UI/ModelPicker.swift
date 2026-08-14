import SwiftUI

/// Выбор активной модели. Используется в трёх местах — в настройках, на экране
/// диктовки и в разделе моделей, — поэтому вынесен отдельным компонентом.
struct ModelPicker: View {
    let title: String
    let hint: String
    let symbol: String
    @Binding var selection: String
    /// Вызывается после смены модели: обычно чтобы выгрузить прежнюю из памяти.
    var onChange: ((ModelSpec) -> Void)?

    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var settings: Settings

    private var installed: [ModelSpec] { models.installedSpeechModels }
    private var current: ModelSpec? { ModelCatalog.spec(id: selection) }
    private var isReady: Bool { models.isInstalled(selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.gradient(settings.accent))
                Text(title)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                Spacer()
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if installed.isEmpty {
                Text("Ни одной модели не скачано")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
            } else {
                Menu {
                    ForEach(grouped) { group in
                        Section(group.engine.title) {
                            ForEach(group.models) { spec in
                                Button {
                                    guard selection != spec.id else { return }
                                    selection = spec.id
                                    // Прежняя модель больше не нужна в памяти.
                                    Engines.unloadAll()
                                    onChange?(spec)
                                } label: {
                                    Label(
                                        "\(spec.title) · \(Fmt.bytes(spec.sizeBytes))",
                                        systemImage: selection == spec.id ? "checkmark.circle.fill" : "circle"
                                    )
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.gradient(settings.accent).opacity(isReady ? 0.2 : 0.08))
                                .frame(width: 28, height: 28)
                            Image(systemName: isReady ? "cube.fill" : "cube")
                                .font(.system(size: 11))
                                .foregroundStyle(isReady
                                                 ? AnyShapeStyle(Theme.gradient(settings.accent))
                                                 : AnyShapeStyle(Color.secondary))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(current?.title ?? selection)
                                .font(.system(.callout, design: .rounded, weight: .medium))
                                .contentTransition(.opacity)
                            HStack(spacing: 5) {
                                if let current {
                                    Text(current.engine.title)
                                    Text("·")
                                    Text(Fmt.bytes(current.sizeBytes))
                                }
                                if !isReady {
                                    Text("— не скачана, возьму другую")
                                        .foregroundStyle(Theme.warning)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

                if current?.engine == .parakeet {
                    Label("Parakeet определяет язык сам: выбор языка и перевод к нему не применяются.",
                          systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Модели сгруппированы по движку: у whisper и Parakeet разное поведение,
    /// и в одном плоском списке это путало бы.
    private var grouped: [EngineGroup] {
        let byEngine = Dictionary(grouping: installed, by: \.engine)
        let order: [ModelSpec.Engine] = [.whisper, .parakeet]
        return order.compactMap { engine in
            guard let items = byEngine[engine], !items.isEmpty else { return nil }
            return EngineGroup(engine: engine, models: items.sorted { $0.quality > $1.quality })
        }
    }

    private struct EngineGroup: Identifiable {
        let engine: ModelSpec.Engine
        let models: [ModelSpec]
        var id: String { engine.rawValue }
    }
}
