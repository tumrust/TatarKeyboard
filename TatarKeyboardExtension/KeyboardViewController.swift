//
//  KeyboardViewController.swift
//  TatarKeyboardExtension
//
//  Точка входа расширения клавиатуры. Встраивает SwiftUI-интерфейс (KeyboardRootView)
//  в UIInputViewController и синхронизирует KeyboardContext (тип Return,
//  автозаглавные, тёмная тема) с текущим полем ввода через textDocumentProxy.
//

import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {

    private var hostingController: UIHostingController<KeyboardRootView>!
    private var heightConstraint: NSLayoutConstraint!
    private let context = KeyboardContext()

    override func viewDidLoad() {
        super.viewDidLoad()

        context.needsInputModeSwitchKey = needsInputModeSwitchKey

        let rootView = KeyboardRootView(
            context: context,
            insertText: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            deleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            documentContextBeforeInput: { [weak self] in
                self?.textDocumentProxy.documentContextBeforeInput
            },
            advanceToNextInputMode: { [weak self] in
                self?.advanceToNextInputMode()
            },
            hapticFeedback: { [weak self] style in
                guard let self, self.hasFullAccess else { return }
                UIImpactFeedbackGenerator(style: style).impactOccurred()
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

        // Разрешаем контенту (в частности — всплывающему пузырю над клавишей)
        // визуально выходить за пределы объявленной высоты расширения, если
        // система это допускает; в любом случае это безопасно, т.к. пузырь
        // не участвует в хит-тестинге (allowsHitTesting(false)).
        view.clipsToBounds = false
        hosting.view.clipsToBounds = false

        syncContext()
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

    /// Подтягивает из системы всё, от чего зависит внешний вид/поведение
    /// клавиатуры для текущего поля: тип Return, автозаглавные, признак пароля,
    /// тёмное оформление, доступность кнопки 🌐.
    private func syncContext() {
        let proxy = textDocumentProxy
        context.returnKeyType = proxy.returnKeyType ?? .default
        context.autocapitalizationType = proxy.autocapitalizationType ?? .sentences
        context.isSecureTextEntry = proxy.isSecureTextEntry ?? false
        context.hasText = proxy.hasText
        context.isDarkAppearance = proxy.keyboardAppearance == .dark
        context.needsInputModeSwitchKey = needsInputModeSwitchKey
        context.hasFullAccess = hasFullAccess
    }
}
