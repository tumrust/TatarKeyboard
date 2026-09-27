//
//  KeyboardRootView.swift
//  TatarKeyboardExtension
//
//  Визуальный слой клавиатуры: буквы (кириллица/латиница/арабица), страницы
//  123 / #+= / эмодзи, динамическая кнопка Return, автозаглавные, повтор
//  Backspace при удержании, двойной пробел → точка, доп. переключатель
//  письменности у пробела, свайп-ввод и предиктивные подсказки слов
//  (по FrequencyDictionary, с адаптацией под кириллицу/латиницу), плюс
//  тактильный отклик по нажатиям (требует Full Access).
//

import SwiftUI
import UIKit

struct KeyboardRootView: View {

    // MARK: Зависимости от KeyboardViewController

    @ObservedObject var context: KeyboardContext
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    /// Текст непосредственно перед курсором — нужен для автозаглавных, для
    /// правила «двойной пробел → точка» и для предиктивных подсказок (какое
    /// слово сейчас набирается).
    let documentContextBeforeInput: () -> String?
    let advanceToNextInputMode: () -> Void
    /// no-op, если Full Access не выдан (проверяется в KeyboardViewController).
    let hapticFeedback: (UIImpactFeedbackGenerator.FeedbackStyle) -> Void

    private enum Mode { case letters, numbers, symbols, emoji }

    /// Откуда взялись текущие предложенные слова — важно знать, сколько
    /// символов удалить при принятии другого варианта.
    private enum SuggestionSource {
        case typing(prefixLength: Int)
        case swipe(insertedWord: String)
    }

    @State private var script: TatarScript = .cyrillic
    @State private var mode: Mode = .letters
    @State private var shifted = false
    @State private var capsLock = false
    @State private var lastSpaceTapTime: Date?
    @State private var emojiCategoryIndex = 0

    @State private var suggestions: [String] = []
    @State private var suggestionSource: SuggestionSource?
    private let swipeState = SwipeState()

    /// Свайп-ввод пока выключен: на практике словарь на 70 слов почти никогда
    /// не находил совпадение, и палец просто вставлял «сырые» буквы под
    /// траекторией — выглядело как баг. Поиск слова теперь берёт данные из
    /// большого FrequencyDictionary (850 слов, кириллица+латиница), что должно
    /// сильно поднять точность — но это ещё не проверено на устройстве.
    /// Поставьте true, чтобы попробовать; вся логика (жест, хит-тест, панель
    /// подсказок) остаётся рабочей и не требует других правок.
    private let isSwipeTypingEnabled = false

    private let letterPadHeight: CGFloat = 3 * 42 + 2 * 8 // 3 ряда по 42pt + 2 промежутка по 8pt

    var body: some View {
        VStack(spacing: 8) {
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
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .environment(\.layoutDirection, (mode == .letters && script.isRTL) ? .rightToLeft : .leftToRight)
        .background(Color.clear)
        .onAppear { maybeAutoShift() }
    }

    // MARK: - Панель предложений: и предиктивный набор, и результат свайпа

    private var suggestionBar: some View {
        HStack(spacing: 0) {
            if mode == .letters && !suggestions.isEmpty {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, word in
                    Button {
                        acceptSuggestion(word)
                    } label: {
                        Text(word)
                            .font(.system(size: 15, weight: index == 0 ? .semibold : .regular))
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
        .frame(height: 30)
    }

    // MARK: - Переключение письменности (без визуальной панели — см. кнопку у пробела)

    private func selectScript(_ candidate: TatarScript) {
        script = candidate
        shifted = false
        capsLock = false
        clearSuggestions()
        maybeAutoShift()
    }

    private func cycleScript() {
        let all = TatarScript.allCases
        let idx = all.firstIndex(of: script) ?? 0
        selectScript(all[(idx + 1) % all.count])
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
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 5) {
                            if index == rows.count - 1 && script.supportsShift {
                                shiftKey
                            }
                            ForEach(row) { key in
                                KeyButton(title: key.main, alt: key.alt, swipeState: swipeState) { text in
                                    commitTap(text)
                                }
                            }
                            if index == rows.count - 1 {
                                deleteKey
                            }
                        }
                    }
                }
                // Свайп-ввод: собираем буквы, над которыми проходит палец, простым
                // геометрическим хит-тестом (см. SwipeHitTesting). Работает
                // одновременно с обычными нажатиями по клавишам благодаря
                // simultaneousGesture — не мешает короткому тапу.
                // Для арабицы (RTL) отключено — см. комментарий в SwipeTyping.swift.
                // Сейчас выключено флагом isSwipeTypingEnabled — см. его комментарий.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { value in
                            guard isSwipeTypingEnabled, !script.isRTL else { return }
                            if let letter = SwipeHitTesting.letter(at: value.location, in: proxy.size, rows: rows, script: script) {
                                swipeState.append(letter)
                            }
                        }
                        .onEnded { _ in
                            defer { swipeState.reset() }
                            guard isSwipeTypingEnabled, !script.isRTL else { return }
                            if swipeState.isActive {
                                commitSwipe(path: swipeState.path)
                            }
                        }
                )
            }
            .frame(height: letterPadHeight)

            bottomRow(leftLabel: "123", leftAction: { switchMode(.numbers) }, showEmojiButton: true)
        }
    }

    private func commitTap(_ text: String) {
        insertText(text)
        hapticFeedback(.light)
        if shifted && !capsLock { shifted = false }
        maybeAutoShift()
        updateTypingSuggestions()
    }

    private func commitSwipe(path: [String]) {
        guard path.count >= 2 else { return }
        let results = SwipeTyping.suggestions(forPath: path, script: script)
        guard let top = results.first else { return }
        insertText(top + " ")
        hapticFeedback(.medium)
        suggestionSource = .swipe(insertedWord: top)
        suggestions = results
        maybeAutoShift()
    }

    /// Предиктивный набор: смотрит, какие буквы уже набраны с начала текущего
    /// слова, и подбирает из FrequencyDictionary слова с таким началом,
    /// отсортированные по частоте — отдельно для кириллицы и латиницы
    /// (Neo-әlif), поле выбирается по текущей письменности.
    private func updateTypingSuggestions() {
        guard mode == .letters else { clearSuggestions(); return }
        let before = documentContextBeforeInput() ?? ""
        let prefix = currentWordPrefix(in: before)
        guard !prefix.isEmpty else { clearSuggestions(); return }

        let matches = FrequencyDictionary.suggestions(forPrefix: prefix, script: script, limit: 3)
        if matches.isEmpty {
            clearSuggestions()
        } else {
            suggestions = matches
            suggestionSource = .typing(prefixLength: prefix.count)
        }
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
        }
        insertText(word + " ")
        hapticFeedback(.light)
        clearSuggestions()
        maybeAutoShift()
    }

    private func clearSuggestions() {
        suggestions = []
        suggestionSource = nil
    }

    // MARK: - Страницы 123 / #+=

    private func punctuationPad(rows: [[KeyDefinition]], toggleLabel: String, toggleTarget: Mode) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 5) {
                    if index == rows.count - 1 {
                        Button {
                            switchMode(toggleTarget)
                        } label: {
                            Text(toggleLabel)
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(TatarKeyStyle())
                    }
                    ForEach(row) { key in
                        KeyButton(title: key.main, alt: key.alt, swipeState: swipeState) { text in
                            insertText(text)
                            hapticFeedback(.light)
                            maybeAutoShift()
                        }
                    }
                    if index == rows.count - 1 {
                        deleteKey
                    }
                }
            }
            bottomRow(leftLabel: "ABC", leftAction: { switchMode(.letters) }, showEmojiButton: true)
        }
    }

    // MARK: - Страница эмодзи

    private var emojiPad: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 8) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(EmojiData.categories) { category in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)

                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                                    ForEach(category.emojis, id: \.self) { emoji in
                                        Button {
                                            insertText(emoji)
                                            hapticFeedback(.light)
                                        } label: {
                                            Text(emoji)
                                                .font(.system(size: 28))
                                                .frame(maxWidth: .infinity, minHeight: 36)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .id(category.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 180)

                // Нижний ряд: ABC | категории эмодзи | Backspace (как в стандартной клавиатуре iOS)
                HStack(spacing: 4) {
                    Button {
                        switchMode(.letters)
                    } label: {
                        Text("ABC")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: context.needsInputModeSwitchKey ? 38 : 42, height: 42)
                    }
                    .buttonStyle(TatarKeyStyle())

                    if context.needsInputModeSwitchKey {
                        Button(action: advanceToNextInputMode) {
                            Image(systemName: "globe")
                                .font(.system(size: 17))
                                .frame(width: 32, height: 42)
                        }
                        .buttonStyle(TatarKeyStyle())
                    }

                    HStack(spacing: 1) {
                        ForEach(EmojiData.categories) { category in
                            Button {
                                emojiCategoryIndex = category.id
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrollProxy.scrollTo(category.id, anchor: .top)
                                }
                                hapticFeedback(.light)
                            } label: {
                                Image(systemName: category.symbolIcon)
                                    .font(.system(size: 15))
                                    .foregroundColor(emojiCategoryIndex == category.id ? .primary : .secondary.opacity(0.6))
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(emojiCategoryIndex == category.id ? Color.keyboardSpecialKeyPressed : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    deleteKey
                        .frame(width: context.needsInputModeSwitchKey ? 38 : 42, height: 42)
                }
            }
        }
    }

    // MARK: - Общие элементы (Shift, Backspace, нижний ряд)

    private var shiftKey: some View {
        Button {
            if capsLock {
                capsLock = false; shifted = false
            } else if shifted {
                capsLock = true
            } else {
                shifted = true
            }
        } label: {
            Image(systemName: capsLock ? "capslock.fill" : (shifted ? "shift.fill" : "shift"))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(TatarKeyStyle(isCharacterKey: shifted || capsLock))
    }

    private var deleteKey: some View {
        DeleteKeyButton {
            deleteBackward()
            hapticFeedback(.light)
            maybeAutoShift()
            updateTypingSuggestions()
        }
        .frame(maxWidth: .infinity, minHeight: 42)
    }

    private func bottomRow(leftLabel: String, leftAction: @escaping () -> Void, showEmojiButton: Bool) -> some View {
        HStack(spacing: 5) {
            Button(action: leftAction) {
                Text(leftLabel)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(TatarKeyStyle())

            if context.needsInputModeSwitchKey {
                // Системная кнопка — переключает между установленными В СИСТЕМЕ
                // клавиатурами (например, на английскую), как в iOS.
                Button(action: advanceToNextInputMode) {
                    Image(systemName: "globe")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 42)
                }
                .buttonStyle(TatarKeyStyle())
            }

            if showEmojiButton {
                Button {
                    switchMode(.emoji)
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 42)
                }
                .buttonStyle(TatarKeyStyle())
            }

            // Доп. кнопка рядом с пробелом — переключает НАШИ ТРИ письменности
            // (кириллица → латиница → арабица → ...). Специально другая иконка,
            // не 🌐 — чтобы не путать с системной кнопкой переключения приложений-
            // клавиатур, которая стоит вплотную слева.
            Button {
                cycleScript()
            } label: {
                Image(systemName: "textformat.alt")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 42)
            }
            .buttonStyle(TatarKeyStyle())

            // Кнопка пробела: без надписи, как в стандартной клавиатуре iOS,
            // забирает всё свободное пространство по центру.
            Button {
                handleSpaceTap()
            } label: {
                Text("")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(TatarKeyStyle(isCharacterKey: true))

            Button {
                clearSuggestions()
                insertText("\n")
                hapticFeedback(.light)
                maybeAutoShift()
            } label: {
                Text(context.returnKeyType.label(for: script))
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: 64, maxWidth: 76, minHeight: 42)
            }
            .buttonStyle(TatarKeyStyle(tinted: true))
        }
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
            insertText(" ")
            lastSpaceTapTime = now
        }
        hapticFeedback(.light)
        clearSuggestions()
        maybeAutoShift()
    }

    // MARK: - Автозаглавные буквы

    private func maybeAutoShift() {
        guard mode == .letters, script.supportsShift, !capsLock else { return }
        switch context.autocapitalizationType {
        case .none:
            shifted = false
        case .allCharacters:
            capsLock = true
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

private struct KeyPopupBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 30))
            .frame(width: 42, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }
}

// MARK: - Клавиша буквы/символа с долгим нажатием (второй символ) и защитой от свайпа

private struct KeyButton: View {
    let title: String
    let alt: String?
    let swipeState: SwipeState
    let onInsert: (String) -> Void

    @State private var isPressed = false
    @State private var timer: Timer?
    @State private var altFired = false

    var body: some View {
        Text(title)
            .font(.system(size: 22))
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPressed ? Color.keyboardKeyBackgroundPressed : Color.keyboardKeyBackground)
                    .shadow(color: Color.keyboardKeyShadow, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                if let alt {
                    Text(alt)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(3)
                }
            }
            // Всплывающий пузырь с увеличенной буквой над клавишей — как в
            // системной клавиатуре iOS. Сама клавиша при этом не увеличивается
            // (только слегка темнеет), крупная копия символа показывается сверху.
            // Примечание: для самого верхнего ряда пузырь может частично не
            // поместиться, если высота расширения-клавиатуры мала — системные
            // клавиатуры используют для этого специальный слой поверх всего
            // экрана, недоступный сторонним расширениям.
            .overlay(alignment: .top) {
                if isPressed {
                    KeyPopupBubble(text: title)
                        .offset(y: -54)
                        .allowsHitTesting(false)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .zIndex(isPressed ? 10 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        altFired = false
                        if let alt {
                            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                                // Если тем временем распознан свайп через несколько
                                // клавиш — не подставляем второй символ этой клавиши.
                                guard !swipeState.isActive else { return }
                                altFired = true
                                onInsert(alt)
                            }
                        }
                    }
                    .onEnded { _ in
                        timer?.invalidate(); timer = nil
                        isPressed = false
                        // Если жест распознан как свайп через несколько букв — слово
                        // уже вставлено в commitSwipe(), обычную вставку пропускаем.
                        guard !swipeState.isActive else { return }
                        if !altFired { onInsert(title) }
                    }
            )
    }
}

// MARK: - Backspace с автоповтором при удержании (как в системной клавиатуре)

private struct DeleteKeyButton: View {
    let action: () -> Void

    @State private var isPressed = false
    @State private var timer: Timer?
    @State private var heldDuration: TimeInterval = 0

    var body: some View {
        Image(systemName: "delete.left.fill")
            .frame(maxWidth: .infinity, minHeight: 42)
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
                        timer?.invalidate()
                        timer = nil
                        isPressed = false
                    }
            )
    }

    private func startRepeating() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { fastTimer in
            heldDuration += 0.1
            action()
            // Через ~1.2с удержания ускоряемся, как системная клавиатура
            if heldDuration > 1.2 {
                fastTimer.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in action() }
            }
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
}
