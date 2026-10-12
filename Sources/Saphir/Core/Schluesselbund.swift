import Foundation
import Security

/// Der macOS-Schluesselbund, auf das Noetigste eingedampft.
///
/// Hier liegt einzig das Spotify-Zugriffsrecht. Eine Datei in `~/.saphir` waere
/// einfacher, koennte aber jeder andere Prozess unter demselben Benutzer lesen —
/// und ein Spotify-Refresh-Token gilt bis zum Widerruf.
enum Schluesselbund {
    private static let dienst = "com.luismarks.saphir"

    static func lies(_ konto: String) -> String? {
        let frage: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ergebnis: CFTypeRef?
        guard SecItemCopyMatching(frage as CFDictionary, &ergebnis) == errSecSuccess,
              let daten = ergebnis as? Data else { return nil }
        return String(data: daten, encoding: .utf8)
    }

    /// `nil` loescht den Eintrag.
    static func setze(_ wert: String?, fuer konto: String) {
        let kennung: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto
        ]
        SecItemDelete(kennung as CFDictionary)

        guard let wert, let daten = wert.data(using: .utf8) else { return }
        var neu = kennung
        neu[kSecValueData as String] = daten
        // Ohne Anmeldung am Mac gibt es keine Notch — strenger als
        // `WhenUnlocked` muss es nicht sein.
        neu[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let stand = SecItemAdd(neu as CFDictionary, nil)
        if stand != errSecSuccess {
            Protokoll.fehler("Schluesselbund: \(konto) nicht gespeichert (\(stand))")
        }
    }
}
