import SwiftUI
import Charts

struct SystemView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var library: LibraryStore

    private var snapshot: LoadSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                gauges
                chartsCard
                coresCard
                engineCard
                storageCard
            }
            .padding(24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Кольца

    private var gauges: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionTitle(text: "Нагрузка на мак",
                                 subtitle: "Всё распознавание идёт локально — вот его цена в ресурсах")
                    Spacer()
                    thermalBadge
                }

                HStack(spacing: 26) {
                    GaugeRing(value: snapshot.cpuTotal, caption: "CPU",
                              detail: "\(snapshot.perCore.count) ядер", accent: settings.accent)

                    if snapshot.gpu >= 0 {
                        GaugeRing(value: snapshot.gpu, caption: "GPU",
                                  detail: settings.useGPU ? "Metal включён" : "Metal выключен",
                                  accent: settings.accent)
                    }

                    GaugeRing(value: snapshot.memoryPressure, caption: "Память",
                              detail: "\(Fmt.bytes(snapshot.memoryUsed)) из \(Fmt.bytes(snapshot.memoryTotal))",
                              accent: settings.accent,
                              tint: snapshot.memoryPressure > 85 ? Theme.warning : nil)

                    Divider().frame(height: 90)

                    VStack(alignment: .leading, spacing: 12) {
                        appMetric(title: "голос · процессор", value: Fmt.percent(snapshot.appCPU),
                                  fraction: snapshot.appCPU / 100)
                        appMetric(title: "голос · память", value: Fmt.bytes(snapshot.appMemory),
                                  fraction: snapshot.memoryTotal > 0
                                    ? Double(snapshot.appMemory) / Double(snapshot.memoryTotal) : 0)
                        if snapshot.lowPowerMode {
                            Label("Включён режим энергосбережения — распознавание будет медленнее",
                                  systemImage: "battery.25")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var thermalBadge: some View {
        let color: Color = {
            switch snapshot.thermal {
            case .nominal: return Theme.success
            case .fair: return Theme.success
            case .serious: return Theme.warning
            case .critical: return Theme.danger
            @unknown default: return .secondary
            }
        }()
        return Pill(text: "Температура: \(snapshot.thermalTitle)", color: color)
    }

    private func appMetric(title: String, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            GradientProgress(value: fraction, accent: settings.accent, height: 5)
        }
        .frame(width: 210)
    }

    // MARK: - Графики

    private var chartsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Последние \(monitor.history.count) секунд")
                    .font(.system(.headline, design: .rounded))

                HStack(spacing: 16) {
                    chartBlock(title: "Процессор",
                               values: monitor.history.map(\.cpuTotal),
                               current: snapshot.cpuTotal)
                    if snapshot.gpu >= 0 {
                        chartBlock(title: "Видеоядро",
                                   values: monitor.history.map { max(0, $0.gpu) },
                                   current: snapshot.gpu)
                    }
                    chartBlock(title: "Память",
                               values: monitor.history.map(\.memoryPressure),
                               current: snapshot.memoryPressure)
                }
            }
        }
    }

    private func chartBlock(title: String, values: [Double], current: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Sparkline(values: values, accent: settings.accent)
                .frame(height: 62)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ядра

    private var coresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("По ядрам")
                    .font(.system(.headline, design: .rounded))
                Text("whisper задействует \(settings.threads) из \(snapshot.perCore.count) потоков")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(snapshot.perCore.enumerated()), id: \.offset) { index, value in
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.primary.opacity(0.07))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.gradient(settings.accent))
                                    .frame(height: max(3, 72 * value / 100))
                            }
                            .frame(height: 72)
                            Text("\(index + 1)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.4), value: snapshot.perCore)
            }
        }
    }

    // MARK: - Движок

    private var engineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Движок распознавания")
                    .font(.system(.headline, design: .rounded))

                HStack(spacing: 12) {
                    StatTile(symbol: "cpu.fill", title: "Ускорение",
                             value: settings.useGPU ? "GPU · Metal" : "Только CPU",
                             detail: warmupDetail,
                             tint: settings.useGPU ? Theme.success : .secondary)
                    StatTile(symbol: "memorychip", title: "В памяти",
                             value: modelsInMemory.isEmpty ? "ничего" : "\(modelsInMemory.count)",
                             detail: modelsInMemory.isEmpty
                                 ? "выгружено, память свободна"
                                 : modelsInMemory.joined(separator: ", "),
                             tint: modelsInMemory.isEmpty ? Theme.success : Theme.warning)
                    StatTile(symbol: "square.stack.3d.up.fill", title: "Потоков",
                             value: "\(settings.threads)",
                             detail: "из \(ProcessInfo.processInfo.activeProcessorCount)")
                    StatTile(symbol: "cube.fill", title: "Модель для записей",
                             value: ModelCatalog.spec(id: settings.transcriptionModelID)?.title ?? "—",
                             detail: models.isInstalled(settings.transcriptionModelID) ? "скачана" : "не скачана",
                             tint: Theme.primary(settings.accent))
                    StatTile(symbol: "keyboard", title: "Модель для диктовки",
                             value: ModelCatalog.spec(id: settings.dictationModelID)?.title ?? "—",
                             detail: models.isInstalled(settings.dictationModelID) ? "скачана" : "не скачана",
                             tint: Theme.success)
                }

                if env.warmup == .running {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Компилирую GPU-ядра. Это происходит один раз после установки и занимает секунд десять.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var modelsInMemory: [String] {
        Engines.loadedModels.map { $0.replacingOccurrences(of: "ggml-", with: "") }
    }

    private var warmupDetail: String {
        switch env.warmup {
        case .ready: return "ядра прогреты"
        case .running: return "компиляция ядер…"
        case .unavailable: return "прогрев не удался"
        case .idle: return "ожидание"
        }
    }

    // MARK: - Диск

    private var storageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Место на диске")
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    Button("Показать папку") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Container.root.path)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.primary(settings.accent))
                }

                Text(Container.root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    StatTile(symbol: "cube.box.fill", title: "Модели",
                             value: Fmt.bytes(models.totalSizeOnDisk))
                    StatTile(symbol: "waveform", title: "Записи",
                             value: Fmt.bytes(Container.size(of: Container.recordings)),
                             detail: Fmt.plural(library.recordings.count, "запись", "записи", "записей"))
                    StatTile(symbol: "doc.text.fill", title: "Расшифровки",
                             value: Fmt.bytes(Container.size(of: Container.transcripts)))
                    StatTile(symbol: "internaldrive.fill", title: "Свободно",
                             value: Fmt.bytes(Container.freeDiskSpace()))
                }
            }
        }
    }
}
