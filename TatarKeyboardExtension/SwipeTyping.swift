//
//  SwipeTyping.swift
//  TatarKeyboardExtension
//
//  Свайп-ввод (как QuickPath / Gboard): палец ведётся по буквам, не отрываясь,
//  и по ФОРМЕ траектории подбирается слово из TatarLanguageModel.
//
//  Алгоритм (упрощённый SHARK²):
//  1. Для каждого слова строится «идеальная» траектория — ломаная через
//     центры его клавиш. Буквы на долгом нажатии (ә на «а», ң на «н», ө на «о»,
//     ü на «u»...) считаются той же клавишей, поэтому «белән» набирается
//     свайпом через «а». Повторы подряд схлопываются («алла» → а-л-а).
//  2. Отбор кандидатов: первая клавиша слова — рядом с началом свайпа,
//     последняя — рядом с концом, длина идеальной траектории сопоставима.
//  3. Обе траектории равномерно перевыбираются в 32 точки, считается среднее
//     расстояние между соответствующими точками (в ширинах клавиши), и к
//     нему добавляется частота слова: чем ближе форма и чаще слово, тем выше.
//     Слова, которые обычно идут после предыдущего слова, получают бонус.
//
//  Веса подобраны на смоделированных свайпах (частые слова, дрожание пальца
//  до 0.35 клавиши, срезанные углы): ~84% — нужное слово сразу, ~96% — среди
//  трёх вариантов, ~1 мс на свайп. На реальных пальцах цифры будут другими.
//
//  Для арабицы (RTL со сложным формированием глифов) свайп отключён —
//  раскладка там зеркальная, а словаря для арабицы пока нет.
//

import Foundation
import CoreGraphics
import Combine

// MARK: - Состояние текущего касания

/// Общее для всех клавиш состояние жеста. `isActive` публикуется — клавиши
/// прячут пузырь, пока идёт свайп. Точки НЕ публикуются (их сотни за жест) —
/// для отрисовки следа есть отдельный SwipeTrail.
final class SwipeState: ObservableObject {
    /// true — палец перешёл с одной буквы на другую, это свайп, а не тап.
    /// Остаётся true после отпускания, пока не начнётся следующее касание:
    /// так клавиша, на которой начался свайп, при своём onEnded гарантированно
    /// узнает, что вставлять свою букву не надо (порядок onEnded у клавиши и
    /// у общего жеста SwiftUI не гарантирует).
    @Published private(set) var isActive = false
    /// Открыта лента вариантов на клавише — горизонтальный сдвиг пальца
    /// выбирает вариант, а не рисует свайп.
    var isSuppressed = false

    private(set) var points: [CGPoint] = []
    private var lastKey: Int?
    private var visitedKeys = 0
    private var isTracking = false

    /// Начало нового касания клавиши (вызывается клавишей при нажатии).
    func beginTouch() {
        guard !isTracking else { return }
        reset()
    }

    /// Очередная точка общего жеста. `key` — номер буквенной клавиши под пальцем.
    func track(point: CGPoint, start: CGPoint, key: Int?) {
        if !isTracking {
            reset()
            isTracking = true
            points.append(start)
        }
        guard !isSuppressed else { return }
        points.append(point)
        if let key, key != lastKey {
            lastKey = key
            visitedKeys += 1
            if visitedKeys >= 2 && !isActive { isActive = true }
        }
    }

    /// Конец общего жеста. true — это был свайп, слово надо подобрать.
    func endTracking() -> Bool {
        isTracking = false
        return isActive && !isSuppressed
    }

    private func reset() {
        if isActive { isActive = false }
        isSuppressed = false
        points = []
        lastKey = nil
        visitedKeys = 0
    }
}

/// След пальца во время свайпа — отдельный объект, чтобы частые обновления
/// перерисовывали только сам след, а не все клавиши.
final class SwipeTrail: ObservableObject {
    @Published var points: [CGPoint] = []
}

// MARK: - Геометрия буквенной панели

/// Центры клавиш в координатах панели букв. Повторяет компоновку
/// KeyboardRootView.lettersPad: ряды одинаковой высоты через 8pt, в ряду —
/// клавиши одинаковой ширины через 5pt; в последнем ряду слева Shift (если
/// есть), справа Backspace — они место занимают, но букв не дают.
struct SwipeKeyboardGeometry {
    struct Key {
        let center: CGPoint
        let rowIndex: Int
    }

    let keys: [Key]
    let keyWidth: CGFloat
    let rowHeight: CGFloat
    /// Буква (нижний регистр, включая варианты долгого нажатия) → номер клавиши.
    let keyIndexByLetter: [Character: Int]
    /// Для кэша кандидатов: меняется вместе с раскладкой.
    let signature: String

    init(rows: [[KeyDefinition]], script: TatarScript, size: CGSize,
         horizontalSpacing: CGFloat = 5, verticalSpacing: CGFloat = 8) {
        var keys: [Key] = []
        var map: [Character: Int] = [:]
        var signature = script.rawValue
        let rowCount = max(rows.count, 1)
        let rowHeight = (size.height - verticalSpacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)
        var firstRowKeyWidth: CGFloat = 0

        for (rowIndex, row) in rows.enumerated() {
            let isLast = rowIndex == rows.count - 1
            let leading = (isLast && script.supportsShift) ? 1 : 0
            let slotCount = row.count + leading + (isLast ? 1 : 0)
            let width = (size.width - horizontalSpacing * CGFloat(slotCount - 1)) / CGFloat(slotCount)
            if rowIndex == 0 { firstRowKeyWidth = width }
            let y = CGFloat(rowIndex) * (rowHeight + verticalSpacing) + rowHeight / 2

            for (column, key) in row.enumerated() {
                let slot = column + leading
                let x = CGFloat(slot) * (width + horizontalSpacing) + width / 2
                let index = keys.count
                keys.append(Key(center: CGPoint(x: x, y: y), rowIndex: rowIndex))
                for text in [key.main] + key.alts {
                    for ch in text.lowercased(with: script.caseLocale) where map[ch] == nil {
                        map[ch] = index
                    }
                }
                signature += key.main.lowercased(with: script.caseLocale)
            }
        }
        self.keys = keys
        self.keyWidth = max(firstRowKeyWidth, 1)
        self.rowHeight = max(rowHeight, 1)
        self.keyIndexByLetter = map
        self.signature = signature
    }

    /// Буквенная клавиша под точкой: ближайшая по горизонтали в ряду под
    /// пальцем; nil — палец над Shift/Backspace или вне панели.
    func letterKey(at point: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, key) in keys.enumerated() {
            let dx = abs(point.x - key.center.x)
            let dy = abs(point.y - key.center.y)
            guard dy <= rowHeight / 2 + 4, dx <= keyWidth / 2 + 3 else { continue }
            if best == nil || dx < best!.distance { best = (index, dx) }
        }
        return best?.index
    }

    /// Клавиши, центр которых ближе `radius` (в ширинах клавиши) к точке;
    /// ближайшая клавиша входит всегда.
    func keys(near point: CGPoint, radius: CGFloat) -> Set<Int> {
        var result = Set<Int>()
        var nearest: (index: Int, distance: CGFloat)?
        for (index, key) in keys.enumerated() {
            let distance = hypot(point.x - key.center.x, (point.y - key.center.y) * 0.9)
            if distance <= radius * keyWidth { result.insert(index) }
            if nearest == nil || distance < nearest!.distance { nearest = (index, distance) }
        }
        if let nearest { result.insert(nearest.index) }
        return result
    }
}

// MARK: - Подбор слов по траектории

enum SwipeTyping {

    private struct Candidate {
        let word: String
        let keys: [Int]
        let logFrequency: Double
    }

    /// Кандидаты для текущей раскладки (строятся один раз, ~40 тыс. слов).
    private static var cache: (signature: String, candidates: [Candidate])?

    /// Сколько самых частых слов словаря участвуют в свайпе.
    private static let vocabularySize = 40_000
    private static let sampleCount = 32

    /// Допуск формы (в ширинах клавиши) и вес частоты слова.
    private static let shapeTolerance = 0.5
    private static let frequencyWeight = 0.5
    /// Бонус словам, которые обычно идут после предыдущего слова.
    private static let contextBonus = 1.5

    /// До `limit` слов, лучше всего подходящих под траекторию `points`
    /// (координаты панели букв). `likelyNext` — вероятные слова после
    /// предыдущего (нижний регистр). Пусто — подходящего слова нет.
    static func suggestions(points: [CGPoint], geometry: SwipeKeyboardGeometry,
                            script: TatarScript, likelyNext: Set<String> = [],
                            limit: Int = 3) -> [String] {
        guard script != .arabic, points.count >= 2,
              let first = points.first, let last = points.last else { return [] }
        let candidates = candidateList(for: geometry, script: script)
        guard !candidates.isEmpty else { return [] }

        let unit = geometry.keyWidth
        let userLength = pathLength(points)
        let userSamples = resample(points, count: sampleCount)
        let startKeys = geometry.keys(near: first, radius: 1.1)
        let endKeys = geometry.keys(near: last, radius: 1.1)

        var scored: [(word: String, score: Double)] = []
        scored.reserveCapacity(256)
        for candidate in candidates {
            guard let firstKey = candidate.keys.first, let lastKey = candidate.keys.last,
                  startKeys.contains(firstKey), endKeys.contains(lastKey) else { continue }
            let ideal = candidate.keys.map { geometry.keys[$0].center }
            // Идеальная траектория не может быть намного длиннее реальной
            // (палец проходит все клавиши слова) и сильно короче её.
            let idealLength = pathLength(ideal)
            guard idealLength <= userLength * 1.6 + unit,
                  idealLength >= userLength * 0.45 - unit else { continue }

            let idealSamples = resample(ideal, count: sampleCount)
            var total: CGFloat = 0
            for i in 0..<sampleCount {
                total += hypot(userSamples[i].x - idealSamples[i].x, userSamples[i].y - idealSamples[i].y)
            }
            let distance = Double(total / CGFloat(sampleCount) / unit)
            var score = -pow(distance / shapeTolerance, 2) + frequencyWeight * candidate.logFrequency
            if !likelyNext.isEmpty, likelyNext.contains(candidate.word.lowercased(with: script.caseLocale)) {
                score += contextBonus
            }
            scored.append((candidate.word, score))
        }

        scored.sort { $0.score > $1.score }
        var seen = Set<String>()
        var result: [String] = []
        for item in scored where seen.insert(item.word.lowercased()).inserted {
            result.append(item.word)
            if result.count == limit { break }
        }
        return result
    }

    private static func candidateList(for geometry: SwipeKeyboardGeometry, script: TatarScript) -> [Candidate] {
        if let cache, cache.signature == geometry.signature { return cache.candidates }
        let words = TatarLanguageModel.shared.mostFrequentWords(limit: vocabularySize, script: script)
        guard !words.isEmpty else { return [] } // словарь ещё грузится — не кэшируем пустоту

        var candidates: [Candidate] = []
        candidates.reserveCapacity(words.count)
        wordLoop: for entry in words {
            var keys: [Int] = []
            for ch in entry.word.lowercased(with: script.caseLocale) {
                // Слова с буквами не с этой раскладки (дефис, «ё» в латинице...) пропускаем.
                guard let key = geometry.keyIndexByLetter[ch] else { continue wordLoop }
                if keys.last != key { keys.append(key) }
            }
            // Одноклавишные слова («а», «аа») свайпом не набирают — это тап.
            guard keys.count >= 2 else { continue }
            candidates.append(Candidate(word: entry.word, keys: keys, logFrequency: log(Double(max(entry.frequency, 1)))))
        }
        cache = (geometry.signature, candidates)
        return candidates
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Равномерная по длине перевыборка ломаной в `count` точек.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard let first = points.first else { return [] }
        let total = pathLength(points)
        guard total > 0, points.count > 1 else { return Array(repeating: first, count: count) }

        let step = total / CGFloat(count - 1)
        var result: [CGPoint] = [first]
        result.reserveCapacity(count)
        var previous = first
        var accumulated: CGFloat = 0
        var index = 1
        while index < points.count && result.count < count {
            let current = points[index]
            let segment = hypot(current.x - previous.x, current.y - previous.y)
            if segment > 0, accumulated + segment >= step {
                let t = (step - accumulated) / segment
                let point = CGPoint(x: previous.x + t * (current.x - previous.x),
                                    y: previous.y + t * (current.y - previous.y))
                result.append(point)
                previous = point
                accumulated = 0
            } else {
                accumulated += segment
                previous = current
                index += 1
            }
        }
        while result.count < count { result.append(points[points.count - 1]) }
        return result
    }
}
