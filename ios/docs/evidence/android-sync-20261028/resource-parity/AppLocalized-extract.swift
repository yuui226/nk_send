import Foundation

enum AppLocalized {
    private static func decodeAndroidEscapes(_ value: String) -> String {
        var result = ""
        var characters = value.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let escaped = characters.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\", "'", "\"": result.append(escaped)
            default: result.append("\\"); result.append(escaped)
            }
        }
        return result
    }

    /// Resolve supported resources in preferred-language order, then use Android's
    /// unqualified English resources. Explicit choices never mutate system locale.
    static func resourceLanguage(tag: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let candidates = tag == "system" ? preferredLanguages : [tag]
        for candidate in candidates {
            let locale = Locale(identifier: candidate)
            switch locale.language.languageCode?.identifier {
            case "en": return "en"
            case "zh":
                let script = locale.language.script?.identifier
                let traditional = script == "Hant" || (script != "Hans" && ["TW", "HK", "MO"].contains(locale.region?.identifier ?? ""))
                return traditional ? "hant" : "zh"
            default: continue
            }
        }
        return "en"
    }

    static func locale(for tag: String, preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        let language = resourceLanguage(tag: tag, preferredLanguages: preferredLanguages)
        return Locale(identifier: language == "hant" ? "zh-Hant" : language == "zh" ? "zh-Hans" : "en")
    }

    private static var currentResourceLanguage: String {
        resourceLanguage(tag: UserDefaults.standard.string(forKey: "app_language") ?? "system")
    }

    /// Uses the generated Android resources for both text and named lookups.
    static func text(_ value: String) -> String { text(value, language: currentResourceLanguage) }

    static func text(_ value: String, language: String) -> String {
        switch language {
        case "en": return decodeAndroidEscapes(AndroidLocalization.en[value] ?? value)
        case "hant": return decodeAndroidEscapes(AndroidLocalization.hant[value] ?? value)
        default: return decodeAndroidEscapes(value)
        }
    }

    static func resource(_ name: String) -> String { resource(name, language: currentResourceLanguage) }

    static func resource(_ name: String, language: String) -> String {
        decodeAndroidEscapes(
            IOSLocalization.byResource[name]?[language]
                ?? AndroidLocalization.byResource[name]?[language]
                ?? IOSLocalization.byResource[name]?["en"]
                ?? AndroidLocalization.byResource[name]?["en"]
                ?? name
        )
    }

    static func versionText(_ version: String) -> String {
        resource("version_label").replacingOccurrences(of: "%1$s", with: version)
    }

    static func settingState(_ enabled: Bool) -> String {
        resource(enabled ? "setting_on" : "setting_off")
    }

    static func formattedResource(_ name: String, _ replacements: [String: String]) -> String {
        replacements.reduce(resource(name)) { result, pair in
            result.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}
