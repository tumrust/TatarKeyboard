//
//  TatarLanguageModel.swift
//  TatarKeyboardExtension
//
//  Большой словарь для подсказок при наборе, автозамены и предсказания
//  следующего слова: ~113 тыс. словоформ и для каждой — до 4 самых частых
//  слов, идущих следом. Данные (TatarLanguageModel.txt) посчитаны по корпусам
//  Лейпцигского университета «tat_mixed_2015_1M» и «tat_wikipedia_2021_100K»
//  (Leipzig Corpora Collection, wortschatz.uni-leipzig.de, ~1,1 млн
//  предложений, ~14 млн слов; в основном azatliq.org и татарская Википедия),
//  оставлены словоформы, встретившиеся не реже 4 раз. Латиница (Neo-әlif)
//  получена из кириллицы тем же NeoAlifTransliteration.
//
//  Формат строки (TAB-разделители), строки отсортированы по байтам UTF-8 ключа:
//    ключ (кириллица, нижний регистр) | частота | латиница | 1 — имя
//    собственное (писать с заглавной) | позиция в порядке сортировки латиницы |
//    номера строк следующих слов через запятую.
//  Первая строка «#\t...» — частые первые слова предложения.
//
//  Сортировка заранее позволяет искать и по префиксу, и точное слово
//  бинарным поиском без построения индексов при запуске; файл читается в
//  фоне при открытии клавиатуры (см. KeyboardViewController).
//

import Foundation

final class TatarLanguageModel {
    static let shared = TatarLanguageModel()

    private struct Storage {
        var keys: [String] = []
        var latin: [String] = []
        var counts: [Int32] = []
        var capitalized: [Bool] = []
        /// latinOrder[позиция в латинской сортировке] = номер слова.
        var latinOrder: [Int32] = []
        var next: [[Int32]] = []
        var sentenceStarters: [Int32] = []
    }

    /// Доступ только с главного потока; заполняется после фоновой загрузки.
    private var storage: Storage?
    private var isLoading = false
    private var frequencyOrder: [Int] = []

    /// Слова, которые пользователь отстоял (отменил автозамену или выбрал
    /// «как есть») — их больше не исправляем.
    private var learnedWords: Set<String>
    private static let learnedWordsKey = "learnedWords"
    private static let learnedWordsLimit = 1000

    var isLoaded: Bool { storage != nil }

    private init() {
        learnedWords = Set(UserDefaults.standard.stringArray(forKey: Self.learnedWordsKey) ?? [])
    }

    func loadIfNeeded(completion: @escaping () -> Void) {
        guard storage == nil, !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Self.parse()
            DispatchQueue.main.async {
                self.storage = loaded
                self.isLoading = false
                completion()
            }
        }
    }

    // MARK: - Запросы

    /// До `limit` самых частых слов, начинающихся с `prefix`.
    func completions(forPrefix prefix: String, script: TatarScript, limit: Int) -> [String] {
        guard let s = storage, script != .arabic, !prefix.isEmpty else { return [] }
        let key = prefix.lowercased(with: script.caseLocale)
        var best: [Int32] = []
        var position = lowerBound(key, script: script, in: s)
        var scanned = 0
        // Для 1–2 букв диапазон может быть огромным — ограничиваем перебор.
        while position < s.keys.count, scanned < 30_000 {
            let index = order(position, script: script, in: s)
            guard word(index, script: script, in: s).utf8.starts(with: key.utf8) else { break }
            insert(index, into: &best, limit: limit, counts: s.counts)
            position += 1
            scanned += 1
        }
        return best.map { display($0, script: script, in: s) }
    }

    /// Самые частые слова (по убыванию частоты) — кандидаты для свайп-ввода,
    /// которому нужен перебор, а не поиск по префиксу. Список строится один раз.
    func mostFrequentWords(limit: Int, script: TatarScript) -> [(word: String, frequency: Int)] {
        guard let s = storage, script != .arabic else { return [] }
        if frequencyOrder.count < min(limit, s.counts.count) {
            frequencyOrder = Array(s.counts.indices.sorted { s.counts[$0] > s.counts[$1] }.prefix(max(limit, 20_000)))
        }
        return frequencyOrder.prefix(limit).map { index in
            (display(Int32(index), script: script, in: s), Int(s.counts[index]))
        }
    }

    /// Есть ли слово в словаре (или среди выученных пользователем).
    func isKnown(_ word: String, script: TatarScript) -> Bool {
        let key = word.lowercased(with: script.caseLocale)
        if learnedWords.contains(key) { return true }
        guard let s = storage else { return true }
        return index(of: key, script: script, in: s) != nil
    }

    /// Самые вероятные следующие слова. `previous == nil` — начало предложения.
    func nextWords(after previous: String?, script: TatarScript, limit: Int) -> [String] {
        guard let s = storage, script != .arabic else { return [] }
        let candidates: [Int32]
        if let previous {
            let key = previous.lowercased(with: script.caseLocale)
            guard let index = index(of: key, script: script, in: s) else { return [] }
            candidates = s.next[Int(index)]
        } else {
            candidates = s.sentenceStarters
        }
        return candidates.prefix(limit).map { display($0, script: script, in: s) }
    }

    /// Исправление для слова, которого нет в словаре: сначала пробуем
    /// расставить «татарские» буквы (а→ә, о→ө, у→ү, н→ң, ж→җ, х→һ — частая
    /// ошибка, т.к. они на долгом нажатии), затем — одну опечатку (лишняя,
    /// пропущенная, заменённая или переставленная буква). nil — исправлять нечего.
    func correction(for typed: String, script: TatarScript) -> String? {
        guard let s = storage, script != .arabic else { return nil }
        let key = typed.lowercased(with: script.caseLocale)
        let chars = Array(key)
        guard chars.count >= 2, chars.allSatisfy({ $0.isLetter }), !learnedWords.contains(key) else { return nil }
        // В корпусе есть и опечатки («белан» — 43 раза против 153 тыс. «белән»),
        // поэтому «знакомое» слово тоже исправляем, если вариант несравнимо частотнее.
        let knownCount = index(of: key, script: script, in: s).map { s.counts[Int($0)] } ?? 0

        var best: (index: Int32, score: Double)?
        func consider(_ candidate: [Character], penalty: Double, minCount: Int32) {
            guard let index = index(of: String(candidate), script: script, in: s) else { return }
            let count = s.counts[Int(index)]
            guard count >= minCount else { return }
            let score = log(Double(count)) - penalty
            if best == nil || score > best!.score { best = (index, score) }
        }

        // 1. Варианты с татарскими буквами (до 256 комбинаций).
        let table = script == .latin ? Self.latinDiacritics : Self.cyrillicDiacritics
        var variants: [(chars: [Character], changes: Int)] = [(chars, 0)]
        for (position, ch) in chars.enumerated() {
            guard let alternatives = table[ch] else { continue }
            for variant in variants where variants.count < 256 {
                for alternative in alternatives {
                    var changed = variant.chars
                    changed[position] = alternative
                    variants.append((changed, variant.changes + 1))
                }
            }
        }
        for variant in variants.dropFirst() {
            consider(variant.chars, penalty: 0.7 * Double(variant.changes), minCount: max(2, knownCount &* 50))
        }
        if let best { return display(best.index, script: script, in: s) }

        // 2. Одна опечатка — только для слов от 3 букв и только в частые слова.
        guard chars.count >= 3, knownCount <= 20 else { return nil }
        let alphabet = script == .latin ? Self.latinAlphabet : Self.cyrillicAlphabet
        let editPenalty = 5.0
        let minCount: Int32 = max(20, knownCount &* 1000)
        for i in chars.indices {
            var deleted = chars
            deleted.remove(at: i)
            consider(deleted, penalty: editPenalty, minCount: minCount)
            if i + 1 < chars.count {
                var swapped = chars
                swapped.swapAt(i, i + 1)
                consider(swapped, penalty: editPenalty - 1, minCount: minCount)
            }
            for letter in alphabet where letter != chars[i] {
                var substituted = chars
                substituted[i] = letter
                consider(substituted, penalty: editPenalty, minCount: minCount)
            }
        }
        for i in 0...chars.count {
            for letter in alphabet {
                var inserted = chars
                inserted.insert(letter, at: i)
                consider(inserted, penalty: editPenalty, minCount: minCount)
            }
        }
        return best.map { display($0.index, script: script, in: s) }
    }

    /// Запоминает слово как «правильное» — автозамена его больше не трогает.
    func learn(_ word: String, script: TatarScript) {
        let key = word.lowercased(with: script.caseLocale)
        guard !key.isEmpty, !learnedWords.contains(key) else { return }
        learnedWords.insert(key)
        var stored = UserDefaults.standard.stringArray(forKey: Self.learnedWordsKey) ?? []
        stored.append(key)
        if stored.count > Self.learnedWordsLimit {
            stored.removeFirst(stored.count - Self.learnedWordsLimit)
        }
        UserDefaults.standard.set(stored, forKey: Self.learnedWordsKey)
    }

    // MARK: - Поиск по отсортированным массивам

    private func word(_ index: Int32, script: TatarScript, in s: Storage) -> String {
        script == .latin ? s.latin[Int(index)] : s.keys[Int(index)]
    }

    private func order(_ position: Int, script: TatarScript, in s: Storage) -> Int32 {
        script == .latin ? s.latinOrder[position] : Int32(position)
    }

    /// Первая позиция, где слово не меньше `key` (сравнение по байтам UTF-8 —
    /// в том же порядке отсортирован файл).
    private func lowerBound(_ key: String, script: TatarScript, in s: Storage) -> Int {
        var low = 0
        var high = s.keys.count
        while low < high {
            let mid = (low + high) / 2
            if word(order(mid, script: script, in: s), script: script, in: s).utf8.lexicographicallyPrecedes(key.utf8) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func index(of key: String, script: TatarScript, in s: Storage) -> Int32? {
        let position = lowerBound(key, script: script, in: s)
        guard position < s.keys.count else { return nil }
        let index = order(position, script: script, in: s)
        return word(index, script: script, in: s).utf8.elementsEqual(key.utf8) ? index : nil
    }

    /// Вставка в маленький список лучших по частоте (по убыванию).
    private func insert(_ index: Int32, into best: inout [Int32], limit: Int, counts: [Int32]) {
        let count = counts[Int(index)]
        if best.count == limit, let last = best.last, counts[Int(last)] >= count { return }
        let position = best.firstIndex { counts[Int($0)] < count } ?? best.count
        best.insert(index, at: position)
        if best.count > limit { best.removeLast() }
    }

    private func display(_ index: Int32, script: TatarScript, in s: Storage) -> String {
        let text = word(index, script: script, in: s)
        guard s.capitalized[Int(index)] else { return text }
        return text.prefix(1).uppercased(with: script.caseLocale) + text.dropFirst()
    }

    // MARK: - Алфавиты

    private static let cyrillicAlphabet = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюяәөүҗңһ")
    private static let latinAlphabet = Array("abcçdefgğhıijklmnñoöpqrsştuüvwxyzə")

    private static let cyrillicDiacritics: [Character: [Character]] = [
        "а": ["ә"], "ә": ["а"], "о": ["ө"], "ө": ["о"], "у": ["ү"], "ү": ["у"],
        "н": ["ң"], "ң": ["н"], "ж": ["җ"], "җ": ["ж"], "х": ["һ"], "һ": ["х"],
        "э": ["ә"]
    ]
    private static let latinDiacritics: [Character: [Character]] = [
        "a": ["ə"], "ə": ["a", "e"], "e": ["ə"], "o": ["ö"], "ö": ["o"], "u": ["ü"], "ü": ["u"],
        "n": ["ñ"], "ñ": ["n"], "g": ["ğ"], "ğ": ["g"], "s": ["ş"], "ş": ["s"],
        "c": ["ç"], "ç": ["c"], "i": ["ı"], "ı": ["i"]
    ]

    // MARK: - Загрузка файла

    private static func parse() -> Storage? {
        guard let url = Bundle.main.url(forResource: "TatarLanguageModel", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        var s = Storage()
        var latinRanks: [Int32] = []
        s.keys.reserveCapacity(120_000)
        s.latin.reserveCapacity(120_000)
        s.counts.reserveCapacity(120_000)
        s.capitalized.reserveCapacity(120_000)
        s.next.reserveCapacity(120_000)
        latinRanks.reserveCapacity(120_000)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count

            func string(_ r: Range<Int>) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: bytes[r]), as: UTF8.self)
            }
            func number(_ r: Range<Int>) -> Int32 {
                var value: Int32 = 0
                for j in r { value = value &* 10 &+ Int32(bytes[j] &- 48) }
                return value
            }
            func numbers(_ r: Range<Int>) -> [Int32] {
                guard !r.isEmpty else { return [] }
                var result: [Int32] = []
                var start = r.lowerBound
                for j in r where bytes[j] == 0x2C { // ','
                    result.append(number(start..<j))
                    start = j + 1
                }
                result.append(number(start..<r.upperBound))
                return result
            }

            var fields: [Range<Int>] = []
            var lineStart = 0
            while lineStart < n {
                var end = lineStart
                while end < n && bytes[end] != 0x0A { end += 1 }
                fields.removeAll(keepingCapacity: true)
                var fieldStart = lineStart
                for j in lineStart..<end where bytes[j] == 0x09 {
                    fields.append(fieldStart..<j)
                    fieldStart = j + 1
                }
                fields.append(fieldStart..<end)

                if bytes[lineStart] == 0x23 { // '#' — заголовок с первыми словами предложения
                    if fields.count >= 2 { s.sentenceStarters = numbers(fields[1]) }
                } else if fields.count >= 6 {
                    s.keys.append(string(fields[0]))
                    s.counts.append(number(fields[1]))
                    s.latin.append(string(fields[2]))
                    s.capitalized.append(bytes[fields[3].lowerBound] == 0x31)
                    latinRanks.append(number(fields[4]))
                    s.next.append(numbers(fields[5]))
                }
                lineStart = end + 1
            }
        }

        s.latinOrder = Array(repeating: 0, count: latinRanks.count)
        for (index, rank) in latinRanks.enumerated() where Int(rank) < s.latinOrder.count {
            s.latinOrder[Int(rank)] = Int32(index)
        }
        let total = s.keys.count
        s.next = s.next.map { $0.filter { Int($0) < total } }
        s.sentenceStarters = s.sentenceStarters.filter { Int($0) < total }
        return s
    }
}
