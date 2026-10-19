//
//  KeyboardContext.swift
//  TatarKeyboardExtension
//
//  Мост между UITextDocumentProxy (данными о текущем текстовом поле — тип Return,
//  автозаглавные, тёмная тема и т.д.) и SwiftUI-интерфейсом клавиатуры.
//  KeyboardViewController обновляет эти поля в textDidChange/viewWillAppear,
//  а KeyboardRootView реагирует на них через @ObservedObject.
//

import UIKit
import Combine

final class KeyboardContext: ObservableObject {
    /// Тип кнопки Return, который запросило текущее поле (Go/Search/Send/Done...) —
    /// на нём строится «динамическая кнопка ввода».
    @Published var returnKeyType: UIReturnKeyType = .default

    /// Требует ли поле автозаглавные буквы, и в каком режиме (слова/предложения/все).
    @Published var autocapitalizationType: UITextAutocapitalizationType = .sentences

    /// Поле пароля — предиктивные функции в таких полях отключаем.
    @Published var isSecureTextEntry: Bool = false

    /// Есть ли уже текст перед курсором (некоторые Return-кнопки в системной
    /// клавиатуре неактивны, пока поле пустое).
    @Published var hasText: Bool = false

    /// Тёмное оформление: поле попросило тёмную клавиатуру или включена тёмная тема.
    @Published var isDarkAppearance: Bool = false

    /// false, если у пользователя включена только эта клавиатура — тогда кнопку
    /// 🌐 (переключение между приложениями-клавиатурами) показывать не нужно.
    @Published var needsInputModeSwitchKey: Bool = true

    /// Дал ли пользователь клавиатуре Full Access (Настройки → Клавиатуры →
    /// Разрешить полный доступ). Нужен только для тактильного отклика —
    /// без него UIFeedbackGenerator в расширении молча ничего не делает.
    @Published var hasFullAccess: Bool = false

    /// .no — поле просит не исправлять слова (автозамена выключается).
    @Published var autocorrectionType: UITextAutocorrectionType = .default

    /// Тип клавиатуры, который запросило поле (цифровая панель, e-mail, URL...).
    @Published var keyboardType: UIKeyboardType = .default

    /// true — кнопка Return должна быть неактивна, пока в поле нет текста.
    @Published var enablesReturnKeyAutomatically: Bool = false

    /// Системные замены текста (Настройки → Клавиатура → Замена текста):
    /// ключ — сокращение в нижнем регистре, значение — полная фраза.
    @Published var textReplacements: [String: String] = [:]

    /// Увеличивается при каждом изменении документа/курсора снаружи —
    /// по нему клавиатура пересчитывает автозаглавные и подсказки.
    @Published var documentChangeCount: Int = 0
}
