//
//  KeyboardViewController.swift
//  TatarKeyboardExtension
//
//  Точка входа расширения клавиатуры. Встраивает SwiftUI-интерфейс (KeyboardRootView)
//  в UIInputViewController и синхронизирует KeyboardContext (тип Return,
//  автозаглавные, тёмная тема, тип клавиатуры) с текущим полем ввода через
//  textDocumentProxy.
//

import UIKit
import SwiftUI
import AudioToolbox

/// Тип нажатия — как в системной клавиатуре, у букв, Backspace и служебных
/// клавиш (Shift, 123, пробел, Return...) разные звуки.
enum KeyFeedback {
    case character
    case delete
    case modifier
    /// Вход в режим трекпада на пробеле — только вибрация, без звука.
    case cursorMode

    /// Системные звуки клавиатуры iOS (те же, что у стандартной клавиатуры).
    var systemSoundID: SystemSoundID? {
        switch self {
        case .character:  return 1104
        case .delete:     return 1155
        case .modifier:   return 1156
        case .cursorMode: return nil
        }
    }
}

final class KeyboardViewController: UIInputViewController {

    private var hostingController: UIHostingController<KeyboardRootView>!
    private var heightConstraint: NSLayoutConstraint!
    private let context = KeyboardContext()
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()

        context.needsInputModeSwitchKey = needsInputModeSwitchKey

        let rootView = KeyboardRootView(
            context: context,
            insertText: { [weak self] text in
                guard let self else { return }
                self.textDocumentProxy.insertText(text)
                self.context.hasText = self.textDocumentProxy.hasText
            },
            deleteBackward: { [weak self] in
                guard let self else { return }
                self.textDocumentProxy.deleteBackward()
                self.context.hasText = self.textDocumentProxy.hasText
            },
            moveCursor: { [weak self] offset in
                self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            },
            documentContextBeforeInput: { [weak self] in
                self?.textDocumentProxy.documentContextBeforeInput
            },
            handleInputModeList: { [weak self] view, event in
                self?.handleInputModeList(from: view, with: event)
            },
            keyFeedback: { [weak self] kind in
                self?.playFeedback(kind)
            }
        )

        let hosting = UIHostingController(rootView: rootView)
        hostingController = hosting

        addChild(hosting)
        view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        view.addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)

        // Точный расчёт под контент (без старой панели письменности, которую убрали):
        // 6(padding.top) + 30(суджест-бар, теперь всегда зарезервирован) + 8(spacing)
        // + 142(3 ряда букв) + 8(spacing) + 42(нижний ряд) + 4(padding.bottom) = 240.
        // Раньше здесь стояло 260/320 — с запасом под уже убранную панель раскладки,
        // отсюда и заметный лишний отступ снизу, который был замечен на устройстве.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        heightConstraint = view.heightAnchor.constraint(equalToConstant: isPad ? 250 : 240)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        // Попытка разрешить пузырю выходить за пределы расширения. На практике
        // iOS всё равно обрезает клавиатуру по её верхнему краю, поэтому
        // всплывающие окна рассчитаны так, чтобы помещаться внутри
        // (см. KeyPopupLayout в KeyboardRootView).
        view.clipsToBounds = false
        hosting.view.clipsToBounds = false

        // Смена системной темы, пока клавиатура на экране.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.syncContext()
        }

        syncContext()
        loadTextReplacements()
        // Большой словарь (~5 МБ) читается в фоне; по готовности перестраиваем подсказки.
        TatarLanguageModel.shared.loadIfNeeded { [weak self] in
            self?.context.documentChangeCount &+= 1
        }
    }

    /// Пользовательские замены текста из настроек iOS. В лексиконе также лежат
    /// имена из контактов (у них userInput == documentText) — их пропускаем.
    private func loadTextReplacements() {
        requestSupplementaryLexicon { [weak self] lexicon in
            var replacements: [String: String] = [:]
            for entry in lexicon.entries where entry.userInput != entry.documentText {
                replacements[entry.userInput.lowercased()] = entry.documentText
            }
            DispatchQueue.main.async {
                self?.context.textReplacements = replacements
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncContext()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Контент пока не адаптируется под ландшафтную ориентацию (клавиши не
        // уменьшаются), поэтому высота остаётся той же, что и в портретной —
        // уменьшать её отдельно означало бы риск обрезать нижний ряд клавиш.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        heightConstraint.constant = isPad ? 250 : 240
    }

    override func textWillChange(_ textInput: UITextInput?) {}

    override func textDidChange(_ textInput: UITextInput?) {
        syncContext()
    }

    /// Звук и вибрация нажатия. Оба переключателя — в хост-приложении
    /// (KeyboardSettings, читаются при каждом нажатии, чтобы изменения
    /// применялись сразу). Без Full Access iOS не даёт расширению ни звука,
    /// ни вибрации, ни доступа к общим настройкам.
    private func playFeedback(_ kind: KeyFeedback) {
        guard hasFullAccess else { return }
        if KeyboardSettings.isSoundEnabled, let soundID = kind.systemSoundID {
            AudioServicesPlaySystemSound(soundID)
        }
        if KeyboardSettings.isHapticsEnabled {
            (kind == .cursorMode ? mediumHaptic : lightHaptic).impactOccurred()
        }
    }

    /// Подтягивает из системы всё, от чего зависит внешний вид/поведение
    /// клавиатуры для текущего поля: тип Return, автозаглавные, признак пароля,
    /// тёмное оформление, доступность кнопки 🌐.
    private func syncContext() {
        let proxy = textDocumentProxy
        context.returnKeyType = proxy.returnKeyType ?? .default
        context.autocapitalizationType = proxy.autocapitalizationType ?? .sentences
        context.isSecureTextEntry = proxy.isSecureTextEntry ?? false
        context.hasText = proxy.hasText
        context.needsInputModeSwitchKey = needsInputModeSwitchKey
        context.hasFullAccess = hasFullAccess
        context.keyboardType = proxy.keyboardType ?? .default
        context.autocorrectionType = proxy.autocorrectionType ?? .default
        context.enablesReturnKeyAutomatically = proxy.enablesReturnKeyAutomatically ?? false
        context.documentChangeCount &+= 1

        // Тёмная тема: поле попросило тёмную клавиатуру ИЛИ в системе включена
        // тёмная тема. Явное .light от поля тему системы не перебивает — часть
        // приложений сообщает .light даже в тёмной теме, и раньше из-за этого
        // клавиши оставались светлыми. Переопределяем стиль только у SwiftUI-
        // потомка (не у self.view), чтобы traitCollection контроллера продолжал
        // отражать настоящую тему системы.
        let systemIsDark = traitCollection.userInterfaceStyle == .dark
            || view.window?.traitCollection.userInterfaceStyle == .dark
        let isDark = proxy.keyboardAppearance == .dark || systemIsDark
        context.isDarkAppearance = isDark
        hostingController?.overrideUserInterfaceStyle = isDark ? .dark : .light
    }
}
