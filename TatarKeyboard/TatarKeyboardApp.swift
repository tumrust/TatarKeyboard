//
//  TatarKeyboardApp.swift
//  TatarKeyboard (хост-приложение)
//
//  Само приложение не показывает клавиатуру — оно требуется Apple как «контейнер»
//  для расширения-клавиатуры и как место, где пользователь включает его в Настройках.
//

import SwiftUI

@main
struct TatarKeyboardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
