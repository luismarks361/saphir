import AppKit
import CryptoKit
import Foundation
import Network

/// Verbindung zu Spotifys Web-API — allein dafuer, ein Stueck in die eigene
/// Bibliothek zu legen oder wieder herauszunehmen.
///
/// Warum nicht ueber AppleScript wie alles andere am Musik-Widget: Spotifys
/// Skript-Woerterbuch kennt kein Speichern. Es kann vor, zurueck, Pause und
/// Position setzen, mehr nicht; `starred` ist ein Rest aus der Stern-Zeit und
/// nur lesbar. Der Weg ueber die Web-API ist der einzige, der wirklich das tut,
/// was das Plus in Spotify tut.
///
/// Anmeldung per **PKCE**, also ohne Client-Geheimnis — dieses Geheimnis liesse
/// sich aus einer App auf dem eigenen Rechner ohnehin herausziehen. Der Rueckweg
/// aus dem Browser laeuft ueber einen winzigen Zuhoerer auf 127.0.0.1; Spotify
/// erlaubt genau diese Schleife fuer Programme auf dem Schreibtisch.
@MainActor
final class SpotifyKonto: ObservableObject {
    static let shared = SpotifyKonto()

    enum Stand: Equatable {
        case ohneKennung     // Client-ID fehlt noch
        case getrennt
        case verbindet
        case verbunden
    }

    @Published private(set) var stand: Stand = .getrennt
    @Published private(set) var fehler: String?
    /// Liegt das laufende Stueck schon in der Bibliothek? `nil` heisst: noch
    /// nicht gefragt, oder es ist gar kein Spotify-Stueck.
    @Published private(set) var gespeichert: Bool?
    /// Fuer welches Stueck Spotify den letzten Druck abgewiesen hat. Der Knopf
    /// faellt sichtbar zurueck, statt stumm nichts zu tun.
    @Published private(set) var abgewiesen: String?

    /// Fester Port, damit die Rueckleit-Adresse im Spotify-Dashboard eine
    /// einzige, gleichbleibende Zeile ist.
    static let port: UInt16 = 8731
    static var rueckleitung: String { "http://127.0.0.1:\(port)/saphir" }

    private let rechte = "user-library-read user-library-modify"
    private var zuhoerer: Rueckleitung?
    private var pruefungFuer: String?

    // MARK: - Gemerktes

    /// Kein Geheimnis: bei PKCE ist die Client-ID oeffentlich, geheim bleibt
    /// nur das Pruefwort, und das lebt nur waehrend der Anmeldung.
    @Published var clientId: String = UserDefaults.standard.string(forKey: "spotify.clientId") ?? "" {
        didSet {
            UserDefaults.standard.set(kennung, forKey: "spotify.clientId")
            standPruefen()
        }
    }

    private var kennung: String { clientId.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var zugriff: String? {
        get { Schluesselbund.lies("spotify.zugriff") }
        set { Schluesselbund.setze(newValue, fuer: "spotify.zugriff") }
    }

    private var erneuerung: String? {
        get { Schluesselbund.lies("spotify.erneuerung") }
        set { Schluesselbund.setze(newValue, fuer: "spotify.erneuerung") }
    }

    private var laeuftAbAm: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "spotify.ablauf")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "spotify.ablauf") }
    }

    private init() { standPruefen() }

    private func standPruefen() {
        if kennung.isEmpty { stand = .ohneKennung }
        else if erneuerung != nil { stand = .verbunden }
        else if stand != .verbindet { stand = .getrennt }
    }

    // MARK: - Anmelden

    func verbinde() {
        guard !kennung.isEmpty else { fehler = "Client-ID fehlt."; return }
        fehler = nil
        stand = .verbindet

        let pruefwort = Self.zufall(64)
        let kennzeichen = Self.zufall(16)

        var teile = URLComponents(string: "https://accounts.spotify.com/authorize")!
        teile.queryItems = [
            .init(name: "client_id", value: kennung),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.rueckleitung),
            .init(name: "scope", value: rechte),
            .init(name: "state", value: kennzeichen),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.abdruck(pruefwort))
        ]
        guard let url = teile.url else { return }

        zuhoerer = Rueckleitung(port: Self.port)
        zuhoerer?.warteAufCode { [weak self] ergebnis in
            Task { @MainActor in
                guard let self else { return }
                self.zuhoerer = nil
                switch ergebnis {
                case .schiefgegangen(let text):
                    self.fehler = text
                    self.standPruefen()
                case .code(let code, let zurueck):
                    guard zurueck == kennzeichen else {
                        self.fehler = "Antwort passt nicht zur Anfrage."
                        self.standPruefen()
                        return
                    }
                    await self.holeToken(code: code, pruefwort: pruefwort)
                }
            }
        }
        NSWorkspace.shared.open(url)
    }

    func trenne() {
        zugriff = nil
        erneuerung = nil
        gespeichert = nil
        kontoGeprueft = false
        pruefungFuer = nil
        fehler = nil
        standPruefen()
    }

    private func holeToken(code: String, pruefwort: String) async {
        let felder = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.rueckleitung,
            "client_id": kennung,
            "code_verifier": pruefwort
        ]
        guard case .ok(let antwort) = await tokenAnfrage(felder) else {
            stand = .getrennt
            return
        }
        uebernimm(antwort)
        stand = .verbunden
        // Das laufende Stueck ist noch ungeprueft — der Musik-Dienst holt das
        // nach, sobald er das hier hoert.
        pruefungFuer = nil
        NotificationCenter.default.post(name: .saphirSpotifyVerbunden, object: nil)
        Protokoll.info("Spotify: verbunden.")
    }

    private func erneuere() async -> Bool {
        guard let alt = erneuerung else { return false }
        let felder = [
            "grant_type": "refresh_token",
            "refresh_token": alt,
            "client_id": kennung
        ]
        switch await tokenAnfrage(felder) {
        case .ok(let antwort):
            uebernimm(antwort)
            return true
        case .widerrufen:
            // Spotify sagt ausdruecklich, dass das Erneuerungswort nicht mehr
            // gilt — dann hilft nur neu anmelden.
            trenne()
            fehler = "Anmeldung abgelaufen. Bitte neu verbinden."
            return false
        case .vorlaeufig:
            // Netz weg, Spotify gestoert, keine lesbare Antwort: das Wort
            // bleibt. Frueher hing hier auch `trenne()`, und eine einzige
            // unlesbare Antwort am 22.09.2026 hat Saphir dauerhaft von Spotify
            // getrennt, obwohl das Wort noch gueltig war.
            return false
        }
    }

    private func uebernimm(_ antwort: [String: Any]) {
        zugriff = antwort["access_token"] as? String
        // Spotify tauscht das Erneuerungswort bei PKCE bei jedem Mal aus; wer
        // das alte behaelt, steht beim uebernaechsten Mal ohne da.
        if let neu = antwort["refresh_token"] as? String { erneuerung = neu }
        let dauer = antwort["expires_in"] as? Double ?? 3600
        laeuftAbAm = Date().addingTimeInterval(dauer - 60)

        // Spotify schreibt in die Antwort, welche Rechte wirklich erteilt
        // wurden — das muss nicht sein, was angefragt wurde. Ohne diese Zeile
        // sieht man einer 403 nicht an, ob das Recht fehlt oder das Konto.
        erteilteRechte = antwort["scope"] as? String ?? ""
        Protokoll.info("Spotify: Rechte erteilt: \(erteilteRechte.isEmpty ? "keine" : erteilteRechte)")
    }

    /// Was Spotify beim letzten Token tatsaechlich erteilt hat.
    private(set) var erteilteRechte: String = UserDefaults.standard.string(forKey: "spotify.rechte") ?? "" {
        didSet { UserDefaults.standard.set(erteilteRechte, forKey: "spotify.rechte") }
    }

    /// Fehlt eines der beiden noetigen Rechte, hilft nur trennen und neu
    /// verbinden — Spotify fragt sonst nicht noch einmal.
    var fehlendeRechte: [String] {
        guard !erteilteRechte.isEmpty else { return [] }
        return rechte.split(separator: " ").map(String.init)
            .filter { !erteilteRechte.contains($0) }
    }

    private enum TokenAntwort {
        case ok([String: Any])
        /// Spotify lehnt das Erneuerungswort ausdruecklich ab (`invalid_grant`).
        case widerrufen
        /// Kein Urteil von Spotify: Netzfehler, Stoerung, nicht lesbare Antwort.
        case vorlaeufig
    }

    private func tokenAnfrage(_ felder: [String: String]) async -> TokenAntwort {
        var anfrage = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        anfrage.httpMethod = "POST"
        anfrage.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        anfrage.httpBody = Data(Self.formular(felder).utf8)

        do {
            let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
            let code = (antwort as? HTTPURLResponse)?.statusCode ?? 0
            guard let objekt = try? JSONSerialization.jsonObject(with: daten) as? [String: Any] else {
                let text = String(data: daten.prefix(200), encoding: .utf8) ?? ""
                fehler = "Spotify antwortet nicht lesbar (HTTP \(code))."
                Protokoll.fehler("Spotify Token: HTTP \(code), keine lesbare Antwort: \(text)")
                return .vorlaeufig
            }
            if objekt["access_token"] != nil { return .ok(objekt) }
            let art = objekt["error"] as? String
            let grund = (objekt["error_description"] as? String) ?? art ?? "unbekannt"
            fehler = "Spotify: \(grund)"
            Protokoll.fehler("Spotify Token: HTTP \(code), \(grund)")
            return art == "invalid_grant" ? .widerrufen : .vorlaeufig
        } catch {
            fehler = error.localizedDescription
            Protokoll.fehler("Spotify Token: \(error.localizedDescription)")
            return .vorlaeufig
        }
    }

    // MARK: - Bibliothek

    /// Aus `spotify:track:4uLU...` wird `4uLU...`. Podcasts und lokale Dateien
    /// lassen sich nicht speichern; fuer die kommt nil zurueck und das Plus
    /// bleibt weg.
    ///
    /// Gebraucht wird sie seit der Februar-2026-Umstellung nur noch zum Pruefen,
    /// ob ueberhaupt ein Stueck laeuft — an die Bibliothek geht die volle URI.
    static func stueckKennung(_ uri: String) -> String? {
        let teile = uri.components(separatedBy: ":")
        guard teile.count == 3, teile[0] == "spotify", teile[1] == "track",
              !teile[2].isEmpty else { return nil }
        return teile[2]
    }

    /// Fragt fuer das laufende Stueck nach, ob es schon in der Bibliothek liegt.
    func pruefe(uri: String) {
        guard stand == .verbunden, Self.stueckKennung(uri) != nil else {
            gespeichert = nil
            pruefungFuer = nil
            return
        }
        guard pruefungFuer != uri else { return }
        pruefungFuer = uri
        gespeichert = nil
        abgewiesen = nil

        Task {
            guard let daten = await api("me/library/contains", methode: "GET",
                                        abfrage: ["uris": uri]),
                  let liste = try? JSONSerialization.jsonObject(with: daten) as? [Bool],
                  let erste = liste.first else { return }
            guard pruefungFuer == uri else { return }
            gespeichert = erste
        }
    }

    /// Das Plus: rein in die Bibliothek, und beim zweiten Druck wieder heraus.
    func umschalten(uri: String) {
        guard stand == .verbunden, Self.stueckKennung(uri) != nil else { return }
        let neu = !(gespeichert ?? false)
        // Sofort umschalten, damit der Knopf nicht auf das Netz wartet.
        gespeichert = neu

        Task {
            let erfolg = await api("me/library", methode: neu ? "PUT" : "DELETE",
                                   abfrage: ["uris": uri]) != nil
            guard !erfolg else { return }
            // Nicht durchgekommen: zurueck auf den alten Stand, nicht luegen.
            //
            // Die Bedingung auf `pruefungFuer` stand hier frueher und war falsch:
            // schlaegt schon die Abfrage fehl, ist `pruefungFuer` gar nicht
            // gesetzt, und der Knopf blieb auf „gespeichert" stehen, obwohl
            // nichts gespeichert war.
            gespeichert = !neu
            abgewiesen = uri
        }
    }

    private func api(_ pfad: String, methode: String,
                     abfrage: [String: String]? = nil,
                     rumpf: [String: Any]? = nil) async -> Data? {
        if Date() >= laeuftAbAm || zugriff == nil {
            guard await erneuere() else { return nil }
        }
        guard let token = zugriff else { return nil }

        var teile = URLComponents(string: "https://api.spotify.com/v1/\(pfad)")!
        if let abfrage { teile.queryItems = abfrage.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = teile.url else { return nil }
        var anfrage = URLRequest(url: url)
        anfrage.httpMethod = methode
        anfrage.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Content-Type nur, wenn wirklich etwas im Rumpf steht.
        //
        // Das war der Fehler, an dem das Plus monatelang nichts tat: die App
        // hing den Typ an *jede* Anfrage, auch an ein GET und an ein PUT ohne
        // Rumpf. Spotifys Torwaechter wirft so etwas mit einer nackten 403
        // „Forbidden" zurueck — ohne Hinweis, ohne www-authenticate, und damit
        // ununterscheidbar von „dir fehlt ein Recht". Nachgemessen: dieselbe
        // Abfrage ohne den Typ antwortet mit 200.
        if let rumpf, let daten = try? JSONSerialization.data(withJSONObject: rumpf) {
            anfrage.httpBody = daten
            anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (daten, antwort) = try await URLSession.shared.data(for: anfrage)
            let code = (antwort as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                // Token war doch schon tot: einmal erneuern und wiederholen.
                guard await erneuere(), let frisch = zugriff else { return nil }
                anfrage.setValue("Bearer \(frisch)", forHTTPHeaderField: "Authorization")
                let (daten2, antwort2) = try await URLSession.shared.data(for: anfrage)
                let code2 = (antwort2 as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code2) { return daten2 }
                melde(code: code2, rumpf: daten2, antwort: antwort2, methode: methode, pfad: pfad)
                return nil
            }
            guard (200..<300).contains(code) else {
                melde(code: code, rumpf: daten, antwort: antwort, methode: methode, pfad: pfad)
                return nil
            }
            fehler = nil
            return daten
        } catch {
            Protokoll.fehler("Spotify \(methode) \(pfad): \(error.localizedDescription)")
            return nil
        }
    }

    /// Spotify legt den Grund in den Rumpf. Ihn wegzuwerfen und nur die Zahl zu
    /// protokollieren hat hier einen Nachmittag gekostet: eine 403 heisst bei
    /// Spotify fast nie „verboten", sondern fast immer „diese App steht noch im
    /// Entwicklungsmodus und dein Konto ist dort nicht eingetragen".
    private func melde(code: Int, rumpf: Data, antwort: URLResponse?, methode: String, pfad: String) {
        let grund = Self.grund(aus: rumpf)
        // Spotify legt den eigentlichen Hinweis gern in eine Kopfzeile statt in
        // den Rumpf; ohne die steht da nur „Forbidden" und man raet.
        let kopf = (antwort as? HTTPURLResponse)?.allHeaderFields
            .compactMap { schluessel, wert -> String? in
                let name = "\(schluessel)".lowercased()
                guard name.hasPrefix("www-") || name.hasPrefix("x-") else { return nil }
                return "\(name)=\(wert)"
            }.sorted().joined(separator: " ") ?? ""
        Protokoll.fehler("Spotify \(methode) \(pfad): HTTP \(code) — \(grund) [\(kopf)]")
        fehler = Self.klartext(code: code, grund: grund)
        if code == 403 { Task { await pruefeKonto() } }
    }

    /// Bei einer 403 einmal das Konto selbst abfragen (`GET /me`, braucht gar
    /// kein Recht). Geht auch das schief, liegt es nicht an der Bibliothek,
    /// sondern daran, dass Spotify dieses Konto in dieser App nicht zulaesst —
    /// und dann ist der Rat ein ganz anderer.
    private var kontoGeprueft = false

    private func pruefeKonto() async {
        guard !kontoGeprueft, let token = zugriff else { return }
        kontoGeprueft = true
        var anfrage = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        anfrage.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (daten, antwort) = try? await URLSession.shared.data(for: anfrage) else { return }
        let code = (antwort as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) {
            let objekt = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
            Protokoll.info("Spotify: Konto erreichbar (\(objekt?["id"] as? String ?? "?"))")
            // Liest sich die Bibliothek? Dann liegt es weder am Konto noch am
            // Token, sondern daran, dass diese App sie nicht aendern darf.
            var liste = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks?limit=1")!)
            liste.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let lesbar = (try? await URLSession.shared.data(for: liste))
                .map { (200..<300).contains(($0.1 as? HTTPURLResponse)?.statusCode ?? 0) } ?? false
            Protokoll.fehler("Spotify: Bibliothek lesbar: \(lesbar), aendern: nein")
            fehler = lesbar ? Self.appSperre : Self.kontoSperre
        } else {
            Protokoll.fehler("Spotify: auch GET me ist HTTP \(code) — \(Self.grund(aus: daten))")
            fehler = Self.kontoSperre
        }
    }

    /// Gemessen am 11.09.2026: `GET me/tracks` antwortet mit 200, aber
    /// `me/tracks/contains` und jedes `PUT`/`DELETE` auf `me/tracks` mit einer
    /// nackten 403 „Forbidden" — bei erteilten Rechten (`user-library-read
    /// user-library-modify`), frischem Token und erreichbarem Konto. Lesen
    /// erlaubt, Aendern nicht: das entscheidet Spotify an der App, nicht am
    /// Token, und im Code ist dagegen nichts auszurichten.
    static let appSperre =
        "Spotify laesst diese App die Bibliothek lesen, aber nicht aendern (403). "
      + "Am Konto liegt es nicht — dann wuerde auch das Lesen scheitern. Meist "
      + "heisst das, dass Spotify einen Endpunkt abgeloest hat; die Web API "
      + "aendert sich fuer Apps im Entwicklungsmodus regelmaessig. Sonst im "
      + "Dashboard pruefen, ob die App-Angaben vollstaendig sind."

    /// Der Grund, wenn selbst `GET /me` abgewiesen wird.
    static let kontoSperre =
        "Spotify laesst dein Konto in dieser App nicht zu. Eine App im Dashboard steht "
      + "im Entwicklungsmodus und gilt nur fuer ausdruecklich eingetragene Konten: "
      + "Dashboard -> deine App -> Settings -> User Management -> dein Spotify-Name und "
      + "deine Spotify-E-Mail eintragen. Danach in Saphir trennen und neu verbinden."


    private static func grund(aus rumpf: Data) -> String {
        guard let objekt = try? JSONSerialization.jsonObject(with: rumpf) as? [String: Any] else {
            return String(data: rumpf, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ohne Angabe"
        }
        if let fehler = objekt["error"] as? [String: Any],
           let text = fehler["message"] as? String { return text }
        if let text = objekt["error"] as? String { return text }
        return "ohne Angabe"
    }

    /// Was der Nutzer lesen soll. Spotifys eigener Satz steht dahinter, damit im
    /// Zweifel die Originalmeldung nachschlagbar bleibt.
    private static func klartext(code: Int, grund: String) -> String {
        let klein = grund.lowercased()
        if code == 403, klein.contains("not registered") || klein.contains("user may not") {
            return "Dein Spotify-Konto ist in deiner eigenen App noch nicht eingetragen. "
                 + "Im Spotify-Dashboard die App oeffnen, unter Settings -> User Management "
                 + "deine Spotify-E-Mail hinzufuegen. (\(grund))"
        }
        if code == 403, klein.contains("scope") {
            return "Die Rechte fehlen. In den Einstellungen trennen und neu verbinden, "
                 + "damit Spotify erneut fragt. (\(grund))"
        }
        if code == 403, klein.contains("premium") {
            return "Spotify erlaubt das nur mit Premium. (\(grund))"
        }
        if code == 429 { return "Spotify bremst gerade. Gleich noch einmal versuchen." }
        return "Spotify: \(grund) (HTTP \(code))"
    }

    // MARK: - Kleinkram

    private static func zufall(_ laenge: Int) -> String {
        let zeichen = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        return String((0..<laenge).map { _ in zeichen.randomElement()! })
    }

    private static func abdruck(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formular(_ felder: [String: String]) -> String {
        var erlaubt = CharacterSet.alphanumerics
        erlaubt.insert(charactersIn: "-._~")
        return felder.map { schluessel, wert in
            let w = wert.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? wert
            return "\(schluessel)=\(w)"
        }.joined(separator: "&")
    }
}

/// Was aus dem Browser zurueckkommt.
private enum Rueckweg {
    case code(String, String)   // Code und Kennzeichen
    case schiefgegangen(String)
}

/// Faengt den Rueckweg aus dem Browser ab: ein Zuhoerer auf 127.0.0.1, der
/// genau eine Anfrage beantwortet und dann wieder verschwindet.
private final class Rueckleitung {
    private let port: UInt16
    private var listener: NWListener?
    private var erledigt = false

    init(port: UInt16) { self.port = port }

    func warteAufCode(_ fertig: @escaping (Rueckweg) -> Void) {
        let melde: (Rueckweg) -> Void = { [weak self] ergebnis in
            guard let self, !self.erledigt else { return }
            self.erledigt = true
            self.listener?.cancel()
            self.listener = nil
            fertig(ergebnis)
        }

        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener = l
            l.newConnectionHandler = { verbindung in
                verbindung.start(queue: .main)
                verbindung.receive(minimumIncompleteLength: 1, maximumLength: 8192) { daten, _, _, _ in
                    let anfrage = daten.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let (text, ergebnis) = Self.lies(anfrage)
                    let seite = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html; charset=utf-8\r
                    Connection: close\r
                    \r
                    <!doctype html><meta charset="utf-8"><title>Saphir</title>
                    <body style="font:16px -apple-system;background:#111;color:#eee;
                    display:grid;place-items:center;height:100vh;margin:0">
                    <p>\(text)</p></body>
                    """
                    verbindung.send(content: Data(seite.utf8), completion: .contentProcessed { _ in
                        verbindung.cancel()
                    })
                    melde(ergebnis)
                }
            }
            l.start(queue: .main)
        } catch {
            melde(.schiefgegangen("Port \(port) ist belegt: \(error.localizedDescription)"))
        }

        // Wer den Browser einfach zumacht, soll nicht auf ewig einen offenen
        // Port hinterlassen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            melde(.schiefgegangen("Zeit abgelaufen."))
        }
    }

    /// Aus der ersten Zeile "GET /saphir?code=..&state=.. HTTP/1.1" die Werte
    /// ziehen. Mehr HTTP muss dieser Zuhoerer nicht koennen.
    private static func lies(_ anfrage: String) -> (String, Rueckweg) {
        guard let zeile = anfrage.components(separatedBy: "\r\n").first,
              let pfad = zeile.components(separatedBy: " ").dropFirst().first,
              let teile = URLComponents(string: "http://127.0.0.1\(pfad)") else {
            return ("Unverstaendliche Antwort.", .schiefgegangen("Unverstaendliche Antwort."))
        }
        let werte = teile.queryItems ?? []
        func wert(_ name: String) -> String? { werte.first { $0.name == name }?.value }

        if let grund = wert("error") {
            return ("Abgebrochen: \(grund)", .schiefgegangen("Spotify: \(grund)"))
        }
        guard let code = wert("code"), let stand = wert("state") else {
            return ("Da fehlt etwas.", .schiefgegangen("Antwort ohne Code."))
        }
        return ("Saphir ist mit Spotify verbunden. Du kannst dieses Fenster schliessen.",
                .code(code, stand))
    }
}

extension Notification.Name {
    static let saphirSpotifyVerbunden = Notification.Name("saphir.spotify.verbunden")
}
