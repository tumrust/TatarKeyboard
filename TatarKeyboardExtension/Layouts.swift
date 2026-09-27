//
//  Layouts.swift
//  TatarKeyboardExtension
//
//  Раскладки для трёх письменностей татарского языка:
//  - Кириллица (стандартная раскладка, как на физической клавиатуре ПК)
//  - Латиница «Заманалиф-2» (официальный алфавит 2012 г., на базе турецкой Q-раскладки)
//  - Арабица «Иске имля / Яңа имля» (практическая раскладка, стандарта не существует)
//

import Foundation
import UIKit

enum TatarScript: String, CaseIterable, Identifiable {
    case cyrillic
    case latin
    case arabic

    var id: String { rawValue }

    /// Короткая метка на переключателе письменностей
    var switchLabel: String {
        switch self {
        case .cyrillic: return "ӘБВ"
        case .latin:    return "ABC"
        case .arabic:   return "ابج"
        }
    }

    var isRTL: Bool { self == .arabic }

    /// В арабском алфавите нет заглавных букв — Shift не нужен
    var supportsShift: Bool { self != .arabic }

    var spaceLabel: String {
        switch self {
        case .arabic: return "فاصыла"
        default: return "бушлык"
        }
    }
}

/// Одна клавиша: основной символ + вариант по долгому нажатию (может отсутствовать)
struct KeyDefinition: Identifiable {
    let id = UUID()
    let main: String
    let alt: String?

    init(_ main: String, alt: String? = nil) {
        self.main = main
        self.alt = alt
    }
}

// MARK: - Подписи кнопки Return под тип поля ввода (динамическая кнопка ввода, как в системной клавиатуре iOS)
extension UIReturnKeyType {
    func label(for script: TatarScript) -> String {
        switch script {
        case .cyrillic:
            switch self {
            case .go:            return "Күчү"
            case .search:        return "Эзләү"
            case .send:          return "Җибәрү"
            case .join:          return "Кушылу"
            case .next:          return "Алга"
            case .route:         return "Юл"
            case .continue:      return "Дәвам"
            case .done:          return "Әзер"
            case .emergencyCall: return "Шалту"
            default:             return "кайту"
            }
        case .latin:
            switch self {
            case .go:            return "Küçü"
            case .search:        return "Ezläw"
            case .send:          return "Cibärü"
            case .join:          return "Kuşılu"
            case .next:          return "Alğa"
            case .route:         return "Yul"
            case .continue:      return "Dawam"
            case .done:          return "Äzer"
            case .emergencyCall: return "Şaltu"
            default:             return "kaytu"
            }
        case .arabic:
            // Устоявшихся переводов системных значений Return для арабского
            // письма нет — используем нейтральный символ.
            return "⏎"
        }
    }
}

enum TatarLayout {

    /// Три ряда букв для выбранной письменности
    static func letterRows(for script: TatarScript, shifted: Bool) -> [[KeyDefinition]] {
        switch script {
        case .cyrillic: return cyrillicRows(shifted: shifted)
        case .latin:    return latinRows(shifted: shifted)
        case .arabic:   return arabicRows()
        }
    }

    /// Страница «123» — как в системной клавиатуре iOS
    static func numberRows(for script: TatarScript) -> [[KeyDefinition]] {
        let row1 = ["1","2","3","4","5","6","7","8","9","0"].map { KeyDefinition($0) }
        let row2 = ["-","/",":",";","(",")","₽","&","@","\""].map { KeyDefinition($0) }
        let row3 = [".",",","?","!","'"].map { KeyDefinition($0) }
        return [row1, row2, row3]
    }

    /// Страница «#+=» — вторая страница символов, как в системной клавиатуре iOS
    static func symbolRows(for script: TatarScript) -> [[KeyDefinition]] {
        let row1 = ["[","]","{","}","#","%","^","*","+","="].map { KeyDefinition($0) }
        let row2 = ["_","\\","|","~","<",">","€","£","¥","•"].map { KeyDefinition($0) }
        let row3 = [".",",","?","!","'"].map { KeyDefinition($0) }
        return [row1, row2, row3]
    }

    // MARK: - Кириллица
    // Раскладка повторяет физическую клавиатуру Татарстана: основной символ — чёрным,
    // alt — «синяя» буква с того же клавиша. По просьбе автора клавиша һ перенесена
    // из начала 1-го ряда в конец 3-го ряда (после ю).
    private static func cyrillicRows(shifted: Bool) -> [[KeyDefinition]] {
        func c(_ lower: String, _ upper: String) -> String { shifted ? upper : lower }

        let row1: [KeyDefinition] = [
            KeyDefinition(c("й","Й")),
            KeyDefinition(c("ө","Ө"), alt: c("ц","Ц")),
            KeyDefinition(c("у","У")),
            KeyDefinition(c("к","К")),
            KeyDefinition(c("е","Е")),
            KeyDefinition(c("н","Н")),
            KeyDefinition(c("г","Г")),
            KeyDefinition(c("ш","Ш")),
            KeyDefinition(c("ә","Ә"), alt: c("щ","Щ")),
            KeyDefinition(c("з","З")),
            KeyDefinition(c("х","Х")),
            KeyDefinition(c("ү","Ү"), alt: c("ъ","Ъ"))
        ]
        let row2: [KeyDefinition] = [
            KeyDefinition(c("ф","Ф")),
            KeyDefinition(c("ы","Ы")),
            KeyDefinition(c("в","В")),
            KeyDefinition(c("а","А")),
            KeyDefinition(c("п","П")),
            KeyDefinition(c("р","Р")),
            KeyDefinition(c("о","О")),
            KeyDefinition(c("л","Л")),
            KeyDefinition(c("д","Д")),
            KeyDefinition(c("ң","Ң"), alt: c("ж","Ж")),
            KeyDefinition(c("э","Э"), alt: "’")
        ]
        let row3: [KeyDefinition] = [
            KeyDefinition(c("я","Я")),
            KeyDefinition(c("ч","Ч")),
            KeyDefinition(c("с","С")),
            KeyDefinition(c("м","М")),
            KeyDefinition(c("и","И")),
            KeyDefinition(c("т","Т")),
            KeyDefinition(c("җ","Җ"), alt: c("ь","Ь")),
            KeyDefinition(c("б","Б")),
            KeyDefinition(c("ю","Ю")),
            KeyDefinition(c("һ","Һ"), alt: c("ё","Ё"))
        ]
        return [row1, row2, row3]
    }

    // MARK: - Латиница «Neo-әlif» (активистская доработка Заманалифа, 2023-24; на базе
    // турецкой Q-раскладки). Буква Ə/ə — отдельная клавиша (не диакритика над E),
    // как рекомендует источник: «Əə» встречается в татарском исключительно часто, и
    // класть её на долгое нажатие было бы неудобно. Ряд 1 теперь из 12 клавиш —
    // столько же, сколько в кириллическом ряду 1, для единого мышечного навыка.
    private static func latinRows(shifted: Bool) -> [[KeyDefinition]] {
        func c(_ lower: String, _ upper: String) -> String { shifted ? upper : lower }

        let row1: [KeyDefinition] = [
            KeyDefinition(c("q","Q")),
            KeyDefinition(c("w","W")),
            KeyDefinition(c("e","E")),
            KeyDefinition(c("r","R")),
            KeyDefinition(c("t","T")),
            KeyDefinition(c("y","Y")),
            KeyDefinition(c("u","U"), alt: c("ü","Ü")),
            KeyDefinition(c("i","İ"), alt: c("ı","I")),
            KeyDefinition(c("o","O"), alt: c("ö","Ö")),
            KeyDefinition(c("p","P")),
            KeyDefinition(c("ğ","Ğ")),
            KeyDefinition(c("ə","Ə"))
        ]
        let row2: [KeyDefinition] = [
            KeyDefinition(c("a","A")),
            KeyDefinition(c("s","S")),
            KeyDefinition(c("d","D")),
            KeyDefinition(c("f","F")),
            KeyDefinition(c("g","G")),
            KeyDefinition(c("h","H")),
            KeyDefinition(c("j","J")),
            KeyDefinition(c("k","K")),
            KeyDefinition(c("l","L")),
            KeyDefinition(c("ş","Ş"))
        ]
        let row3: [KeyDefinition] = [
            KeyDefinition(c("z","Z")),
            KeyDefinition(c("x","X")),
            KeyDefinition(c("c","C")),
            KeyDefinition(c("v","V")),
            KeyDefinition(c("b","B")),
            KeyDefinition(c("n","N"), alt: c("ñ","Ñ")),
            KeyDefinition(c("m","M")),
            KeyDefinition(c("ç","Ç")),
            KeyDefinition(c("w","W"))
        ]
        return [row1, row2, row3]
    }

    // MARK: - Арабица (Иске имля / Яңа имля — практическая раскладка, без официального стандарта)
    private static func arabicRows() -> [[KeyDefinition]] {
        let row1 = ["ا","ب","پ","ت","ج","چ","د","ر"].map { KeyDefinition($0) }
        let row2 = ["ز","ژ","س","ش","ف","ق","ک","گ"].map { KeyDefinition($0) }
        let row3 = ["ڭ","ل","م","ن","و","ۋ","ه","ی"].map { KeyDefinition($0) }
        return [row1, row2, row3]
    }
}
