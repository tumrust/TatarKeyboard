//
//  ContentView.swift
//  TatarKeyboard (хост-приложение)
//

import SwiftUI

struct ContentView: View {
    @State private var demoText: String = ""
    // Общий App Group с клавиатурой — см. KeyboardSettings.
    @AppStorage(KeyboardSettings.soundEnabledKey, store: KeyboardSettings.store)
    private var isSoundEnabled = true
    @AppStorage(KeyboardSettings.hapticsEnabledKey, store: KeyboardSettings.store)
    private var isHapticsEnabled = true

    var body: some View {
        NavigationView {
            Form {
                Section("Тестовое поле") {
                    TextEditor(text: $demoText)
                        .frame(minHeight: 120)
                        .font(.system(size: 20))
                }

                Section {
                    Toggle(isOn: $isSoundEnabled) {
                        Label("Звук клавиш", systemImage: "speaker.wave.2")
                    }
                    Toggle(isOn: $isHapticsEnabled) {
                        Label("Вибрация", systemImage: "iphone.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Отклик при наборе")
                } footer: {
                    Text("Работает только с включённым «Полным доступом». Звук клавиш также отключается беззвучным режимом iPhone.")
                }

                Section("Как включить клавиатуру") {
                    instructionRow(number: 1, text: "Настройки → Основные → Клавиатура → Клавиатуры → Добавить новую клавиатуру")
                    instructionRow(number: 2, text: "Выберите «Tatar Keyboard» в разделе «Сторонние клавиатуры»")
                    instructionRow(number: 3, text: "Там же включите «Разрешить полный доступ» (см. пояснение ниже)")
                    instructionRow(number: 4, text: "В любом приложении нажмите и удерживайте значок 🌐, чтобы выбрать татарскую клавиатуру")
                    instructionRow(number: 5, text: "Переключайте кириллицу / латиницу / арабицу кнопками над клавиатурой")

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Открыть Настройки", systemImage: "gear")
                    }
                }

                Section {
                    Label("Зачем нужен «Полный доступ»", systemImage: "hand.raised")
                        .font(.system(size: 15, weight: .semibold))
                    Text("iOS по умолчанию запрещает сторонним клавиатурам звук и вибрацию при нажатии клавиш, а также чтение настроек из этого приложения, пока не выдан полный доступ — таково системное ограничение платформы, не наш выбор. Мы используем этот доступ ТОЛЬКО для звука, вибрации и переключателей выше.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("Клавиатура НЕ выходит в интернет, НЕ отправляет набранный текст никуда за пределы устройства и не имеет доступа к буферу обмена сверх обычного. Предиктивные подсказки слов считаются полностью на устройстве по встроенному словарю — без каких-либо серверов.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("Без полного доступа клавиатура работает точно так же — просто без звука и вибрации при наборе.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("Приватность")
                }
            }
            .navigationTitle("Tatar Keyboard")
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .font(.system(size: 15))
        }
    }
}

#Preview {
    ContentView()
}
