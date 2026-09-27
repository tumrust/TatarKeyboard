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

    /// Просит ли текущее приложение принудительно тёмное оформление клавиатуры.
    @Published var isDarkAppearance: Bool = false

    /// false, если у пользователя включена только эта клавиатура — тогда кнопку
    /// 🌐 (переключение между приложениями-клавиатурами) показывать не нужно.
    @Published var needsInputModeSwitchKey: Bool = true

    /// Дал ли пользователь клавиатуре Full Access (Настройки → Клавиатуры →
    /// Разрешить полный доступ). Нужен только для тактильного отклика —
    /// без него UIFeedbackGenerator в расширении молча ничего не делает.
    @Published var hasFullAccess: Bool = false
}
