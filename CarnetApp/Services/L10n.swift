import Foundation

/// The language Carnet speaks. The member's own choice, made in the Maurice
/// app and kept by the household (`GET /api/users/me/preferences` → `locale`),
/// wins over the device's: someone whose iPhone is in English but who chose
/// French for Maurice reads Carnet in French too. Without a choice, the
/// language iOS gives the app (the device's, or the one set for Carnet in
/// Settings).
///
/// The choice is kept on the device per member (`carnet.locale.<member id>`)
/// so the first screen of a launch already speaks it; `CarnetSession` reads
/// it again from the server when a member becomes active.
enum AppLanguage {
    /// The languages Localizable.xcstrings holds.
    static let supported = ["en", "fr", "de", "it", "es", "nl", "pt"]

    private static var defaults: UserDefaults { UserDefaults(suiteName: CarnetAPI.appGroupID) ?? .standard }

    static func key(_ memberId: String) -> String { "carnet.locale.\(memberId)" }

    /// The active member's chosen language, as a base code ("fr"), or nil
    /// when they follow the device or chose one Carnet does not hold.
    static var chosen: String? {
        guard let member = defaults.string(forKey: "carnet.activeMemberId"),
              let id = defaults.string(forKey: key(member)) else { return nil }
        let base = (id.components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? id).lowercased()
        return supported.contains(base) ? base : nil
    }

    /// What `L` reads from: the chosen language's table, else the bundle's own
    /// resolution (iOS's language for the app).
    static var bundle: Bundle {
        guard let code = chosen,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    /// The language strings are said in — for dates and numbers set beside them.
    static var locale: Locale {
        guard let code = chosen else { return .current }
        // Keep the device's region for a language it shares ("fr" on a
        // French-region iPhone stays fr_FR), else the language alone.
        if let region = Locale.current.region?.identifier { return Locale(identifier: "\(code)_\(region)") }
        return Locale(identifier: code)
    }

    /// Remember a member's choice (nil: they follow the device).
    static func set(_ locale: String?, for memberId: String) {
        if let locale, !locale.isEmpty { defaults.set(locale, forKey: key(memberId)) }
        else { defaults.removeObject(forKey: key(memberId)) }
    }
}

/// A string from Localizable.xcstrings, in the member's language. The keys
/// are Maurice's own (maurice/app/Maurice/Resources/*.lproj/Localizable.strings):
/// both apps say the same thing in the same words, in the same seven languages.
func L(_ key: String) -> String {
    AppLanguage.bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// A formatted string from Localizable.xcstrings (`%@`, `%d`, `%1$@`…).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.locale, arguments: args)
}
