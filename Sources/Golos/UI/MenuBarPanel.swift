import SwiftUI
import AppKit

/// Компактная панель в строке меню: запись и диктовка без открытия окна.
struct MenuBarPanel: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var calls: CallDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            recordSection

            Divider()

            dictationSection

            if transcription.isRunning, let job = transcription.current {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(Fmt.percent(job.progress * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GradientProgress(value: job.progress, accent: settings.accent, height: 5)
                }
            }

            Divider()

            HStack {
                Button("Открыть «голос»") { env.show(.record) }
                    .buttonStyle(.plain)
                    .font(.callout)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 288)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.gradient(settings.accent))
                    .frame(width: 24, height: 24)
                GolosMark().frame(width: 17, height: 11)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("голос").font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(statusLine).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusLine: String {
        if recorder.isBusy { return "идёт запись · \(Fmt.duration(recorder.elapsed))" }
        if dictation.phase.isActive { return "диктовка активна" }
        if transcription.isRunning { return "распознаю…" }
        return "готов"
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button {
                    env.toggleRecording()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: recorder.isBusy ? "stop.fill" : "record.circle")
                            .foregroundStyle(recorder.isBusy ? Theme.danger : Theme.primary(settings.accent))
                        Text(recorder.isBusy ? "Остановить запись" : "Начать запись")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if recorder.isBusy {
                    Text(Fmt.duration(recorder.elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if recorder.isBusy {
                LiveWaveform(levels: recorder.waveform.suffix(48).map { $0 },
                             accent: settings.accent, barWidth: 2, spacing: 2)
                    .frame(height: 26)
            }

            if let detection = calls.current, !recorder.isBusy {
                Button {
                    env.startRecordingCall(detection)
                } label: {
                    Label("Записать разговор в \(detection.appName)", systemImage: "person.2.wave.2")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary(settings.accent))
            }
        }
    }

    private var dictationSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Диктовка")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                Text(settings.dictationEnabled
                     ? settings.dictationHotKey.displayString
                     : "выключена")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.dictationEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
