import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 268)
        } detail: {
            ZStack {
                AuroraBackground(accent: settings.accent,
                                 animated: settings.animatedBackground && !settings.reduceMotion)
                    .ignoresSafeArea()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) { bannerView }
        }
        .sheet(isPresented: $env.showOnboarding) {
            OnboardingView()
                .environmentObject(env)
                .environmentObject(settings)
                .environmentObject(models)
        }
    }

    // MARK: - Боковая панель

    private var sidebar: some View {
        VStack(spacing: 0) {
            header

            List(selection: Binding(
                get: { env.route },
                set: { if let value = $0 { env.route = value } }
            )) {
                ForEach(Route.allCases) { route in
                    Label {
                        HStack {
                            Text(route.title)
                            Spacer()
                            badge(for: route)
                        }
                    } icon: {
                        Image(systemName: route.symbol)
                            .foregroundStyle(env.route == route
                                             ? AnyShapeStyle(Theme.gradient(settings.accent))
                                             : AnyShapeStyle(Color.secondary))
                    }
                    .tag(route)
                }
            }
            .listStyle(.sidebar)

            Divider().opacity(0.4)
            statusFooter
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.gradient(settings.accent))
                    .frame(width: 30, height: 30)
                GolosMark()
                    .frame(width: 21, height: 14)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("голос")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text("локальное распознавание")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func badge(for route: Route) -> some View {
        switch route {
        case .record:
            if recorder.isBusy {
                Circle().fill(Theme.danger).frame(width: 7, height: 7)
            }
        case .library:
            if transcription.queueCount > 0 {
                Text("\(transcription.queueCount)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.primary(settings.accent).opacity(0.2)))
            }
        case .models:
            let downloading = models.states.values.filter(\.isDownloading).count
            if downloading > 0 {
                ProgressView().controlSize(.mini)
            }
        case .dictation:
            if dictation.phase.isActive {
                Circle().fill(Theme.success).frame(width: 7, height: 7)
            }
        default:
            EmptyView()
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(engineColor)
                    .frame(width: 7, height: 7)
                Text(engineText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(Fmt.percent(monitor.snapshot.cpuTotal))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if monitor.snapshot.gpu >= 0 {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(Fmt.percent(monitor.snapshot.gpu))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var engineColor: Color {
        switch env.warmup {
        case .ready: return Theme.success
        case .running: return Theme.warning
        case .unavailable: return Theme.danger
        case .idle: return .secondary
        }
    }

    private var engineText: String {
        switch env.warmup {
        case .ready: return settings.useGPU ? "Движок готов · GPU" : "Движок готов · CPU"
        case .running: return "Прогрев GPU-ядер…"
        case .unavailable: return "Движок не прогрет"
        case .idle: return models.hasAnyModel ? "Движок в покое" : "Нет моделей"
        }
    }

    // MARK: - Основная область

    @ViewBuilder
    private var detail: some View {
        switch env.route {
        case .record: RecordView()
        case .library: LibraryView()
        case .dictation: DictationView()
        case .archive: ArchiveView()
        case .stats: StatsView()
        case .models: ModelsView()
        case .system: SystemView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = env.banner {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: banner.kind))
                    .foregroundStyle(color(for: banner.kind))
                Text(banner.text)
                    .font(.callout)
                Spacer(minLength: 12)
                Button {
                    withAnimation { env.banner = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(color(for: banner.kind).opacity(0.35), lineWidth: 1))
            .shadow(radius: 12, y: 4)
            .padding(.top, 14)
            .frame(maxWidth: 560)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                withAnimation { if env.banner?.id == banner.id { env.banner = nil } }
            }
        }
    }

    private func symbol(for kind: AppEnvironment.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private func color(for kind: AppEnvironment.Banner.Kind) -> Color {
        switch kind {
        case .info: return Theme.primary(settings.accent)
        case .warning: return Theme.warning
        case .error: return Theme.danger
        case .success: return Theme.success
        }
    }
}
