// ==============================================================================
// Mimra — Localization & Internationalization Service (P7-06 / F-033, F-059)
// Provides string catalog translations, locale management, RTL detection,
// layout expansion support, and keyboard layout helper (Dvorak, AZERTY).
// Test IDs: T-I18N-01, T-I18N-02
// ==============================================================================

import AppKit
import Carbon
import Foundation
import os.log

private let logger = Logger(subsystem: "com.mimra.app", category: "LocalizationService")

/// Supported application languages in Mimra.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"
    case german = "de"
    case turkish = "tr"
    case arabic = "ar"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語 (Japanese)"
        case .german: return "Deutsch (German)"
        case .turkish: return "Türkçe (Turkish)"
        case .arabic: return "العربية (Arabic)"
        }
    }

    /// Whether this language is written Right-to-Left (RTL).
    public var isRTL: Bool {
        self == .arabic
    }
}

/// Central observable localization service providing string catalog lookup, locale selection, and RTL support.
@MainActor
public final class LocalizationService: ObservableObject {
    public static let shared = LocalizationService()

    public static let didChangeNotification = Notification.Name("MimraLocalizationDidChange")
    public static let appLanguageKey = "appSelectedLanguage"

    @Published public var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.appLanguageKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            logger.info("Language changed to: \(self.currentLanguage.rawValue, privacy: .public)")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: Self.appLanguageKey),
           let lang = AppLanguage(rawValue: raw) {
            self.currentLanguage = lang
        } else {
            // Match system preferred language if supported
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("ja") {
                self.currentLanguage = .japanese
            } else if preferred.hasPrefix("de") {
                self.currentLanguage = .german
            } else if preferred.hasPrefix("tr") {
                self.currentLanguage = .turkish
            } else if preferred.hasPrefix("ar") {
                self.currentLanguage = .arabic
            } else {
                self.currentLanguage = .english
            }
        }
    }

    // MARK: - String Catalog Dictionary (F-059, T-I18N-02)

    private static let catalog: [String: [AppLanguage: String]] = [
        // Panel & List
        "panel.empty_title": [
            .english: "Clipboard is Empty",
            .japanese: "クリップボードは空です",
            .german: "Zwischenablage ist leer",
            .turkish: "Pano Boş",
            .arabic: "الحافظة فارغة"
        ],
        "panel.empty_subtitle": [
            .english: "Items copied to the clipboard will appear here automatically.",
            .japanese: "コピーされた項目は自動的にここに表示されます。",
            .german: "In die Zwischenablage kopierte Elemente erscheinen hier automatisch.",
            .turkish: "Kopyalanan öğeler burada otomatik olarak görüntülenecektir.",
            .arabic: "العناصر المنسوخة إلى الحافظة ستظهر هنا تلقائياً."
        ],
        "panel.search_placeholder": [
            .english: "Search clipboard history...",
            .japanese: "クリップボード履歴を検索...",
            .german: "Zwischenablage-Verlauf durchsuchen...",
            .turkish: "Pano geçmişinde ara...",
            .arabic: "البحث في سجل الحافظة..."
        ],
        "panel.pinned_header": [
            .english: "PINNED",
            .japanese: "ピン留め",
            .german: "ANGEHEFTET",
            .turkish: "SABİTLENENLER",
            .arabic: "المثبتة"
        ],
        "panel.history_header": [
            .english: "HISTORY",
            .japanese: "履歴",
            .german: "VERLAUF",
            .turkish: "GEÇMİŞ",
            .arabic: "السجل"
        ],
        "panel.no_matches_title": [
            .english: "No Matches Found",
            .japanese: "一致する項目が見つかりません",
            .german: "Keine Treffer gefunden",
            .turkish: "Eşleşme Bulunamadı",
            .arabic: "لم يتم العثور على نتائج"
        ],

        // Settings Tabs
        "settings.title": [
            .english: "Mimra Settings",
            .japanese: "Mimra 設定",
            .german: "Mimra Einstellungen",
            .turkish: "Mimra Ayarları",
            .arabic: "إعدادات ميمرا"
        ],
        "settings.general": [
            .english: "General",
            .japanese: "一般",
            .german: "Allgemein",
            .turkish: "Genel",
            .arabic: "عام"
        ],
        "settings.appearance": [
            .english: "Appearance",
            .japanese: "外観",
            .german: "Erscheinungsbild",
            .turkish: "Görünüm",
            .arabic: "المظهر"
        ],
        "settings.hotkeys": [
            .english: "Hotkeys",
            .japanese: "ショートカット",
            .german: "Tastenkombinationen",
            .turkish: "Kısayollar",
            .arabic: "اختصارات المفاتيح"
        ],
        "settings.search": [
            .english: "Search & Sorting",
            .japanese: "検索と並び替え",
            .german: "Suche & Sortierung",
            .turkish: "Arama ve Sıralama",
            .arabic: "البحث والترتيب"
        ],
        "settings.storage": [
            .english: "Storage",
            .japanese: "ストレージ",
            .german: "Speicher",
            .turkish: "Depolama",
            .arabic: "التخزين"
        ],
        "settings.privacy": [
            .english: "Privacy",
            .japanese: "プライバシー",
            .german: "Datenschutz",
            .turkish: "Gizlilik",
            .arabic: "الخصوصية"
        ],

        // Actions & Confirmations
        "action.copy": [
            .english: "Copy",
            .japanese: "コピー",
            .german: "Kopieren",
            .turkish: "Kopyala",
            .arabic: "نسخ"
        ],
        "action.paste": [
            .english: "Paste",
            .japanese: "貼り付け",
            .german: "Einsetzen",
            .turkish: "Yapıştır",
            .arabic: "لصق"
        ],
        "action.delete": [
            .english: "Delete",
            .japanese: "削除",
            .german: "Löschen",
            .turkish: "Sil",
            .arabic: "حذف"
        ],
        "action.clear_all": [
            .english: "Clear All History...",
            .japanese: "すべての履歴を消去...",
            .german: "Gesamten Verlauf löschen...",
            .turkish: "Tüm Geçmişi Temizle...",
            .arabic: "مسح كل السجل..."
        ],
        "action.cancel": [
            .english: "Cancel",
            .japanese: "キャンセル",
            .german: "Abbrechen",
            .turkish: "Vazgeç",
            .arabic: "إلغاء"
        ],
        "action.restore_defaults": [
            .english: "Restore All Default Shortcuts",
            .japanese: "すべてのデフォルトを復元",
            .german: "Alle Standardeinstellungen wiederherstellen",
            .turkish: "Tüm Varsayılanları Geri Yükle",
            .arabic: "استعادة كافة الإعدادات الافتراضية"
        ]
    ]

    /// Translates a localization key using the active language or explicitly requested locale.
    public func string(forKey key: String, language: AppLanguage? = nil) -> String {
        let lang = language ?? currentLanguage
        if let entry = Self.catalog[key], let translated = entry[lang] {
            return translated
        }
        // Fall back to English
        if let entry = Self.catalog[key], let english = entry[.english] {
            return english
        }
        return key
    }

    /// Formats a localization template with variable arguments.
    public func format(key: String, _ args: CVarArg..., language: AppLanguage? = nil) -> String {
        let template = string(forKey: key, language: language)
        return String(format: template, arguments: args)
    }
}

// MARK: - Keyboard Layout & Physical Keycode Translation (F-033, T-I18N-01)

/// Helper for translating virtual key codes across keyboard layouts (QWERTY, Dvorak, AZERTY).
public enum KeyCodeHelper {
    /// Translates an ANSI virtual keycode into a character representation under the specified layout type.
    public static func character(for keyCode: UInt32, layoutName: String = "QWERTY") -> String {
        switch layoutName.uppercased() {
        case "DVORAK":
            switch keyCode {
            case UInt32(kVK_ANSI_C): return "J"
            case UInt32(kVK_ANSI_V): return "K"
            case UInt32(kVK_ANSI_P): return "R"
            default: break
            }
        case "AZERTY", "FRENCH":
            switch keyCode {
            case UInt32(kVK_ANSI_Q): return "A"
            case UInt32(kVK_ANSI_W): return "Z"
            case UInt32(kVK_ANSI_A): return "Q"
            case UInt32(kVK_ANSI_Z): return "W"
            case 18: return "&"
            case 19: return "é"
            case 20: return "\""
            case 21: return "'"
            case 23: return "("
            case 22: return "§"
            case 26: return "è"
            case 28: return "!"
            case 25: return "ç"
            default: break
            }
        default: // QWERTY
            break
        }

        // Default QWERTY mapping
        return KeyShortcut.keyName(for: keyCode)
    }
}
