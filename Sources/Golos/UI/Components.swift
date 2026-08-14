import SwiftUI
import Charts

/// Живая дорожка уровня: столбики, которые пружинят под звук.
struct LiveWaveform: View {
    let levels: [Float]
    let accent: Settings.AccentTheme
    var active: Bool = true
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            // Столбиков берём столько, сколько влезает: иначе HStack выходит
            // за рамку и рисует поверх соседей — таймер в плашке диктовки
            // именно так и оказывался перечёркнут волной.
            let capacity = max(1, Int((geo.size.width + spacing) / (barWidth + spacing)))
            let visible = Array(levels.suffix(capacity))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(fill(for: index, count: visible.count))
                        .frame(
                            width: barWidth,
                            height: max(minHeight, CGFloat(level) * geo.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: levels)
        }
        .clipped()
    }

    private func fill(for index: Int, count: Int) -> LinearGradient {
        let colors = Theme.accentColors(accent)
        let fade = active ? 1.0 : 0.35
        // Свежие значения справа — они ярче, старые слева слегка гаснут.
        let position = Double(index) / Double(max(1, count - 1))
        let opacity = (0.45 + position * 0.55) * fade
        return LinearGradient(
            colors: [colors[0].opacity(opacity), colors[1].opacity(opacity)],
            startPoint: .bottom, endPoint: .top
        )
    }
}

/// Кольцевой индикатор для процентов.
struct GaugeRing: View {
    let value: Double        // 0…100
    let caption: String
    let detail: String
    let accent: Settings.AccentTheme
    var tint: Color?
    var size: CGFloat = 108

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 10)

            Circle()
                .trim(from: 0, to: max(0.002, min(1, value / 100)))
                .stroke(
                    AngularGradient(
                        colors: tint.map { [$0.opacity(0.7), $0] } ?? Theme.accentColors(accent),
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: value)

            VStack(spacing: 1) {
                Text(Fmt.percent(value))
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .offset(y: 16)
        }
    }
}

/// Компактный график истории значения.
struct Sparkline: View {
    let values: [Double]
    let accent: Settings.AccentTheme
    var maximum: Double = 100

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("t", index), y: .value("v", value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.primary(accent).opacity(0.45), Theme.primary(accent).opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            LineMark(x: .value("t", index), y: .value("v", value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(Theme.primary(accent))
        }
        .chartYScale(domain: 0...maximum)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .animation(.easeOut(duration: 0.35), value: values.count)
    }
}

/// Плитка со значением и подписью.
struct StatTile: View {
    let symbol: String
    let title: String
    let value: String
    var detail: String?
    var tint: Color = .secondary

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Пульсирующий круг — «слушаю».
struct BreathingOrb: View {
    let accent: Settings.AccentTheme
    var level: Float = 0
    var size: CGFloat = 66
    var animated: Bool = true

    @State private var pulse = false

    var body: some View {
        ZStack {
            // Внешние волны расходятся тем сильнее, чем громче голос.
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Theme.primary(accent).opacity(0.35 - Double(index) * 0.1), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.35 + CGFloat(index) * 0.22 + CGFloat(level) * 0.3 : 0.9)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(
                        animated
                            ? .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(index) * 0.45)
                            : .default,
                        value: pulse
                    )
            }

            Circle()
                .fill(Theme.gradient(accent))
                .frame(width: size, height: size)
                .scaleEffect(1 + CGFloat(level) * 0.22)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: level)
                .shadow(color: Theme.primary(accent).opacity(0.5), radius: 18)

            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { if animated { pulse = true } }
    }
}

/// Бегущий блик поверх содержимого — состояние «идёт распознавание».
struct ShimmerModifier: ViewModifier {
    var active: Bool = true
    @State private var offset: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: offset * geo.size.width * 1.5)
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                    .mask(content)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    offset = 1
                }
            }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

/// Три точки, которые по очереди подпрыгивают, — «думаю».
struct ThinkingDots: View {
    let accent: Settings.AccentTheme
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.gradient(accent))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == index ? 1.35 : 0.8)
                    .opacity(phase == index ? 1 : 0.45)
            }
        }
        // Через .task, а не Timer в .onAppear: задача сама отменяется при
        // исчезновении view. Таймер приходилось бы гасить руками, а каждое
        // повторное появление плодило бы ещё один — и они копились без предела.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

/// Полоса прогресса с градиентом и подписью.
struct GradientProgress: View {
    let value: Double     // 0…1
    let accent: Settings.AccentTheme
    var height: CGFloat = 8
    var indeterminate: Bool = false

    @State private var slide: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))

                if indeterminate {
                    Capsule()
                        .fill(Theme.gradient(accent))
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: slide * geo.size.width)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                                slide = 1.05
                            }
                        }
                } else {
                    Capsule()
                        .fill(Theme.gradient(accent))
                        .frame(width: max(height, geo.size.width * CGFloat(max(0, min(1, value)))))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// Оценка «звёздочками» для скорости и качества модели.
struct RatingBars: View {
    let value: Int          // 1…5
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Capsule()
                    .fill(index <= value ? tint : Color.primary.opacity(0.12))
                    .frame(width: 10, height: 4)
            }
        }
    }
}

/// Кнопка записи: круг, который превращается в квадрат и пульсирует.
struct RecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let accent: Settings.AccentTheme
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 3)
                    .frame(width: 74, height: 74)

                if isRecording {
                    Circle()
                        .stroke(Theme.danger.opacity(0.45), lineWidth: 3)
                        .frame(width: 74, height: 74)
                        .scaleEffect(pulse ? 1.22 : 1)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
                }

                RoundedRectangle(cornerRadius: isRecording ? 8 : 30, style: .continuous)
                    .fill(isRecording ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.gradient(accent)))
                    .frame(width: isRecording ? 28 : 60, height: isRecording ? 28 : 60)
                    .animation(.spring(response: 0.34, dampingFraction: 0.68), value: isRecording)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .colorInvert()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onAppear { pulse = true }
        .help(isRecording ? "Остановить запись" : "Начать запись")
    }
}
