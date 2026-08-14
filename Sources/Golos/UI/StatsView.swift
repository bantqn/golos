import SwiftUI
import Charts

/// Дашборд: сколько надиктовано и сколько расшифровано по дням, неделям и месяцам.
struct StatsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var dictation: DictationController

    @State private var period: StatsPeriod = .day

    private var buckets: [StatsBucket] {
        Stats.buckets(period: period, recordings: library.recordings, dictations: dictation.history)
    }

    private var total: StatsBucket {
        Stats.total(recordings: library.recordings, dictations: dictation.history)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                totals
                wordsChart
                timeChart
                breakdown
            }
            .padding(24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Статистика",
                             subtitle: "Всё считается из локальных метаданных — файлы расшифровок для этого не читаются")

                Picker("Период", selection: $period) {
                    ForEach(StatsPeriod.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var totals: some View {
        HStack(spacing: 12) {
            StatTile(symbol: "waveform.badge.mic", title: "Надиктовано слов",
                     value: "\(total.dictationWords)",
                     detail: Fmt.plural(total.dictationCount, "диктовка", "диктовки", "диктовок"),
                     tint: Theme.primary(settings.accent))
            StatTile(symbol: "text.viewfinder", title: "Расшифровано слов",
                     value: "\(total.transcribedWords)",
                     detail: Fmt.plural(total.recordingCount, "запись", "записи", "записей"),
                     tint: Theme.success)
            StatTile(symbol: "clock", title: "Речи надиктовано",
                     value: Fmt.duration(total.dictationSeconds))
            StatTile(symbol: "recordingtape", title: "Записано звука",
                     value: Fmt.duration(total.recordedSeconds))
        }
    }

    private var wordsChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                chartTitle("Слова", detail: "диктовка и расшифровки записей")

                if buckets.allSatisfy({ $0.totalWords == 0 }) {
                    emptyHint
                } else {
                    Chart {
                        ForEach(buckets) { bucket in
                            BarMark(
                                x: .value("Период", bucket.label),
                                y: .value("Слова", bucket.dictationWords)
                            )
                            .foregroundStyle(Theme.primary(settings.accent))
                            .position(by: .value("Вид", "Диктовка"))

                            BarMark(
                                x: .value("Период", bucket.label),
                                y: .value("Слова", bucket.transcribedWords)
                            )
                            .foregroundStyle(Theme.success)
                            .position(by: .value("Вид", "Записи"))
                        }
                    }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 180)
                }
            }
        }
    }

    private var timeChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                chartTitle("Минуты звука", detail: "сколько говорили и сколько записано")

                if buckets.allSatisfy({ $0.totalSeconds < 1 }) {
                    emptyHint
                } else {
                    Chart {
                        ForEach(buckets) { bucket in
                            BarMark(
                                x: .value("Период", bucket.label),
                                y: .value("Минуты", bucket.dictationSeconds / 60)
                            )
                            .foregroundStyle(Theme.primary(settings.accent))
                            .position(by: .value("Вид", "Диктовка"))

                            BarMark(
                                x: .value("Период", bucket.label),
                                y: .value("Минуты", bucket.recordedSeconds / 60)
                            )
                            .foregroundStyle(Theme.success)
                            .position(by: .value("Вид", "Записи"))
                        }
                    }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 180)
                }
            }
        }
    }

    /// Таблица по отрезкам — для тех случаев, когда нужны точные числа.
    private var breakdown: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                chartTitle("Подробно", detail: period.title.lowercased())

                HStack {
                    Text("Период").frame(width: 90, alignment: .leading)
                    Text("Диктовок").frame(width: 80, alignment: .trailing)
                    Text("Слов").frame(width: 70, alignment: .trailing)
                    Text("Записей").frame(width: 80, alignment: .trailing)
                    Text("Слов").frame(width: 70, alignment: .trailing)
                    Text("Звука").frame(width: 90, alignment: .trailing)
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                ForEach(buckets.reversed()) { bucket in
                    HStack {
                        Text(bucket.label).frame(width: 90, alignment: .leading)
                        Text("\(bucket.dictationCount)").frame(width: 80, alignment: .trailing)
                        Text("\(bucket.dictationWords)").frame(width: 70, alignment: .trailing)
                        Text("\(bucket.recordingCount)").frame(width: 80, alignment: .trailing)
                        Text("\(bucket.transcribedWords)").frame(width: 70, alignment: .trailing)
                        Text(Fmt.duration(bucket.recordedSeconds)).frame(width: 90, alignment: .trailing)
                        Spacer()
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(bucket.totalWords == 0 ? .tertiary : .primary)
                }
            }
        }
    }

    private func chartTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(.headline, design: .rounded))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var emptyHint: some View {
        Text("За выбранный период ничего не записано и не продиктовано.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(height: 100, alignment: .center)
    }
}
