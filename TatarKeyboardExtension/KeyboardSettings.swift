//
//  KeyboardSettings.swift
//  TatarKeyboard + TatarKeyboardExtension (файл входит в обе цели)
//
//  Настройки, которые меняются в хост-приложении и читаются клавиатурой.
//  Хранятся в общем App Group — у приложения и расширения разные песочницы,
//  обычный UserDefaults.standard у них не общий. Клавиатура получает доступ
//  к общему контейнеру только с «Полным доступом»; без него действуют
//  значения по умолчанию (всё включено), но звук и вибрация без полного
//  доступа в расширении всё равно не работают.
//

import Foundation

enum KeyboardSettings {
    static let appGroup = "group.com.tatarapps.tatarkeyboard"

    static let soundEnabledKey = "keySoundEnabled"
    static let hapticsEnabledKey = "keyHapticsEnabled"

    static var store: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var isSoundEnabled: Bool {
        store.object(forKey: soundEnabledKey) as? Bool ?? true
    }

    static var isHapticsEnabled: Bool {
        store.object(forKey: hapticsEnabledKey) as? Bool ?? true
    }
}
