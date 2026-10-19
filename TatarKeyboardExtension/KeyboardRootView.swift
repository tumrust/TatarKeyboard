//  KeyboardRootView.swift
//  TatarKeyboardExtension
//
//  Визуальный слой клавиатуры: буквы (кириллица/латиница/арабица), страницы
//  123 / #+= / эмодзи, динамическая кнопка Return, автозаглавные, повтор
//  Backspace при удержании, двойной пробел → точка, доп. переключатель
//  письменности у пробела, свайп-ввод и предиктивные подсказки слов
//  (по TatarLanguageModel, с адаптацией под кириллицу/латиницу), плюс
//  тактильный отклик по нажатиям (требует Full Access).
//  Как в системной клавиатуре: курсор-трекпад на пробеле, ленты вариантов
//  по долгому нажатию, двойной тап Shift = Caps Lock, удаление словами при
//  долгом удержании Backspace, цифровые панели и @/./ для e-mail/URL,
//  замены текста iOS, недавние эмодзи и подписи для VoiceOver.
//

import SwiftUI
import UIKit

struct KeyboardRootView: View {

    // MARK: Зависимости от KeyboardViewController

    @ObservedObject var context: KeyboardContext
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    /// Сдвиг курсора на N символов (для трекпада на пробеле).
    let moveCursor: (Int) -> Void
    /// Текст непосредственно пере д курсором — нужен для автозаглавных, для
    /// правила «двойной пробел → точка» и для предиктивных подсказок (какое
    /// слово сейчас набирается).
    let documentContextBeforeInput: () -> String?
    /// Системная обработка кнопки 🌐: тап — следующая клавиатура, удержание — список.
    let handleInputModeList: (UIView, UIEvent) -> Void
    /// Звук и вибрация нажатия (см. KeyFeedback); включаются/выключаются
    /// в хост-приложении, требуют Full Access — проверяется в KeyboardViewController.
    let keyFeedback: (KeyFeedback) -> Void

    private enum Mode { case letters, numbers, symbols, emoji }

    /// Цифровые панели для полей с соответствующим keyboardType.
    private enum DigitPadKind { case digits, decimal, phone }

    /// Откуда взялись текущие предложенные слова — важно знать, сколько
    /// символов удалить при принятии другого варианта.
    private enum SuggestionSource {
        case typing(prefixLength: Int)
        case swipe(insertedWord: String)
        /// Предсказание следующего слова — ничего удалять не нужно.
        case prediction
    }

    @State private var script: TatarScript = .cyrillic
    @State private var mode: Mode = .letters
    @State private var shifted = false
    @State private var capsLock = false
    @State private var lastShiftTapTime: Date?
    @State private var lastSpaceTapTime: Date?
    /// 0 — «Недавние», 1... — категории EmojiData.categories.
    @State private var emojiCategoryIndex = 0
    @State private var recentEmojis: [String] = RecentEmoji.load()
    /// Палец водит по пробелу — клавиши приглушены, курсор двигается.
    @State private var isCursorMode = false

    @State private var suggestions: [String] = []
    @State private var suggestionSource: SuggestionSource?
    /// Набранное слово «как есть», показывается первым в «кавычках».
    @State private var literalSuggestion: String?
    /// После принятия подсказки был автоматически вставлен пробел — знак
    /// препинания, набранный следом, встанет вплотную к слову.
    @State private var autoSpaceInserted = false
    /// Последняя автозамена — Backspace сразу после неё возвращает набранное.
    @State private var lastAutocorrection: (original: String, corrected: String, suffix: String)?
    private let languageModel = TatarLanguageModel.shared
    @StateObject private var swipeState = SwipeState()
    @StateObject private var swipeTrail = SwipeTrail()

    /// Свайп-ввод по форме траектории (см. SwipeTyping.swift). Не работает в
    /// арабице, в полях паролей, e-mail и URL — как QuickPath в iOS.
    private var isSwipeTypingEnabled: Bool {
        !script.isRTL && !context.isSecureTextEntry
            && context.keyboardType != .emailAddress && context.keyboardType != .URL
    }

    private let letterPadHeight: CGFloat = 3 * 42 + 2 * 8 // 3 ряда по 42pt + 2 промежутка по 8pt
    private let suggestionBarHeight: CGFloat = 30
    /// 4 ряда по 50pt + 3 промежутка по 6pt = 218pt — помещается в ту же высоту расширения.
    private let digitKeyHeight: CGFloat = 50

    var body: some View {
        VStack(spacing: 8) {
            if let kind = digitPadKind {
                digitPad(kind)
            } else {
                if mode != .emoji {
                    suggestionBar
                }
                switch mode {
                case .letters:
                    lettersPad
                case .numbers:
                    punctuationPad(rows: TatarLayout.numberRows(for: script), toggleLabel: "#+=", toggleTarget: .symbols)
                case .symbols:
                    punctuationPad(rows: TatarLayout.symbolRows(for: script), toggleLabel: "123", toggleTarget: .numbers)
                case .emoji:
                    emojiPad
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .environment(\.layoutDirection, (mode == .letters && script.isRTL) ? .rightToLeft : .leftToRight)
        // Тема задаётся явно из KeyboardViewController: у расширения клавиатуры
        // собственные traits не всегда совпадают с темой поля ввода.
        .environment(\.colorScheme, context.isDarkAppearance ? .dark : .light)
        .background(Color.clear)
        .onAppear { applyKeyboardType() }
        .onChange(of: context.keyboardType) { _, _ in applyKeyboardType() }
        .onChange(of: context.documentChangeCount) { _, _ in handleDocumentChange() }
    }

    // MARK: - Реакция на поле ввода (тип клавиатуры, изменения текста снаружи)

    private var digitPadKind: DigitPadKind? {
        switch context.keyboardType {
        case .numberPad, .asciiCapableNumberPad: return .digits
        case .decimalPad: return .decimal
        case .phonePad: return .phone
        default: return nil
        }
    }

    /// Новое поле ввода: стартовая страница зависит от его keyboardType.
    private func applyKeyboardType() {
        clearSuggestions()
        mode = context.keyboardType == .numbersAndPunctuation ? .numbers : .letters
        maybeAutoShift()
    }

    /// Курсор передвинули/текст изменился не через нас (или поле сменилось) —
    /// пересчитываем автозаглавные и подсказки под новое положение курсора.
    private func handleDocumentChange() {
        if case .swipe = suggestionSource { return }
        maybeAutoShift()
        updateTypingSuggestions()
    }

    // MARK: - Панель предложений: и предиктивный набор, и результат свайпа

    private var suggestionBar: some View {
        HStack(spacing: 0) {
            if mode == .letters && !suggestions.isEmpty {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, word in
                    let isLiteral = index == 0 && literalSuggestion != nil
                    let isBest = index == (literalSuggestion != nil ? 1 : 0)
                    Button {
                        acceptSuggestion(word)
                    } label: {
                        Text(isLiteral ? "«\(word)»" : word)
                            .font(.system(size: 15, weight: isBest ? .semibold : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    if index < suggestions.count - 1 {
                        Divider().frame(height: 16)
                    }
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: suggestionBarHeight)
    }

    // MARK: - Переключение письменности (без визуальной панели — см. кнопку у пробела)

    private func selectScript(_ candidate: TatarScript) {
        // Смена письменности разворачивает layoutDirection на .rightToLeft для
        // арабицы (и обратно) — это меняет порядок вообще всех клавиш в ряду.
        // Без явного отключения анимации на именно эту смену состояния SwiftUI
        // подхватывал соседний .animation(...) с клавиш и красиво, но долго
        // «переплывал» все кнопки на новые места — выглядело как лишняя
        // анимация специально у кнопки Aa. Отключаем анимацию только для этого
        // присваивания, остальные анимации (нажатия клавиш и т.д.) не трогаем.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            script = candidate
        }
        shifted = false
        capsLock = false
        clearSuggestions()
        maybeAutoShift()
    }

    private func cycleScript() {
        let all = TatarScript.allCases
        let idx = all.firstIndex(of: script) ?? 0
        let next = all[(idx + 1) % all.count]
        // Раньше здесь просто менялась script (через selectScript), а mode не
        // трогался — если нажать «Aa» на экране 123/#+=, письменность внутри
        // менялась, но пользователь оставался на цифрах и НИЧЕГО не видел:
        // цифры одинаковы во всех трёх письменностях. Теперь кнопка всегда
        // возвращает на экран букв — так же, как ведёт себя переключение языка
        // в системной клавиатуре.
        selectScript(next)
        switchMode(.letters)
    }

    private func switchMode(_ newMode: Mode) {
        clearSuggestions()
        mode = newMode
    }

    // MARK: - Страница букв (со свайп-вводом и предиктивными подсказками)

    private var lettersPad: some View {
        let rows = TatarLayout.letterRows(for: script, shifted: shifted || capsLock)
        return VStack(spacing: 8) {
            GeometryReader { proxy in
                let geometry = SwipeKeyboardGeometry(rows: rows, script: script, size: proxy.size)
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 5) {
                            if index == rows.count - 1 && script.supportsShift {
                                shiftKey
                            }
                            ForEach(Array(row.enumerated()), id: \.element.id) { keyIndex, key in
                                KeyButton(title: key.main, alts: key.alts, showsAltHint: true,
                                          opensToLeft: keyIndex >= row.count / 2, swipeState: swipeState) { text in
                                    commitTap(text)
                                }
                            }
                            if index == rows.count - 1 {
                                deleteKey()
                            }
                        }
                    }
                }
                // В режиме трекпада (палец на пробеле) клавиши приглушаются, как в iOS.
                .opacity(isCursorMode ? 0.3 : 1)
                // След пальца поверх клавиш во время свайпа.
                .overlay(SwipeTrailView(trail: swipeTrail))
                // Свайп-ввод: записываем траекторию пальца; как только он перешёл
                // на вторую букву — это свайп (клавиша под пальцем свою букву уже
                // не вставит). Работает одновременно с обычными нажатиями
                // благодаря simultaneousGesture — не мешает короткому тапу.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { value in
                            guard isSwipeTypingEnabled else { return }
                            swipeState.track(point: value.location, start: value.startLocation,
                                             key: geometry.letterKey(at: value.location))
                            if swipeState.isActive && !swipeState.isSuppressed {
                                swipeTrail.points = swipeState.points
                            }
                        }
                        .onEnded { _ in
                            swipeTrail.points = []
                            guard isSwipeTypingEnabled, swipeState.endTracking() else { return }
                            commitSwipe(points: swipeState.points, geometry: geometry)
                        }
                )
            }
            .frame(height: letterPadHeight)

            bottomRow(leftLabel: "123", leftAction: { switchMode(.numbers) }, extraKeys: fieldExtraKeys)
        }
    }

    /// Доп. клавиши у пробела под тип поля — как в системной клавиатуре для e-mail/URL.
    private var fieldExtraKeys: [KeyDefinition] {
        switch context.keyboardType {
        case .emailAddress: return [KeyDefinition("@"), KeyDefinition(".")]
        case .URL:          return [KeyDefinition("/"), KeyDefinition(".", alts: [".com", ".ru", ".tatar", ".org"])]
        case .webSearch:    return [KeyDefinition(".")]
        case .twitter:      return [KeyDefinition("@"), KeyDefinition("#")]
        default:            return []
        }
    }

    /// Вставка символа с «умным» пробелом: если после принятой подсказки стоит
    /// автопробел, знак препинания встаёт вплотную к слову, а пробел — после него.
    private func insertCharacter(_ text: String) {
        lastAutocorrection = nil
        let isPunctuation = [".", ",", "!", "?", ":", ";"].contains(text)
        if autoSpaceInserted, isPunctuation,
           documentContextBeforeInput()?.hasSuffix(" ") == true {
            deleteBackward()
            insertText(text + " ")
        } else {
            // Знак препинания сразу после слова завершает его — как и пробел.
            if isPunctuation { applyAutocorrectionIfNeeded(suffix: text) }
            insertText(text)
        }
        autoSpaceInserted = false
    }

    // MARK: - Автозамена

    /// Автозамену не делаем в паролях, e-mail/URL и там, где поле её отключило.
    private var isAutocorrectEnabled: Bool {
        !context.isSecureTextEntry && context.autocorrectionType != .no
            && context.keyboardType != .emailAddress && context.keyboardType != .URL
    }

    /// Слово перед курсором, если оно отделено от остального текста
    /// пробелом/началом строки/скобкой (не часть e-mail, ссылки, «ир-егет»).
    private func completedWordBeforeCursor() -> String? {
        let before = documentContextBeforeInput() ?? ""
        let word = currentWordPrefix(in: before)
        guard !word.isEmpty else { return nil }
        let rest = before.dropLast(word.count)
        if let boundary = rest.last, !(boundary.isWhitespace || "([«\"„“'".contains(boundary)) { return nil }
        return word
    }

    /// Исправляет только что набранное слово (если оно похоже на опечатку).
    /// `suffix` — то, что будет вставлено следом (пробел или знак), для отмены.
    @discardableResult
    private func applyAutocorrectionIfNeeded(suffix: String) -> Bool {
        guard isAutocorrectEnabled, script != .arabic,
              let word = completedWordBeforeCursor(),
              // Слова ЦЕЛИКОМ ЗАГЛАВНЫМИ (аббревиатуры) не трогаем.
              !(word.count > 1 && word.allSatisfy { $0.isUppercase }),
              let correction = languageModel.correction(for: word, script: script) else { return false }
        let corrected = matchCase(correction, to: word)
        guard corrected != word else { return false }
        for _ in 0..<word.count { deleteBackward() }
        insertText(corrected)
        lastAutocorrection = (word, corrected, suffix)
        return true
    }

    /// Backspace сразу после автозамены: возвращает набранное слово (без
    /// пробела, курсор — в конце слова) и запоминает его, чтобы больше не исправлять.
    private func undoAutocorrectionIfPossible() -> Bool {
        guard let last = lastAutocorrection else { return false }
        lastAutocorrection = nil
        guard documentContextBeforeInput()?.hasSuffix(last.corrected + last.suffix) == true else { return false }
        for _ in 0..<(last.corrected.count + last.suffix.count) { deleteBackward() }
        insertText(last.original)
        languageModel.learn(last.original, script: script)
        return true
    }

    private func commitTap(_ text: String) {
        insertCharacter(text)
        keyFeedback(.character)
        if shifted && !capsLock { shifted = false }
        maybeAutoShift()
        updateTypingSuggestions()
    }

    /// Вставляет лучшее слово под траекторию свайпа; остальные варианты — в
    /// панели подсказок (выбор заменит вставленное слово).
    private func commitSwipe(points: [CGPoint], geometry: SwipeKeyboardGeometry) {
        // Предыдущее слово (если курсор после пробела) подсказывает вероятное следующее.
        let before = documentContextBeforeInput() ?? ""
        let previous = currentWordPrefix(in: String(before.reversed().drop { $0 == " " }.reversed()))
        let likelyNext = previous.isEmpty || !before.hasSuffix(" ") ? [] : Set(
            languageModel.nextWords(after: previous, script: script, limit: 4)
                .map { $0.lowercased(with: script.caseLocale) })
        let results = SwipeTyping.suggestions(points: points, geometry: geometry, script: script,
                                              likelyNext: likelyNext)
            .map(applyShiftCase)
        guard let top = results.first else { return }
        // Как в Gboard: слово, начатое вплотную к предыдущему, отделяем пробелом.
        if let last = before.last, !last.isWhitespace, !"([«\"„“'".contains(last) {
            insertText(" ")
        }
        insertText(top + " ")
        keyFeedback(.character)
        if shifted && !capsLock { shifted = false }
        lastAutocorrection = nil
        autoSpaceInserted = true
        suggestionSource = .swipe(insertedWord: top)
        suggestions = results
        literalSuggestion = nil
        maybeAutoShift()
    }

    /// Регистр слова из словаря под текущее состояние Shift / Caps Lock.
    private func applyShiftCase(_ word: String) -> String {
        guard script.supportsShift else { return word }
        let locale = script.caseLocale
        if capsLock { return word.uppercased(with: locale) }
        if shifted { return word.prefix(1).uppercased(with: locale) + word.dropFirst() }
        return word
    }

    /// Предиктивный набор (аналог QuickType). Пока слово набирается: первым
    /// идёт набранное «как есть», затем замена текста iOS или исправление
    /// автозамены (оно же применится по пробелу), затем продолжения слова из
    /// TatarLanguageModel. После пробела — предсказание следующего слова.
    private func updateTypingSuggestions() {
        guard mode == .letters, digitPadKind == nil, !context.isSecureTextEntry else { clearSuggestions(); return }
        let before = documentContextBeforeInput() ?? ""
        let prefix = currentWordPrefix(in: before)
        guard !prefix.isEmpty else { updatePredictions(before: before); return }

        var items = languageModel.completions(forPrefix: prefix, script: script, limit: 3)
            .map { matchCase($0, to: prefix) }
        if isAutocorrectEnabled, let correction = languageModel.correction(for: prefix, script: script) {
            items.insert(matchCase(correction, to: prefix), at: 0)
        }
        if let replacement = context.textReplacements[prefix.lowercased()] {
            items.insert(replacement, at: 0)
        }
        var seen: Set<String> = [prefix]
        items = items.filter { seen.insert($0).inserted }
        guard !items.isEmpty else { clearSuggestions(); return }

        suggestions = Array(([prefix] + items).prefix(3))
        literalSuggestion = prefix
        suggestionSource = .typing(prefixLength: prefix.count)
    }

    /// Следующее слово: по предыдущему слову, а в начале текста/предложения —
    /// частые первые слова. Регистр — по текущему состоянию Shift.
    private func updatePredictions(before: String) {
        guard script != .arabic, languageModel.isLoaded,
              context.keyboardType != .emailAddress, context.keyboardType != .URL else { clearSuggestions(); return }
        let trimmed = before.reversed().drop { $0 == " " }
        let words: [String]
        if trimmed.isEmpty || trimmed.first.map({ ".!?\n".contains($0) }) == true {
            // Начало текста/предложения — только если после знака уже есть пробел или перевод строки.
            guard before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n") else { clearSuggestions(); return }
            words = languageModel.nextWords(after: nil, script: script, limit: 3)
        } else if before.hasSuffix(" "), let first = trimmed.first, first.isLetter {
            let previous = currentWordPrefix(in: String(trimmed.reversed()))
            words = languageModel.nextWords(after: previous, script: script, limit: 3)
        } else {
            words = []
        }
        guard !words.isEmpty else { clearSuggestions(); return }
        suggestions = words.map(applyShiftCase)
        literalSuggestion = nil
        suggestionSource = .prediction
    }

    /// Словарь хранит слова в нижнем регистре — подгоняем под набранное
    /// («Та» → «Татар», «ТА» → «ТАТАР»).
    private func matchCase(_ word: String, to typed: String) -> String {
        guard let first = typed.first, first.isUppercase else { return word }
        let locale = script.caseLocale
        if typed.count > 1, typed.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return word.uppercased(with: locale)
        }
        return word.prefix(1).uppercased(with: locale) + word.dropFirst()
    }

    /// Последовательность буквенных символов от конца строки до ближайшей
    /// границы слова (пробел, знак препинания, начало текста).
    private func currentWordPrefix(in text: String) -> String {
        var result: [Character] = []
        for ch in text.reversed() {
            guard ch.isLetter else { break }
            result.append(ch)
        }
        return String(result.reversed())
    }

    private func acceptSuggestion(_ word: String) {
        guard let source = suggestionSource else { return }
        switch source {
        case .typing(let prefixLength):
            for _ in 0..<prefixLength { deleteBackward() }
        case .swipe(let insertedWord):
            for _ in 0..<(insertedWord.count + 1) { deleteBackward() } // +1 — автопробел после слова
        case .prediction:
            break
        }
        // Выбрали слово «как есть» — значит, оно правильное, больше не исправляем.
        if word == literalSuggestion { languageModel.learn(word, script: script) }
        lastAutocorrection = nil
        insertText(word + " ")
        keyFeedback(.character)
        clearSuggestions()
        autoSpaceInserted = true
        maybeAutoShift()
        updateTypingSuggestions()
    }

    private func clearSuggestions() {
        suggestions = []
        suggestionSource = nil
        literalSuggestion = nil
    }

    // MARK: - Страницы 123 / #+=

    private func punctuationPad(rows: [[KeyDefinition]], toggleLabel: String, toggleTarget: Mode) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 5) {
                    if index == rows.count - 1 {
                        Button {
                            keyFeedback(.modifier)
                            switchMode(toggleTarget)
                        } label: {
                            Text(toggleLabel)
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(TatarKeyStyle())
                    }
                    ForEach(Array(row.enumerated()), id: \.element.id) { keyIndex, key in
                        KeyButton(title: key.main, alts: key.alts,
                                  opensToLeft: keyIndex >= row.count / 2, swipeState: swipeState) { text in
                            insertCharacter(text)
                            keyFeedback(.character)
                            maybeAutoShift()
                        }
                    }
                    if index == rows.count - 1 {
                        deleteKey()
                    }
                }
            }
            bottomRow(leftLabel: "ABC", leftAction: { switchMode(.letters) })
        }
    }

    // MARK: - Страница эмодзи
    //
    // ВАЖНО: раньше здесь был непрерывный ScrollView с ScrollViewReader, где все
    // ~9 категорий (местами по 150-250 эмодзи каждая, то есть суммарно больше
    // тысячи Text-вьюх) лежали в одном LazyVStack. У сторонних клавиатур очень
    // жёсткий лимит памяти на процесс — при быстром скролле система успевала
    // запросить измерение/рендер гораздо большего числа ячеек, чем помещается в
    // лимит, и процесс падал. ScrollViewReader.scrollTo() дополнительно мешает
    // LazyVStack оставаться по-настоящему ленивым (ему нужно знать позиции
    // якорей). Заодно это и была причина, почему подсветка категории не
    // успевала синхронизироваться со скроллом — не было отслеживания текущей
    // видимой секции.
    //
    // Возврат к постраничному показу (один Grid — одна категория) полностью
    // убирает обе проблемы: одновременно в памяти только эмодзи ТЕКУЩЕЙ
    // категории (максимум ~250 ячеек одного плоского LazyVGrid, который
    // виртуализируется нормально), а подсветка категории — это просто то, что
    // выбрано кнопкой, рассинхронизации в принципе быть не может.
    private var emojiPad: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                    ForEach(currentEmojis, id: \.self) { emoji in
                        Button {
                            insertText(emoji)
                            keyFeedback(.character)
                            // На странице «Недавние» список не перестраиваем прямо под
                            // пальцем — он обновится при следующем открытии категории.
                            let updated = RecentEmoji.record(emoji)
                            if emojiCategoryIndex != 0 { recentEmojis = updated }
                        } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            // Сетка занимает место панели подсказок + букв, чтобы нижний ряд
            // (ABC / категории / ⌫) стоял ровно там же, где нижний ряд букв.
            .frame(height: suggestionBarHeight + 8 + letterPadHeight)

            // Нижний ряд: ABC | категории эмодзи | Backspace (как в стандартной клавиатуре iOS)
            HStack(spacing: 5) {
                Button {
                    keyFeedback(.modifier)
                    switchMode(.letters)
                } label: {
                    Text("ABC")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(TatarKeyStyle())

                if context.needsInputModeSwitchKey {
                    globeKey(width: 36)
                }

                HStack(spacing: 1) {
                    ForEach(Array(emojiCategoryTabs.enumerated()), id: \.offset) { index, tab in
                        Button {
                            if index == 0 { recentEmojis = RecentEmoji.load() }
                            emojiCategoryIndex = index
                            keyFeedback(.modifier)
                        } label: {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15))
                                .foregroundColor(emojiCategoryIndex == index ? .primary : .secondary.opacity(0.6))
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(emojiCategoryIndex == index ? Color.keyboardSpecialKeyPressed : Color.clear)
                                )
                                // Без этого зона нажатия ограничивается видимыми
                                // пикселями иконки (мелкая, 15pt) вместо всего
                                // выделенного под кнопку места — отсюда и жалоба
                                // «сложно попасть пальцем».
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.title)
                    }
                }
                .frame(maxWidth: .infinity)

                deleteKey()
                    .frame(width: 42, height: 42)
            }
        }
    }

    /// Вкладки категорий: первая — «Недавние», дальше — категории EmojiData.
    private var emojiCategoryTabs: [(icon: String, title: String)] {
        [("clock", "Недавние")] + EmojiData.categories.map { ($0.symbolIcon, $0.title) }
    }

    private var currentEmojis: [String] {
        emojiCategoryIndex == 0 ? recentEmojis : EmojiData.categories[emojiCategoryIndex - 1].emojis
    }

    private func openEmojiPad() {
        keyFeedback(.modifier)
        recentEmojis = RecentEmoji.load()
        // Пока недавних нет — открываем сразу смайлы, а не пустую страницу.
        if emojiCategoryIndex == 0 && recentEmojis.isEmpty { emojiCategoryIndex = 1 }
        switchMode(.emoji)
    }

    // MARK: - Цифровая панель (.numberPad / .decimalPad / .phonePad)

    private func digitPad(_ kind: DigitPadKind) -> some View {
        VStack(spacing: 6) {
            ForEach(TatarLayout.digitPadRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { digit in
                        digitKey(digit)
                    }
                }
            }
            HStack(spacing: 6) {
                switch kind {
                case .digits:
                    if context.needsInputModeSwitchKey {
                        globeKey(width: nil, height: digitKeyHeight, iconSize: 20)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, minHeight: digitKeyHeight)
                    }
                case .decimal:
                    digitKey(Locale.current.decimalSeparator ?? ".")
                case .phone:
                    digitKey("+", alts: ["*", "#", ",", ";"])
                }
                digitKey("0")
                deleteKey(height: digitKeyHeight)
            }
        }
    }

    private func digitKey(_ digit: String, alts: [String] = []) -> some View {
        KeyButton(title: digit, alts: alts, showsAltHint: !alts.isEmpty,
                  height: digitKeyHeight, fontSize: 26, showsPopup: false, swipeState: swipeState) { text in
            insertText(text)
            keyFeedback(.character)
        }
    }

    // MARK: - Общие элементы (Shift, Backspace, нижний ряд)

    /// Как в iOS: тап — Shift на одну букву, двойной тап — Caps Lock, тап при Caps Lock — выкл.
    private var shiftKey: some View {
        Button {
            let now = Date()
            if capsLock {
                capsLock = false; shifted = false
                lastShiftTapTime = nil
            } else if let last = lastShiftTapTime, now.timeIntervalSince(last) < 0.3 {
                capsLock = true; shifted = true
                lastShiftTapTime = nil
            } else {
                shifted.toggle()
                lastShiftTapTime = now
            }
            keyFeedback(.modifier)
        } label: {
            Image(systemName: capsLock ? "capslock.fill" : (shifted ? "shift.fill" : "shift"))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(TatarKeyStyle(isCharacterKey: shifted || capsLock))
        .accessibilityLabel(capsLock ? "Caps Lock" : "Shift")
        .accessibilityAddTraits(shifted || capsLock ? .isSelected : [])
    }

    private func deleteKey(height: CGFloat = 42) -> some View {
        DeleteKeyButton(height: height, action: {
            if !undoAutocorrectionIfPossible() { deleteBackward() }
            afterDelete()
        }, wordAction: {
            deleteWordBackward()
            afterDelete()
        })
        .frame(maxWidth: .infinity, minHeight: height)
    }

    private func afterDelete() {
        autoSpaceInserted = false
        keyFeedback(.delete)
        maybeAutoShift()
        updateTypingSuggestions()
    }

    /// Удаляет пробелы перед курсором и затем одно «слово» — подряд идущие
    /// буквы/цифры либо подряд идущие прочие символы.
    private func deleteWordBackward() {
        let chars = Array(documentContextBeforeInput() ?? "")
        var count = 0
        var i = chars.count - 1
        while i >= 0, chars[i].isWhitespace { count += 1; i -= 1 }
        if i >= 0 {
            let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            let kind = isWordChar(chars[i])
            while i >= 0, !chars[i].isWhitespace, isWordChar(chars[i]) == kind { count += 1; i -= 1 }
        }
        for _ in 0..<max(count, 1) { deleteBackward() }
    }

    /// Системная кнопка 🌐 — переключает между установленными В СИСТЕМЕ
    /// клавиатурами, а при удержании показывает их список (handleInputModeList).
    private func globeKey(width: CGFloat?, height: CGFloat = 42, iconSize: CGFloat = 18) -> some View {
        Image(systemName: "globe")
            .font(.system(size: iconSize))
            .accessibilityHidden(true)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.keyboardSpecialKeyBackground)
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            .overlay(InputModeSwitchKey(handler: handleInputModeList))
    }

    private func bottomRow(leftLabel: String, leftAction: @escaping () -> Void, extraKeys: [KeyDefinition] = []) -> some View {
        HStack(spacing: 5) {
            Button {
                keyFeedback(.modifier)
                leftAction()
            } label: {
                Text(leftLabel)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(TatarKeyStyle())

            if context.needsInputModeSwitchKey {
                globeKey(width: 36)
            }

            // Для e-mail/URL место у пробела отдаём под @ . / — эмодзи там почти не нужны.
            if extraKeys.count < 2 {
                Button {
                    openEmojiPad()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 42)
                }
                .buttonStyle(TatarKeyStyle())
                .accessibilityLabel("Эмодзи")
            }

            // Доп. кнопка рядом с пробелом — переключает НАШИ ТРИ письменности
            // (кириллица → латиница → арабица → ...). Специально другая иконка,
            // не 🌐 — чтобы не путать с системной кнопкой переключения приложений-
            // клавиатур, которая стоит вплотную слева.
            Button {
                keyFeedback(.modifier)
                cycleScript()
            } label: {
                Image(systemName: "textformat.alt")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 42)
            }
            .buttonStyle(TatarKeyStyle())
            .accessibilityLabel("Письменность: \(script.switchLabel)")

            // Кнопка пробела: без надписи, как в стандартной клавиатуре iOS,
            // забирает всё свободное пространство по центру. Удержание или
            // горизонтальный сдвиг пальца — трекпад для курсора.
            SpaceKeyButton(
                isRTL: mode == .letters && script.isRTL,
                isCursorMode: $isCursorMode,
                onTap: handleSpaceTap,
                onCursorModeStart: { keyFeedback(.cursorMode) },
                onMoveCursor: { offset in
                    moveCursor(offset)
                    autoSpaceInserted = false
                    clearSuggestions()
                }
            )

            ForEach(Array(extraKeys.enumerated()), id: \.element.id) { index, key in
                KeyButton(title: key.main, alts: key.alts, opensToLeft: index == extraKeys.count - 1,
                          fontSize: 20, swipeState: swipeState) { text in
                    insertCharacter(text)
                    keyFeedback(.character)
                    maybeAutoShift()
                    updateTypingSuggestions()
                }
                .frame(width: 34)
            }

            returnKey
        }
    }

    /// Динамическая Return: синяя для действий (Найти/Отправить...), серая для
    /// обычного перевода строки и неактивная в пустом поле, если поле так просит.
    private var returnKey: some View {
        let isDisabled = context.enablesReturnKeyAutomatically && !context.hasText
        return Button {
            autoSpaceInserted = false
            lastAutocorrection = nil
            applyAutocorrectionIfNeeded(suffix: "\n")
            insertText("\n")
            keyFeedback(.modifier)
            maybeAutoShift()
            updateTypingSuggestions()
        } label: {
            Text(context.returnKeyType.label(for: script))
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(isDisabled ? .secondary : nil)
                .frame(minWidth: 64, maxWidth: 76, minHeight: 42)
        }
        .buttonStyle(TatarKeyStyle(tinted: !isDisabled && context.returnKeyType.isProminent))
        .disabled(isDisabled)
    }

    // MARK: - Двойной пробел → «. »

    private func handleSpaceTap() {
        let now = Date()
        if let last = lastSpaceTapTime, now.timeIntervalSince(last) < 0.35,
           let before = documentContextBeforeInput(), before.hasSuffix(" "),
           let previous = before.dropLast().last, previous.isLetter {
            deleteBackward()
            insertText(". ")
            lastSpaceTapTime = nil
        } else {
            lastAutocorrection = nil
            // Сначала замена текста iOS (это намеренное сокращение), иначе — автозамена.
            if !applyTextReplacementIfNeeded() {
                applyAutocorrectionIfNeeded(suffix: " ")
            }
            insertText(" ")
            lastSpaceTapTime = now
        }
        keyFeedback(.modifier)
        autoSpaceInserted = false
        // Как в iOS: пробел на странице 123/#+= возвращает к буквам.
        if (mode == .numbers || mode == .symbols) && context.keyboardType != .numbersAndPunctuation {
            switchMode(.letters)
        }
        maybeAutoShift()
        updateTypingSuggestions()
    }

    /// Замена текста iOS: сокращение перед курсором (до пробела) меняется на фразу.
    @discardableResult
    private func applyTextReplacementIfNeeded() -> Bool {
        guard !context.isSecureTextEntry, !context.textReplacements.isEmpty,
              let before = documentContextBeforeInput() else { return false }
        let token = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !token.isEmpty, let replacement = context.textReplacements[token.lowercased()] else { return false }
        for _ in 0..<token.count { deleteBackward() }
        insertText(replacement)
        return true
    }

    // MARK: - Автозаглавные буквы

    private func maybeAutoShift() {
        guard mode == .letters, script.supportsShift, !capsLock else { return }
        switch context.autocapitalizationType {
        case .none:
            shifted = false
        case .allCharacters:
            shifted = true
        case .words:
            let before = documentContextBeforeInput() ?? ""
            shifted = before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n")
        case .sentences:
            let before = documentContextBeforeInput() ?? ""
            if before.isEmpty || before.hasSuffix("\n") {
                shifted = true
            } else if before.hasSuffix(" ") {
                let trimmed = before.reversed().drop(while: { $0 == " " })
                shifted = trimmed.first.map { ".!?".contains($0) } ?? false
            } else {
                shifted = false
            }
        @unknown default:
            shifted = false
        }
    }
}

// MARK: - Пузырь с увеличенной буквой при нажатии (имитация системной клавиатуры)

/// Размеры всплывающих окон над клавишей. Расширение клавиатуры iOS обрезает
/// всё, что выходит за его верхний край, а над верхним рядом букв всего 44pt
/// (6 отступ + 30 панель подсказок + 8 промежуток) — пузырь и лента вариантов
/// обязаны в них помещаться, поэтому стоят вплотную к клавише (зазор 2pt).
private enum KeyPopupLayout {
    static let gap: CGFloat = 2
    static let bubbleHeight: CGFloat = 40
    static let stripCellHeight: CGFloat = 38
    static let stripPadding: CGFloat = 2
    static var bubbleOffset: CGFloat { -(bubbleHeight + gap) }
    static var stripOffset: CGFloat { -(stripCellHeight + 2 * stripPadding + gap) }
}

private struct KeyPopupBubble: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .regular))
            .foregroundColor(.primary)
            .frame(width: 36, height: KeyPopupLayout.bubbleHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.keyboardBubbleBackground)
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
    }
}

// MARK: - Лента вариантов по долгому нажатию (как «е → ё», «- → – —» в iOS)

private struct AlternatesStrip: View {
    let alts: [String]
    let selectedIndex: Int
    let cellWidth: CGFloat
    /// true — лента растёт влево от клавиши (для клавиш у правого края),
    /// первый вариант при этом остаётся над самой клавишей.
    let opensToLeft: Bool

    var body: some View {
        let order = opensToLeft ? Array(alts.indices.reversed()) : Array(alts.indices)
        HStack(spacing: 0) {
            ForEach(order, id: \.self) { index in
                Text(alts[index])
                    .font(.system(size: alts[index].count > 1 ? 17 : 22))
                    .lineLimit(1)
                    .foregroundColor(index == selectedIndex ? .white : .primary)
                    .frame(width: cellWidth, height: KeyPopupLayout.stripCellHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(index == selectedIndex ? Color.accentColor : Color.clear)
                    )
            }
        }
        .padding(KeyPopupLayout.stripPadding)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.keyboardBubbleBackground)
                .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
        )
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Клавиша буквы/символа с долгим нажатием (варианты) и защитой от свайпа

private struct KeyButton: View {
    let title: String
    var alts: [String] = []
    /// Подписывать ли первый вариант мелко в углу (на буквенных клавишах — да).
    var showsAltHint: Bool = false
    var opensToLeft: Bool = false
    var height: CGFloat = 42
    var fontSize: CGFloat = 22
    /// Пузырь с крупным символом при нажатии (на цифровой панели его нет, как в iOS).
    var showsPopup: Bool = true
    @ObservedObject var swipeState: SwipeState
    let onInsert: (String) -> Void

    @State private var isPressed = false
    /// true — удержание превысило altRevealDelay и лента вариантов открыта.
    @State private var isAltRevealed = false
    @State private var selectedAltIndex = 0
    /// Номер текущего касания: отложенное «раскрытие» от прошлого быстрого
    /// тапа не должно сработать на следующем.
    @State private var pressToken = 0

    /// Через сколько секунд удержания открывается лента вариантов.
    private let altRevealDelay: TimeInterval = 0.35

    private var altCellWidth: CGFloat { alts.contains { $0.count > 1 } ? 50 : 30 }

    var body: some View {
        Text(title)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPressed ? Color.keyboardKeyBackgroundPressed : Color.keyboardKeyBackground)
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                if showsAltHint, let alt = alts.first {
                    Text(alt)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(3)
                }
            }
            // Короткий тап — пузырь с крупным символом и вставка основного символа.
            // Удержание — лента вариантов: палец ведётся влево/вправо, при
            // отпускании вставляется подсвеченный вариант.
            .overlay(alignment: .top) {
                // Во время свайпа пузырь не показываем — палец уже ушёл с клавиши.
                if showsPopup && isPressed && !isAltRevealed && !swipeState.isActive {
                    KeyPopupBubble(title: title)
                        .offset(y: KeyPopupLayout.bubbleOffset)
                        .allowsHitTesting(false)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5, anchor: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .overlay(alignment: opensToLeft ? .topTrailing : .topLeading) {
                if isPressed && isAltRevealed {
                    AlternatesStrip(alts: alts, selectedIndex: selectedAltIndex,
                                    cellWidth: altCellWidth, opensToLeft: opensToLeft)
                        .fixedSize()
                        .offset(y: KeyPopupLayout.stripOffset)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .zIndex(isPressed ? 10 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressed {
                            swipeState.beginTouch()
                            isPressed = true
                            isAltRevealed = false
                            selectedAltIndex = 0
                            pressToken &+= 1
                            let token = pressToken
                            if !alts.isEmpty {
                                DispatchQueue.main.asyncAfter(deadline: .now() + altRevealDelay) {
                                    // Палец уже отпущен (или это другое касание) — ничего не делаем.
                                    guard isPressed, token == pressToken, !swipeState.isActive else { return }
                                    isAltRevealed = true
                                    // Дальше сдвиг пальца выбирает вариант, а не рисует свайп.
                                    swipeState.isSuppressed = true
                                }
                            }
                        }
                        guard isAltRevealed else { return }
                        let dx = opensToLeft ? -value.translation.width : value.translation.width
                        let index = Int(((dx + altCellWidth / 2) / altCellWidth).rounded(.down))
                        selectedAltIndex = min(max(index, 0), alts.count - 1)
                    }
                    .onEnded { _ in
                        defer {
                            isPressed = false
                            isAltRevealed = false
                            selectedAltIndex = 0
                        }
                        // Если жест распознан как свайп через несколько букв — слово
                        // уже вставлено в commitSwipe(), обычную вставку пропускаем.
                        guard !swipeState.isActive else { return }
                        if isAltRevealed, alts.indices.contains(selectedAltIndex) {
                            onInsert(alts[selectedAltIndex])
                        } else {
                            onInsert(title)
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAction { onInsert(title) }
            .accessibilityActions {
                ForEach(alts, id: \.self) { alt in
                    Button(alt) { onInsert(alt) }
                }
            }
    }
}

// MARK: - Пробел: тап — пробел, удержание/сдвиг — трекпад для курсора (как в iOS)

private struct SpaceKeyButton: View {
    /// В RTL (арабица) движение пальца вправо — это движение назад по тексту.
    let isRTL: Bool
    @Binding var isCursorMode: Bool
    let onTap: () -> Void
    let onCursorModeStart: () -> Void
    /// Смещение курсора в символах (положительное — вперёд по тексту).
    let onMoveCursor: (Int) -> Void

    @State private var isPressed = false
    @State private var anchorX: CGFloat = 0
    @State private var pressToken = 0

    private let longPressDelay: TimeInterval = 0.45
    private let dragActivationDistance: CGFloat = 14
    private let pointsPerCharacter: CGFloat = 9

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPressed ? Color.keyboardKeyBackgroundPressed : Color.keyboardKeyBackground)
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            .contentShape(Rectangle())
            // Глобальные координаты не зеркалятся в RTL-раскладке — направление
            // сдвига всегда «физическое», а для RTL его разворачиваем сами.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isPressed {
                            isPressed = true
                            anchorX = value.location.x
                            pressToken &+= 1
                            let token = pressToken
                            DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay) {
                                guard isPressed, token == pressToken, !isCursorMode else { return }
                                startCursorMode()
                            }
                        }
                        if !isCursorMode, abs(value.location.x - value.startLocation.x) > dragActivationDistance {
                            startCursorMode()
                            anchorX = value.location.x
                        }
                        guard isCursorMode else { return }
                        let steps = Int((value.location.x - anchorX) / pointsPerCharacter)
                        if steps != 0 {
                            onMoveCursor(isRTL ? -steps : steps)
                            anchorX += CGFloat(steps) * pointsPerCharacter
                        }
                    }
                    .onEnded { _ in
                        if !isCursorMode { onTap() }
                        isPressed = false
                        isCursorMode = false
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Пробел")
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAction { onTap() }
    }

    private func startCursorMode() {
        isCursorMode = true
        onCursorModeStart()
    }
}

// MARK: - Кнопка 🌐 через UIKit: handleInputModeList требует UIView и UIEvent

private struct InputModeSwitchKey: UIViewRepresentable {
    let handler: (UIView, UIEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.handle(_:event:)), for: .allTouchEvents)
        button.accessibilityLabel = "Следующая клавиатура"
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.handler = handler
    }

    final class Coordinator: NSObject {
        var handler: (UIView, UIEvent) -> Void

        init(handler: @escaping (UIView, UIEvent) -> Void) {
            self.handler = handler
        }

        @objc func handle(_ sender: UIButton, event: UIEvent) {
            handler(sender, event)
        }
    }
}

// MARK: - Backspace с автоповтором при удержании (как в системной клавиатуре)

private struct DeleteKeyButton: View {
    var height: CGFloat = 42
    let action: () -> Void
    /// Удаление целого слова — включается после долгого удержания.
    let wordAction: () -> Void

    @State private var isPressed = false
    @State private var timer: Timer?
    @State private var heldDuration: TimeInterval = 0

    var body: some View {
        Image(systemName: "delete.left.fill")
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPressed ? Color.keyboardSpecialKeyPressed : Color.keyboardSpecialKeyBackground)
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            .scaleEffect(isPressed ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        heldDuration = 0
                        action() // мгновенное удаление по нажатию
                        // Первый повтор — после короткой паузы, чтобы не удалить
                        // лишнее при обычном тапе.
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            startRepeating()
                        }
                    }
                    .onEnded { _ in
                        stop()
                    }
            )
            // Страница могла смениться прямо под пальцем — не оставляем таймер жить.
            .onDisappear { stop() }
            .accessibilityElement()
            .accessibilityLabel("Удалить")
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAction { action() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isPressed = false
    }

    private func startRepeating() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { charTimer in
            heldDuration += 0.1
            action()
            // Как в системной клавиатуре: после ~1.5с удержания удаляем уже целыми словами.
            if heldDuration > 1.5 {
                charTimer.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in wordAction() }
            }
        }
    }
}

private extension UIReturnKeyType {
    /// Синяя кнопка — для «действий»; обычный перевод строки и «Далее» — серые, как в iOS.
    var isProminent: Bool {
        switch self {
        case .default, .next, .continue: return false
        default: return true
        }
    }
}

// MARK: - Общий стиль служебных клавиш (123, ABC, globe, return...)

private struct TatarKeyStyle: ButtonStyle {
    var tinted: Bool = false
    var isCharacterKey: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let normalColor = isCharacterKey ? Color.keyboardKeyBackground : Color.keyboardSpecialKeyBackground
        let pressedColor = isCharacterKey ? Color.keyboardKeyBackgroundPressed : Color.keyboardSpecialKeyPressed

        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tinted ? Color.accentColor.opacity(configuration.isPressed ? 0.6 : 1.0)
                                 : (configuration.isPressed ? pressedColor : normalColor))
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            .foregroundColor(tinted ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Системные цвета клавиш в стиле iOS (светлая / тёмная тема)

private extension Color {
    static let keyboardKeyBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.30)
            : UIColor.white
    })

    static let keyboardKeyBackgroundPressed = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.50)
            : UIColor(white: 0.82, alpha: 1.0)
    })

    static let keyboardSpecialKeyBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.16)
            : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1.0)
    })

    static let keyboardSpecialKeyPressed = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.35)
            : UIColor(white: 1.0, alpha: 1.0)
    })

    static let keyboardKeyShadow = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.clear
            : UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.35)
    })
    
    static let keyboardBubbleBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.38, alpha: 1.0)
            : UIColor.white                       
    })
}

// MARK: - След пальца при свайпе

private struct SwipeTrailView: View {
    @ObservedObject var trail: SwipeTrail

    var body: some View {
        Path { path in
            guard let first = trail.points.first else { return }
            path.move(to: first)
            for point in trail.points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(Color.accentColor.opacity(0.55),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }
}
