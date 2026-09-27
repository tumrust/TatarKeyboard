//
//  SwipeTyping.swift
//  TatarKeyboardExtension
//
//  Упрощённый свайп-ввод: пока палец не отрывается от экрана, собираем
//  последовательность букв, над которыми он проходит, и подбираем ближайшее
//  слово из FrequencyDictionary (общий словарь с предиктивным набором — 850
//  слов, кириллица+латиница). Это НЕ полноценный Gboard-алгоритм (тот учитывает
//  форму всей траектории и обучается на статистике языка) — здесь работает
//  облегчённая эвристика: подпоследовательность + бонусы за первую/последнюю
//  букву и длину, при равенстве — по частоте слова.
//
//  Функция включается флагом isSwipeTypingEnabled в KeyboardRootView.swift
//  (сейчас false — на маленьком словаре из ~70 слов, который был здесь раньше,
//  реальные свайпы почти никогда не находили совпадение и просто вставляли
//  «сырые» буквы под траекторией; после перехода на большой FrequencyDictionary
//  стоит попробовать снова, но это ещё не проверялось на устройстве).
//
//  Для арабицы (RTL со сложным формированием глифов) свайп остаётся отключён —
//  координаты жеста считаются в физическом (LTR) порядке экрана, а раскладка
//  отображается зеркально, так что распознавание было бы некорректным без
//  отдельной RTL-математики.
//

import Foundation
import CoreGraphics

/// Общее состояние текущего жеста свайпа. Простой reference-тип (не ObservableObject) —
/// его читают клавиши в момент завершения касания, лишние re-render'ы не нужны.
final class SwipeState {
    var isActive: Bool = false
    var path: [String] = []

    func reset() {
        isActive = false
        path = []
    }

    /// Добавляет букву в путь, если она отличается от последней (палец может
    /// какое-то время находиться над одной и той же клавишей).
    func append(_ letter: String) {
        guard path.last != letter else { return }
        path.append(letter)
        if path.count >= 2 {
            isActive = true
        }
    }
}

enum SwipeTyping {

    /// Подбирает до `limit` слов, чья траектория лучше всего согласуется с путём
    /// свайпа — теперь ищет по тому же FrequencyDictionary, что и предиктивный
    /// набор (850 слов, кириллица+латиница), а не по отдельному списку из ~70
    /// слов, как раньше. На маленьком списке почти любой реальный свайп не
    /// находил совпадений и просто вставлял «сырые» буквы под траекторией —
    /// с большим словарём вероятность найти реальное слово должна быть
    /// значительно выше. Для нераспознанных путей и для арабицы (без словаря
    /// подходящего вида) по-прежнему возвращает сам прослеженный путь как
    /// единственный вариант — так пользователь не теряет ввод.
    static func suggestions(forPath path: [String], script: TatarScript, limit: Int = 3) -> [String] {
        let traced = path.joined()
        guard script != .arabic, path.count >= 2 else {
            return [traced]
        }

        let scored: [(word: String, score: Int, frequency: Int)] = FrequencyDictionary.entries.compactMap { entry in
            let candidate = script == .cyrillic ? entry.cyrillic : entry.latin
            guard let score = matchScore(word: candidate, tracedPath: path) else { return nil }
            return (candidate, score, entry.frequency)
        }

        // Сначала по качеству совпадения буквенного пути, при равенстве — по
        // частоте слова (более распространённые слова выше).
        let sorted = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.frequency > $1.frequency }
        let top = sorted.prefix(limit).map { $0.word }
        return top.isEmpty ? [traced] : top
    }

    /// Слово подходит, если буквы пути встречаются в нём по порядку (не обязательно
    /// подряд — как и при реальном свайпе, палец задевает соседние клавиши).
    /// Бонусы: совпадение первой/последней буквы, штраф за разницу в длине.
    private static func matchScore(word: String, tracedPath: [String]) -> Int? {
        let wordChars = Array(word)
        var wordIndex = 0

        for pathLetter in tracedPath {
            guard let target = pathLetter.first else { continue }
            var found = false
            while wordIndex < wordChars.count {
                let current = wordChars[wordIndex]
                wordIndex += 1
                if current == target {
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        var score = 10
        if word.first == tracedPath.first?.first { score += 5 }
        if word.last == tracedPath.last?.first { score += 5 }
        score -= abs(word.count - tracedPath.count)
        return score
    }
}

/// Слот раскладки для геометрического хит-теста свайпа: либо буква (со своим
/// нижним регистром — путь всегда собирается без учёта Shift), либо служебная
/// клавиша (Shift/Backspace), которая в подбор слова не участвует.
enum PadSlot {
    case letter(String)
    case nonLetter
}

enum SwipeHitTesting {

    /// Раскладывает три ряда букв в плоский список «слотов» на ряд — с учётом того,
    /// что в последнем ряду слева может быть Shift, а справа всегда Backspace
    /// (см. компоновку в KeyboardRootView.letterRow).
    static func slots(for rows: [[KeyDefinition]], script: TatarScript) -> [[PadSlot]] {
        rows.enumerated().map { index, row in
            var slots: [PadSlot] = []
            let isLast = index == rows.count - 1
            if isLast && script.supportsShift {
                slots.append(.nonLetter) // Shift
            }
            slots.append(contentsOf: row.map { .letter($0.main.lowercased()) })
            if isLast {
                slots.append(.nonLetter) // Backspace
            }
            return slots
        }
    }

    /// Простой геометрический хит-тест: делит зону свайпа на равные по высоте
    /// ряды и каждый ряд — на равные по ширине слоты (клавиши растягиваются
    /// через `.frame(maxWidth: .infinity)`, так что это достаточно точное
    /// приближение без более сложной системы Preference/Anchor).
    static func letter(at point: CGPoint, in size: CGSize, rows: [[KeyDefinition]], script: TatarScript) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        let rowSlots = slots(for: rows, script: script)
        guard !rowSlots.isEmpty else { return nil }

        let rowHeight = size.height / CGFloat(rowSlots.count)
        let rowIndex = min(max(Int(point.y / rowHeight), 0), rowSlots.count - 1)
        let slotsInRow = rowSlots[rowIndex]
        guard !slotsInRow.isEmpty else { return nil }

        let slotWidth = size.width / CGFloat(slotsInRow.count)
        let colIndex = min(max(Int(point.x / slotWidth), 0), slotsInRow.count - 1)

        if case let .letter(char) = slotsInRow[colIndex] {
            return char
        }
        return nil
    }
}
