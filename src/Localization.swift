import Foundation

// Every user-facing string is written as L("English", "한국어").
// The language follows the [display] language setting; "system" uses the
// first preferred macOS language (Korean if it is Korean, English otherwise).

enum Localization {
    static var language: AppLanguage = .system

    static var usesKorean: Bool {
        switch language {
        case .english: return false
        case .korean: return true
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ko") == true
        }
    }
}

func L(_ english: String, _ korean: String) -> String {
    Localization.usesKorean ? korean : english
}
