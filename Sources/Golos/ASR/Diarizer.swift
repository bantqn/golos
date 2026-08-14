import Foundation
import Accelerate

/// Разделение реплик по голосам внутри одной дорожки.
///
/// Работает по звуку, а не по словам, и поэтому не зависит от языка — русский
/// разделяется так же, как английский. Для каждой реплики считается описание
/// голоса: усреднённый по кадрам лог-мел-спектр (тембр) и медианная частота
/// основного тона (высота). Затем реплики группируются агломеративно: пока
/// самая похожая пара ближе порога — объединяем.
///
/// Честно про пределы. Это не нейросетевая диаризация: она уверенно разделяет
/// заметно разные голоса — мужской и женский, высокий и низкий, — и путается
/// на похожих. Она не узнаёт людей между записями и не разделит двоих, если
/// они говорят одновременно. Для «кто из двух-трёх участников встречи это
/// сказал» её достаточно, для протокола суда — нет.
enum Diarizer {

    struct Options {
        var maxSpeakers: Int = 4
        /// Порог косинусного расстояния для объединения. Больше — меньше голосов.
        var threshold: Double = 0.22
        /// Реплики короче этого не участвуют в кластеризации: на трёх словах
        /// описание голоса получается случайным.
        var minSegmentSeconds: TimeInterval = 1.0
        /// Насколько должна различаться высота тона, чтобы счесть голоса разными.
        ///
        /// В логарифме. Значение подобрано замером, а не на глаз: у одного
        /// человека медианная высота гуляет между фразами примерно до 0.25
        /// (на 13% деление ещё было ложным), а между явно разными голосами
        /// разрыв был 0.55. 0.30 стоит между этими двумя числами.
        var minPitchSeparation: Double = 0.30
    }

    /// Раскладывает реплики по голосам.
    /// - Returns: те же реплики с проставленным `.voice(n)`, либо исходные,
    ///   если разделять было нечего.
    static func assignVoices(segments: [Segment], audioURL: URL,
                             options: Options = Options()) -> [Segment] {
        guard segments.count > 1 else { return segments }

        let embeddings: [Int: [Double]]
        do {
            embeddings = try features(for: segments, audioURL: audioURL, options: options)
        } catch {
            Log.warn("Разделение по голосам не удалось: \(error.localizedDescription)")
            return segments
        }

        let indices = embeddings.keys.sorted()
        guard indices.count > 1 else { return segments }

        // Медианная высота тона в логарифме — до нормировки: она понадобится
        // как физическая мера, а не как безразмерная координата.
        let logPitch = indices.map { embeddings[$0]![0] }

        var vectors = normalize(indices.map { embeddings[$0]! })
        if let width = vectors.first?.count {
            let scale = weights(for: width)
            for row in vectors.indices {
                for dimension in 0..<width { vectors[row][dimension] *= scale[dimension] }
            }
        }
        var clusters = cluster(vectors, maxClusters: options.maxSpeakers, threshold: options.threshold)

        // Проверка на здравый смысл: относительный скачок расстояний находится
        // всегда, даже когда говорит один человек, — на записи одного голоса
        // это давало три «участника». Поэтому склеиваем обратно те группы,
        // у которых высота тона практически совпадает: разные люди почти
        // никогда не совпадают по высоте настолько точно.
        clusters = mergeByPitch(clusters, logPitch: logPitch,
                                minSeparation: options.minPitchSeparation)

        // Нумеруем голоса по первому появлению: «голос 1» — тот, кто заговорил раньше.
        var clusterToVoice: [Int: Int] = [:]
        var result = segments
        for (position, segmentIndex) in indices.enumerated() {
            let cluster = clusters[position]
            if clusterToVoice[cluster] == nil {
                clusterToVoice[cluster] = clusterToVoice.count + 1
            }
            result[segmentIndex].speaker = .voice(clusterToVoice[cluster]!)
        }

        // Короткие реплики получают голос ближайшей по времени размеченной.
        let assigned = Set(indices)
        for index in result.indices where !assigned.contains(index) {
            result[index].speaker = nearestVoice(to: index, in: result, assigned: assigned) ?? .unknown
        }

        let voices = clusterToVoice.count
        Log.info("Разделение по голосам: найдено \(voices) на \(indices.count) репликах")
        return voices > 1 ? result : segments
    }

    private static func nearestVoice(to index: Int, in segments: [Segment],
                                     assigned: Set<Int>) -> Segment.Speaker? {
        var best: (distance: TimeInterval, speaker: Segment.Speaker)?
        for other in assigned {
            let distance = abs(segments[other].start - segments[index].start)
            if best == nil || distance < best!.distance {
                best = (distance, segments[other].speaker)
            }
        }
        return best?.speaker
    }

    // MARK: - Шкала говорящих

    /// Кто говорит в каждый момент записи.
    struct Turn: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var voice: Int

        var duration: TimeInterval { end - start }
    }

    /// Строит шкалу говорящих прямо по звуку, не опираясь на то, как модель
    /// распознавания нарезала реплики.
    ///
    /// Это принципиально: Parakeet отдаёт девятиминутную запись одной репликой,
    /// и делить по репликам там просто нечего. Здесь запись режется на короткие
    /// окна одинаковой длины, у каждого считается описание голоса, окна
    /// кластеризуются и склеиваются в непрерывные отрезки речи одного человека.
    ///
    /// - Parameter expectedSpeakers: если известно точно, сколько людей говорит,
    ///   число кластеров не угадывается, а берётся заданное — это заметно
    ///   надёжнее автоматического выбора.
    static func speakerTurns(audioURL: URL, expectedSpeakers: Int?,
                             options: Options = Options()) -> [Turn] {
        let windowSeconds: TimeInterval = 1.5
        let hopSeconds: TimeInterval = 0.75

        let duration: TimeInterval
        do {
            duration = try probeDuration(audioURL)
        } catch {
            Log.warn("Шкала говорящих: не удалось прочитать файл — \(error.localizedDescription)")
            return []
        }
        guard duration > windowSeconds * 2 else { return [] }

        var windows: [Window] = []
        var position: TimeInterval = 0
        while position + windowSeconds <= duration {
            windows.append(Window(start: position, end: position + windowSeconds))
            position += hopSeconds
        }
        guard windows.count > 2 else { return [] }

        let embeddings: [Int: [Double]]
        do {
            embeddings = try features(forWindows: windows, audioURL: audioURL)
        } catch {
            Log.warn("Шкала говорящих не построена: \(error.localizedDescription)")
            return []
        }

        let indices = embeddings.keys.sorted()
        guard indices.count > 2 else { return [] }

        let logPitch = indices.map { embeddings[$0]![0] }
        var vectors = normalize(indices.map { embeddings[$0]! })
        if let width = vectors.first?.count {
            let scale = weights(for: width)
            for row in vectors.indices {
                for dimension in 0..<width { vectors[row][dimension] *= scale[dimension] }
            }
        }

        var labels: [Int]
        if let expected = expectedSpeakers, expected >= 1 {
            guard expected > 1 else {
                // Один говорящий — вся запись один отрезок, считать нечего.
                return [Turn(start: 0, end: duration, voice: 1)]
            }
            labels = clusterExactly(vectors, count: expected)
        } else {
            labels = cluster(vectors, maxClusters: options.maxSpeakers, threshold: options.threshold)
            // Склейка по высоте тона — единственный проверенный признак. Пробовал
            // отличать настоящий диалог от ложного деления по устройству меток во
            // времени (в диалоге, казалось бы, должны быть длинные чередующиеся
            // блоки) — не работает: у одного человека блоки такие же длинные,
            // 6,8 и 7,4 окна против 10,0 у настоящего диалога. Когда голоса
            // похожи по тону, их число надёжнее указать руками.
            labels = mergeByPitch(labels, logPitch: logPitch,
                                  minSeparation: options.minPitchSeparation)
        }

        // Сглаживание: без него метка дёргается от окна к окну на согласных
        // и стыках, и вместо реплик получается частокол.
        labels = smooth(labels, radius: 2)

        // Нумеруем по первому появлению.
        var voiceByCluster: [Int: Int] = [:]
        var turns: [Turn] = []
        for (position, windowIndex) in indices.enumerated() {
            let cluster = labels[position]
            if voiceByCluster[cluster] == nil { voiceByCluster[cluster] = voiceByCluster.count + 1 }
            let voice = voiceByCluster[cluster]!
            let window = windows[windowIndex]

            if var last = turns.last, last.voice == voice, window.start - last.end <= hopSeconds * 2 {
                last.end = window.end
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(start: window.start, end: window.end, voice: voice))
            }
        }

        turns = mergeShortTurns(turns, minimum: 1.2)
        turns = sealBoundaries(turns, total: duration)
        turns = refineBoundaries(turns, audioURL: audioURL)
        guard Set(turns.map(\.voice)).count > 1 else { return [] }

        Log.info("Шкала говорящих: \(Set(turns.map(\.voice)).count) голосов, \(turns.count) отрезков")
        return turns
    }

    /// Убирает щели и наложения между отрезками.
    ///
    /// Окна идут с перекрытием, поэтому конец одного отрезка оказывается позже
    /// начала следующего — и реплика на стыке попадала бы сразу в оба. Границу
    /// ставим посередине спорного места, а края растягиваем до концов записи,
    /// чтобы ни одна реплика не осталась без говорящего.
    private static func sealBoundaries(_ turns: [Turn], total: TimeInterval) -> [Turn] {
        guard !turns.isEmpty else { return turns }
        var result = turns
        for index in 0..<(result.count - 1) {
            let middle = (result[index].end + result[index + 1].start) / 2
            result[index].end = middle
            result[index + 1].start = middle
        }
        result[0].start = 0
        result[result.count - 1].end = max(total, result[result.count - 1].end)
        return result
    }

    /// Подтягивает границы отрезков к тишине.
    ///
    /// Кластеризация работает окнами по полторы секунды, поэтому границу она
    /// определяет с точностью до окна и обычно ставит её раньше времени — так
    /// последнее слово одного говорящего уезжает в реплику другого. Люди же
    /// сменяются в паузе, поэтому границу двигаем в самое тихое место рядом.
    private static func refineBoundaries(_ turns: [Turn], audioURL: URL,
                                         search: TimeInterval = 0.7) -> [Turn] {
        guard turns.count > 1 else { return turns }
        let frame = Int(AudioFormat.sampleRate * 0.06)
        var result = turns

        for index in 0..<(result.count - 1) {
            let boundary = result[index].end
            // Сдвиг ограничен длиной более короткого из соседей: иначе короткую
            // реплику можно подрезать с двух сторон и вовсе её потерять.
            let room = min(search,
                           min(result[index].duration, result[index + 1].duration) * 0.3)
            let from = max(result[index].start + 0.2, boundary - room)
            let to = min(result[index + 1].end - 0.2, boundary + room)
            guard to - from > 0.25,
                  let samples = try? AudioLoader.samples(
                    from: audioURL, start: from, duration: to - from),
                  samples.count > frame
            else { continue }

            var quietestStart = 0
            var quietestEnergy = Float.greatestFiniteMagnitude
            var position = 0
            while position + frame <= samples.count {
                var energy: Float = 0
                for offset in position..<(position + frame) {
                    energy += samples[offset] * samples[offset]
                }
                if energy < quietestEnergy {
                    quietestEnergy = energy
                    quietestStart = position
                }
                position += frame / 2
            }

            let refined = from + Double(quietestStart + frame / 2) / AudioFormat.sampleRate
            result[index].end = refined
            result[index + 1].start = refined
        }
        return result
    }

    /// Медианный фильтр по последовательности меток.
    private static func smooth(_ labels: [Int], radius: Int) -> [Int] {
        guard labels.count > radius * 2 + 1 else { return labels }
        var result = labels
        for index in labels.indices {
            let lower = max(0, index - radius)
            let upper = min(labels.count - 1, index + radius)
            var counts: [Int: Int] = [:]
            for position in lower...upper { counts[labels[position], default: 0] += 1 }
            if let winner = counts.max(by: { $0.value < $1.value })?.key { result[index] = winner }
        }
        return result
    }

    /// Слишком короткие отрезки прилепляем к соседям: полсекунды речи — это
    /// обычно не реплика, а огрех кластеризации на стыке.
    private static func mergeShortTurns(_ turns: [Turn], minimum: TimeInterval) -> [Turn] {
        guard turns.count > 1 else { return turns }
        var result: [Turn] = []
        for turn in turns {
            if turn.duration < minimum, var last = result.last {
                last.end = turn.end
                result[result.count - 1] = last
            } else {
                result.append(turn)
            }
        }
        return result
    }

    /// Кластеризация до заданного числа групп, без угадывания.
    private static func clusterExactly(_ vectors: [[Double]], count: Int) -> [Int] {
        var groups: [Int: [Int]] = [:]
        for index in vectors.indices { groups[index] = [index] }

        while groups.count > max(1, count) {
            var bestPair: (Int, Int)?
            var bestDistance = Double.greatestFiniteMagnitude
            let keys = groups.keys.sorted()
            for left in 0..<keys.count {
                for right in (left + 1)..<keys.count {
                    let distance = averageDistance(groups[keys[left]]!, groups[keys[right]]!, vectors)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestPair = (keys[left], keys[right])
                    }
                }
            }
            guard let pair = bestPair else { break }
            groups[pair.0]!.append(contentsOf: groups[pair.1]!)
            groups[pair.1] = nil
        }

        var assignment = Array(vectors.indices)
        for (cluster, members) in groups {
            for member in members { assignment[member] = cluster }
        }
        return assignment
    }

    private static func probeDuration(_ url: URL) throws -> TimeInterval {
        let reader = try AudioWindowReader(url: url, windowSeconds: 3600, overlapSeconds: 0)
        defer { reader.cancel() }
        return reader.duration
    }

    /// Описания голоса для произвольных отрезков времени.
    private static func features(forWindows windows: [Window],
                                 audioURL: URL) throws -> [Int: [Double]] {
        let asSegments = windows.map { Segment(start: $0.start, end: $0.end, text: "") }
        var options = Options()
        options.minSegmentSeconds = 0
        return try features(for: asSegments, audioURL: audioURL, options: options)
    }

    // MARK: - Признаки

    private static let melBands = 24
    private static let frameSize = 512          // 32 мс при 16 кГц
    private static let hopSize = 256

    /// Отрезок времени, для которого считается описание голоса.
    struct Window {
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Один проход по файлу: кадры раскладываются по репликам, в которые попали.
    private static func features(for segments: [Segment], audioURL: URL,
                                options: Options) throws -> [Int: [Double]] {
        // Реплики, достаточно длинные, чтобы описание голоса было осмысленным.
        let candidates = segments.indices.filter {
            segments[$0].end - segments[$0].start >= options.minSegmentSeconds
        }
        guard candidates.count > 1 else { return [:] }

        var melSums = [Int: [Double]](minimumCapacity: candidates.count)
        var melSquares = [Int: [Double]](minimumCapacity: candidates.count)
        var pitches = [Int: [Double]](minimumCapacity: candidates.count)
        var counts = [Int: Int](minimumCapacity: candidates.count)
        for index in candidates {
            melSums[index] = [Double](repeating: 0, count: melBands)
            melSquares[index] = [Double](repeating: 0, count: melBands)
            pitches[index] = []
        }

        let filterbank = melFilterbank()
        let window = hannWindow()
        let fft = FFT(size: frameSize)

        // Читаем окнами, чтобы длинная запись не оказалась в памяти целиком.
        let reader = try AudioWindowReader(url: audioURL, windowSeconds: 120, overlapSeconds: 0)
        defer { reader.cancel() }

        var cursor = 0
        while let chunk = try reader.next() {
            let samples = chunk.samples
            var frameStart = 0
            while frameStart + frameSize <= samples.count {
                let time = chunk.offset + Double(frameStart) / AudioFormat.sampleRate

                // Реплики упорядочены, поэтому идём по ним курсором, а не поиском.
                while cursor < candidates.count, segments[candidates[cursor]].end < time {
                    cursor += 1
                }
                guard cursor < candidates.count else { break }
                let index = candidates[cursor]

                if time >= segments[index].start {
                    let frame = Array(samples[frameStart..<(frameStart + frameSize)])
                    if energy(frame) > 1e-4 {
                        let mel = logMel(frame, window: window, filterbank: filterbank, fft: fft)
                        for band in 0..<melBands {
                            melSums[index]![band] += mel[band]
                            melSquares[index]![band] += mel[band] * mel[band]
                        }
                        if let f0 = pitch(frame) { pitches[index]!.append(f0) }
                        counts[index, default: 0] += 1
                    }
                }
                frameStart += hopSize
            }
        }

        var result: [Int: [Double]] = [:]
        for index in candidates {
            let count = counts[index] ?? 0
            // Меньше десяти кадров — это меньше трети секунды звука.
            guard count >= 10 else { continue }
            let voiced = pitches[index]!.sorted()
            // Без надёжной высоты тона описание голоса получается ни о чём.
            guard voiced.count >= 5 else { continue }

            var vector: [Double] = []

            // Высота тона — основной признак говорящего. В логарифме, потому что
            // слух и физиология работают в отношениях, а не в разнице герц.
            vector.append(log(voiced[voiced.count / 2]))
            vector.append(log(voiced[voiced.count / 4]))
            vector.append(log(voiced[voiced.count * 3 / 4]))

            // Форма спектра, из которой убрано общее смещение: иначе признак
            // описывает произносимые слова и громкость, а не голос. Именно на
            // этом первая версия делила одного человека на несколько «голосов».
            var shape: [Double] = []
            for group in 0..<8 {
                var sum = 0.0
                for band in (group * 3)..<(group * 3 + 3) {
                    sum += melSums[index]![band] / Double(count)
                }
                shape.append(sum / 3)
            }
            let shapeMean = shape.reduce(0, +) / Double(shape.count)
            vector.append(contentsOf: shape.map { $0 - shapeMean })

            result[index] = vector
        }
        return result
    }

    /// Веса измерений: первые три — высота тона, и они должны решать.
    /// Без этого сорок мел-полос заглушали единственный по-настоящему
    /// говорящий о человеке признак.
    private static func weights(for width: Int) -> [Double] {
        (0..<width).map { $0 < 3 ? 3.0 : 1.0 }
    }

    private static func energy(_ frame: [Float]) -> Float {
        var sum: Float = 0
        vDSP_measqv(frame, 1, &sum, vDSP_Length(frame.count))
        return sum
    }

    /// Частота основного тона по автокорреляции. Диапазон 70–350 Гц покрывает
    /// и низкий мужской голос, и высокий женский.
    private static func pitch(_ frame: [Float]) -> Double? {
        let rate = AudioFormat.sampleRate
        let minLag = Int(rate / 350)
        let maxLag = min(Int(rate / 70), frame.count - 1)
        guard maxLag > minLag else { return nil }

        var bestLag = 0
        var bestValue: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            frame.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_dotpr(base, 1, base + lag, 1, &sum, vDSP_Length(frame.count - lag))
            }
            if sum > bestValue {
                bestValue = sum
                bestLag = lag
            }
        }
        guard bestLag > 0, bestValue > 0 else { return nil }
        return rate / Double(bestLag)
    }

    private static func logMel(_ frame: [Float], window: [Float],
                               filterbank: [[Float]], fft: FFT) -> [Double] {
        var windowed = [Float](repeating: 0, count: frameSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))

        let spectrum = fft.magnitudes(windowed)
        var result = [Double](repeating: 0, count: melBands)
        for band in 0..<melBands {
            var sum: Float = 0
            vDSP_dotpr(spectrum, 1, filterbank[band], 1, &sum, vDSP_Length(spectrum.count))
            result[band] = log(Double(sum) + 1e-10)
        }
        return result
    }

    private static func hannWindow() -> [Float] {
        var window = [Float](repeating: 0, count: frameSize)
        for index in 0..<frameSize {
            window[index] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frameSize - 1)))
        }
        return window
    }

    /// Треугольные фильтры, равномерные по шкале мел.
    private static func melFilterbank() -> [[Float]] {
        let bins = frameSize / 2
        let rate = AudioFormat.sampleRate
        func toMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func toHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        let lowMel = toMel(80)
        let highMel = toMel(rate / 2)
        let points = (0...(melBands + 1)).map { index -> Double in
            toHz(lowMel + (highMel - lowMel) * Double(index) / Double(melBands + 1))
        }
        let binFor = { (hz: Double) -> Double in hz * Double(bins) / (rate / 2) }

        return (0..<melBands).map { band in
            let left = binFor(points[band])
            let center = binFor(points[band + 1])
            let right = binFor(points[band + 2])
            return (0..<bins).map { bin in
                let position = Double(bin)
                if position <= left || position >= right { return 0 }
                if position <= center {
                    return Float((position - left) / max(1e-6, center - left))
                }
                return Float((right - position) / max(1e-6, right - center))
            }
        }
    }

    // MARK: - Кластеризация

    /// Приводим каждое измерение к нулевому среднему и единичному разбросу:
    /// без этого мел-полосы с большой энергией задавили бы остальные признаки,
    /// а частота тона в герцах — вообще всё.
    private static func normalize(_ vectors: [[Double]]) -> [[Double]] {
        guard let width = vectors.first?.count, width > 0 else { return vectors }
        var result = vectors
        for dimension in 0..<width {
            let column = vectors.map { $0[dimension] }
            let mean = column.reduce(0, +) / Double(column.count)
            let variance = column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(column.count)
            let deviation = max(1e-6, variance.squareRoot())
            for row in result.indices {
                result[row][dimension] = (result[row][dimension] - mean) / deviation
            }
        }
        return result
    }

    /// Агломеративная кластеризация со самостоятельным выбором числа голосов.
    ///
    /// Абсолютный порог расстояния тут не годится: после нормировки признаков
    /// расстояния зависят от записи, и одно и то же число означает разное на
    /// разных дорожках — проверено замером, подобранное значение переставало
    /// работать на другом файле. Поэтому сливаем всё до одной группы, запоминая
    /// расстояние каждого слияния, а потом режем там, где расстояние резче
    /// всего подскочило: этот скачок и есть граница между «тот же голос»
    /// и «уже другой».
    private static func cluster(_ vectors: [[Double]], maxClusters: Int, threshold: Double) -> [Int] {
        let count = vectors.count
        guard count > 1 else { return [0] }

        var groups: [Int: [Int]] = [:]
        for index in vectors.indices { groups[index] = [index] }

        // История слияний: кто с кем и на каком расстоянии.
        var history: [(into: Int, from: Int, distance: Double)] = []

        while groups.count > 1 {
            var bestPair: (Int, Int)?
            var bestDistance = Double.greatestFiniteMagnitude

            let keys = groups.keys.sorted()
            for left in 0..<keys.count {
                for right in (left + 1)..<keys.count {
                    let distance = averageDistance(groups[keys[left]]!, groups[keys[right]]!, vectors)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestPair = (keys[left], keys[right])
                    }
                }
            }
            guard let pair = bestPair else { break }
            groups[pair.0]!.append(contentsOf: groups[pair.1]!)
            groups[pair.1] = nil
            history.append((into: pair.0, from: pair.1, distance: bestDistance))
        }

        let chosen = chooseClusterCount(history: history, total: count,
                                        maxClusters: maxClusters, minJump: threshold)

        // Повторяем слияния, пока групп не станет ровно столько.
        var replay: [Int: [Int]] = [:]
        for index in vectors.indices { replay[index] = [index] }
        for merge in history {
            if replay.count <= chosen { break }
            guard let moved = replay[merge.from] else { continue }
            replay[merge.into]?.append(contentsOf: moved)
            replay[merge.from] = nil
        }

        var assignment = Array(vectors.indices)
        for (cluster, members) in replay {
            for member in members { assignment[member] = cluster }
        }
        return assignment
    }

    /// Где резать дерево слияний.
    ///
    /// Смотрим на расстояние того слияния, которое свело бы число групп с k до
    /// k−1. Если оно заметно больше предыдущего, значит на этом шаге склеили два
    /// разных голоса — останавливаемся на k.
    private static func chooseClusterCount(history: [(into: Int, from: Int, distance: Double)],
                                           total: Int, maxClusters: Int, minJump: Double) -> Int {
        let limit = min(maxClusters, total)
        guard limit > 1, history.count >= 2 else { return 1 }

        // history[i] — слияние, после которого групп стало total − i − 1.
        // Значит переход k → k−1 сделан слиянием с индексом total − k.
        func distance(forCutAt k: Int) -> Double? {
            let index = total - k
            guard index >= 0, index < history.count else { return nil }
            return history[index].distance
        }

        var bestCount = 1
        var bestRatio = 1.0
        for k in 2...limit {
            guard let merging = distance(forCutAt: k),
                  let previous = distance(forCutAt: k + 1), previous > 1e-9
            else { continue }
            let ratio = merging / previous
            if ratio > bestRatio {
                bestRatio = ratio
                bestCount = k
            }
        }
        // Скачок должен быть ощутимым, иначе перед нами один голос.
        return bestRatio >= max(1.15, 1 + minJump) ? bestCount : 1
    }

    /// Сливает группы, у которых средняя высота тона ближе порога.
    private static func mergeByPitch(_ clusters: [Int], logPitch: [Double],
                                     minSeparation: Double) -> [Int] {
        var result = clusters
        while true {
            var members: [Int: [Int]] = [:]
            for (position, cluster) in result.enumerated() { members[cluster, default: []].append(position) }
            guard members.count > 1 else { return result }

            func center(_ cluster: Int) -> Double {
                let list = members[cluster]!
                return list.reduce(0) { $0 + logPitch[$1] } / Double(list.count)
            }

            let keys = members.keys.sorted()
            var closest: (Int, Int, Double)?
            for left in 0..<keys.count {
                for right in (left + 1)..<keys.count {
                    let gap = abs(center(keys[left]) - center(keys[right]))
                    if closest == nil || gap < closest!.2 {
                        closest = (keys[left], keys[right], gap)
                    }
                }
            }
            guard let pair = closest, pair.2 < minSeparation else { return result }

            for position in members[pair.1]! { result[position] = pair.0 }
        }
    }

    private static func averageDistance(_ left: [Int], _ right: [Int], _ vectors: [[Double]]) -> Double {
        var total = 0.0
        for a in left {
            for b in right { total += cosineDistance(vectors[a], vectors[b]) }
        }
        return total / Double(left.count * right.count)
    }

    private static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 1 }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }
}

/// Обёртка над vDSP: величины спектра действительного сигнала.
private final class FFT {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(_ input: [Float]) -> [Float] {
        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imagBuffer.baseAddress!)
                input.withUnsafeBufferPointer { inputBuffer in
                    inputBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return magnitudes
    }
}
