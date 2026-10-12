import AppKit
import Foundation
import SwiftUI

/// Was eine Session gerade tut. Dieselben sechs Zustaende wie in Agent Island,
/// damit die Insel nichts zeigt, was dort nicht auch steht.
enum AgentZustand: String {
    case idle
    case working
    case needsApproval
    case needsInput
    case done
    case failed

    var text: String {
        switch self {
        case .idle: return "bereit"
        case .working: return "arbeitet"
        case .needsApproval: return "wartet auf Freigabe"
        case .needsInput: return "braucht dich"
        case .done: return "fertig"
        case .failed: return "Fehler"
        }
    }

    /// Die Farben stammen aus Agent Island. Sie sind so gewaehlt, dass man sie im
    /// Augenwinkel liest: Gelb wartet, Blau arbeitet, Gruen ist fertig.
    var farbe: Color {
        switch self {
        case .idle: return Color(white: 0.45)
        case .working: return Color(red: 0.35, green: 0.66, blue: 0.98)
        case .needsApproval: return Color(red: 0.98, green: 0.72, blue: 0.20)
        case .needsInput: return Color(red: 0.98, green: 0.55, blue: 0.25)
        case .done: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .failed: return Color(red: 0.95, green: 0.35, blue: 0.38)
        }
    }

    /// Groesser heisst dringender. Bestimmt, welche Session oben steht und
    /// welcher Punkt neben der Kamera die Farbe angibt.
    var rang: Int {
        switch self {
        case .needsApproval: return 5
        case .needsInput: return 4
        case .failed: return 3
        case .working: return 2
        case .done: return 1
        case .idle: return 0
        }
    }
}

/// Eine Frage aus `AskUserQuestion`. In der Insel stehen nur die Bezeichnungen
/// der Auswahl — die Erklaerungen dazu passen dort nicht hin und stuenden
/// ohnehin schon im Terminal.
struct AgentFrage: Equatable, Identifiable {
    let frage: String
    let auswahl: [String]
    var id: String { frage }
}

/// Was gerade auf eine Entscheidung wartet.
struct AgentFreigabe: Equatable {
    enum Art: String { case permission, plan, question }
    /// Kennung der Anfrage. Zwei Freigaben nacheinander in derselben Session
    /// sind zwei Ereignisse, auch wenn die Session dieselbe bleibt.
    let anfrage: String
    let art: Art
    let werkzeug: String
    let fragen: [AgentFrage]

    /// Der Satz ueber den Knoepfen. Kein Erklaertext, sondern das, worum es geht.
    var ueberschrift: String {
        switch art {
        case .plan: return "Plan freigeben"
        case .question: return fragen.first?.frage ?? "Frage"
        case .permission: return werkzeug
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    /// Typografisches Zeichen des Agenten. Claude bekommt stattdessen seine
    /// echte Marke, siehe `AgentMarke`.
    let zeichen: String
    let istClaude: Bool
    let name: String
    let zustand: AgentZustand
    let taetigkeit: String?
    let freigabe: AgentFreigabe?
}

/// Anthropics eigene Zahlen. Sie stehen nirgends sonst auf der Platte: einziger
/// Kanal ist das Feld `rate_limits` im Statusline-Payload, und der Motor legt den
/// letzten Stand in `~/.saphir/rate-limits.json` ab. Deshalb wird nichts
/// geschaetzt — eine Rechnung aus den Transcripts lag gemessen um
/// Groessenordnungen daneben.
struct Kontingent: Equatable {
    struct Fenster: Equatable {
        let verbraucht: Int
        let resetAm: Date

        var frei: Int { max(0, min(100, 100 - verbraucht)) }
        var laeuft: Bool { Date() < resetAm }
    }

    let fuenfStunden: Fenster?
    let woche: Fenster?
    let standVon: Date

    /// Hat laenger niemand Claude Code offen gehabt, sind die Zahlen alt. Alte
    /// Zahlen koennen den Verbrauch nur unterschaetzen, das soll man sehen.
    var veraltet: Bool { Date().timeIntervalSince(standVon) > 15 * 60 }
}

/// Die Claude-Sessions in der Insel.
///
/// Der Dienst haelt den Motor (`AgentenMotor`) und den lokalen Server, an den die
/// Hooks von Claude Code ihre Ereignisse schicken, und uebersetzt den Stand des
/// Motors in das, was die Insel zeigt. Saphir ist damit eigenstaendig: es braucht
/// keine zweite App, die die Hooks bedient.
///
/// Der Hook `PermissionRequest` kann nur von *einer* App bedient werden. Laeuft
/// neben Saphir noch ein anderes Programm, das sich dort eingetragen hat, fragen
/// beide, und es antwortet, wer zuerst da ist.
@MainActor
final class AgentDienst: ObservableObject {
    static let shared = AgentDienst()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var kontingent: Kontingent?
    /// Ob der lokale Server laeuft und Hooks annimmt.
    @Published private(set) var laeuft = false
    /// Ob die Hooks von Saphir in Claudes Einstellungen stehen.
    @Published private(set) var hooksEingetragen = false
    @Published private(set) var port: UInt16 = 0
    /// Der letzte Fehler beim Eintragen oder Entfernen, fuer die Einstellungen.
    @Published private(set) var fehler: String?

    /// Was bereits entschieden wurde, und wie. Bleibt stehen, bis die Session
    /// die Freigabe selbst zurueckzieht — sonst huepft der Knopf zwischen
    /// „gedrueckt" und „wartet".
    @Published private(set) var entschieden: [String: String] = [:]
    /// Beantwortete Fragen einer laufenden `AskUserQuestion`.
    @Published private(set) var antworten: [String: String] = [:]

    /// Meldet, dass eine Freigabe ansteht, die vorher nicht anstand.
    var freigabeKamAn: (() -> Void)?
    /// Meldet, dass die Freigabe vom Tisch ist — entschieden, abgelaufen oder
    /// im Terminal beantwortet.
    var freigabeVorbei: (() -> Void)?
    /// Etwas Sehenswertes ohne Frage: kurz aufklappen, so viele Sekunden lang.
    var kurzZeigen: ((Double) -> Void)?
    /// Eine Zeile unter der Notch (Symbol, Text, Sekunden).
    var hinweis: ((String, String, Double) -> Void)?
    /// Auf- oder zuklappen von aussen, per `POST /panel`.
    var panel: ((Bool, Bool?) -> Void)?

    private let motor = AgentenMotor.shared
    private var server: HTTPServer?
    private var letzteAnfrage: String?
    private var letzteSession: String?
    private var wartendeSessions: Set<String> = []
    /// Bis hierhin zeigt die Insel die Quittung eines Knopfdrucks, bevor die
    /// erledigte Freigabe verschwindet.
    private var haltBis: Date?
    private var haltPlan: DispatchWorkItem?

    /// Wie lange eine Quittung stehen bleibt: lang genug, den Haken zu sehen.
    private static let quittungsDauer = 0.9

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
        motor.beiAenderung = { [weak self] in self?.uebernehme() }
        motor.beiKurzZeigen = { [weak self] sekunden in self?.kurzZeigen?(sekunden) }
        motor.beiHinweis = { [weak self] symbol, text, sekunden in self?.hinweis?(symbol, text, sekunden) }
        motor.beiPanel = { [weak self] auf, anheften in self?.panel?(auf, anheften) }
    }

    /// Die Session, deren Zustand die eingeklappte Insel faerbt.
    var vorderste: AgentSession? {
        sessions.max { $0.zustand.rang < $1.zustand.rang }
    }

    /// Die Freigabe, die gerade beantwortet werden will. Es ist immer hoechstens
    /// eine: Claude haelt den Hook offen, bis entschieden ist.
    var offeneFreigabe: AgentSession? {
        sessions.first { $0.freigabe != nil }
    }

    var hatFreigabe: Bool { offeneFreigabe != nil }

    // MARK: - Start und Ende

    func taktPruefen() {
        if Einstellungen.shared.istAn(.agenten) { starte() } else { stoppe() }
    }

    private func starte() {
        guard server == nil else { return }
        let neu = HTTPServer()
        do {
            try neu.start()
        } catch {
            Protokoll.fehler("Agenten-Server startet nicht: \(error.localizedDescription)")
            fehler = "Der lokale Server startet nicht: \(error.localizedDescription)"
            return
        }
        server = neu
        port = neu.port
        motor.serverPort = neu.port
        laeuft = true

        SessionIndex.startWatching { [weak self] in
            self?.motor.refreshTitles()
        }
        motor.rateLimits = RateLimits.load()

        // Verbunden heisst: der Nutzer hat es einmal gewollt. Dann bleibt das
        // Skript auf dem neuesten Stand, auch wenn die App verschoben oder
        // aktualisiert wurde. Vorher fasst Saphir `~/.claude` nicht an.
        if AgentenOptionen.shared.verbunden {
            schreibeVerbindung()
            NotifCenter.shared.requestAuthorization()
        }
        hooksEingetragen = HookInstaller.isInstalled
        uebernehme()
    }

    private func stoppe() {
        server?.stop()
        server = nil
        laeuft = false
        port = 0
        SessionIndex.stopWatching()
        sessions = []
        kontingent = nil
        letzteAnfrage = nil
        letzteSession = nil
        LiveAktivitaeten.shared.entferne("agenten")
    }

    /// Beim Beenden der App: der Server geht, damit die Hooks sauber ins Leere
    /// laufen und Claude wie gewohnt im Terminal fragt.
    func beende() {
        server?.stop()
        server = nil
    }

    // MARK: - Mit Claude Code verbinden

    /// Traegt Hooks und Statuszeile in `~/.claude/settings.json` ein. Vorhandene
    /// Eintraege bleiben, vorher gibt es eine Sicherung.
    func verbinde() {
        AgentenOptionen.shared.verbunden = true
        schreibeVerbindung()
        NotifCenter.shared.requestAuthorization()
        hooksEingetragen = HookInstaller.isInstalled
    }

    /// Nimmt beides wieder heraus. Eine Statuszeile, die es vorher gab, kommt
    /// zurueck.
    func trenne() {
        AgentenOptionen.shared.verbunden = false
        do {
            try HookInstaller.uninstall()
            try StatuslineInstaller.uninstall()
            fehler = nil
        } catch {
            Protokoll.fehler("Trennen: \(error.localizedDescription)")
            fehler = error.localizedDescription
        }
        hooksEingetragen = HookInstaller.isInstalled
    }

    private func schreibeVerbindung() {
        do {
            try HookInstaller.install()
            try StatuslineInstaller.install()
            fehler = nil
        } catch {
            Protokoll.fehler("Verbinden: \(error.localizedDescription)")
            fehler = error.localizedDescription
        }
    }

    // MARK: - Lesen

    /// Uebersetzt den Stand des Motors in das, was die Insel zeigt. Der Motor
    /// ruft das nach jeder Aenderung.
    private func uebernehme() {
        // Eine eben beantwortete Freigabe soll mit ihrer Quittung noch kurz da
        // sein, statt im selben Augenblick zu verschwinden.
        if let bis = haltBis, Date() < bis {
            guard haltPlan == nil else { return }
            let plan = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.haltPlan = nil
                    self?.haltBis = nil
                    self?.uebernehme()
                }
            }
            haltPlan = plan
            DispatchQueue.main.asyncAfter(deadline: .now() + bis.timeIntervalSinceNow, execute: plan)
            return
        }

        kontingent = Self.kontingent(motor.rateLimits)
        setze(sessions: motor.sessions.map(Self.anzeige))
        meldeNeueAufmerksamkeit()
    }

    private func setze(sessions neu: [AgentSession]) {
        // Dringendes zuerst, sonst steht die wartende Freigabe unter drei
        // arbeitenden Sessions.
        let sortiert = neu.sorted { ($0.zustand.rang, $0.name) > ($1.zustand.rang, $1.name) }
        if sessions != sortiert { sessions = sortiert }

        let anfrage = offeneFreigabe?.freigabe?.anfrage
        if anfrage != letzteAnfrage {
            // Eine erledigte Freigabe raeumt ihre Quittung mit weg.
            if let alt = letzteSession { entschieden[alt] = nil }
            antworten = [:]
            letzteAnfrage = anfrage
            letzteSession = offeneFreigabe?.id
            if anfrage != nil {
                // Dasselbe Klopfen wie bei einer Erinnerung. Die Insel gibt
                // ungefragt Laut, also bleibt es bei dem einen Klang.
                Klang.spiele(.erinnerung)
                if AgentenOptionen.shared.beiFreigabeAufklappen { freigabeKamAn?() }
            } else {
                freigabeVorbei?()
            }
        }
        meldeLiveAktivitaet()
    }

    /// Eine Session, die dich im Terminal braucht, klappt die Insel kurz auf.
    /// Beantworten laesst sich das dort nicht, aber man soll es merken.
    private func meldeNeueAufmerksamkeit() {
        let jetzt = Set(sessions.filter { $0.zustand == .needsInput }.map(\.id))
        let neu = jetzt.subtracting(wartendeSessions)
        wartendeSessions = jetzt
        guard !neu.isEmpty, AgentenOptionen.shared.beiFertigAufklappen else { return }
        kurzZeigen?(AgentenOptionen.shared.aufklappDauer)
    }

    private static func anzeige(_ s: MotorSession) -> AgentSession {
        AgentSession(
            id: s.id,
            zeichen: s.agent.glyph,
            istClaude: s.agent == .claude,
            name: s.displayName,
            zustand: s.state,
            taetigkeit: s.activity,
            freigabe: s.pending.map(anzeige)
        )
    }

    private static func anzeige(_ p: PendingDecision) -> AgentFreigabe {
        AgentFreigabe(
            anfrage: p.id,
            art: AgentFreigabe.Art(rawValue: p.kind.rawValue) ?? .permission,
            werkzeug: p.toolName,
            fragen: p.questions.map { AgentFrage(frage: $0.question, auswahl: $0.options.map(\.label)) }
        )
    }

    private static func kontingent(_ limits: RateLimits?) -> Kontingent? {
        guard let limits else { return nil }
        func fenster(_ w: RateLimits.Window?) -> Kontingent.Fenster? {
            w.map { Kontingent.Fenster(verbraucht: $0.usedPercentage, resetAm: $0.resetsAt) }
        }
        let fuenf = fenster(limits.fiveHour)
        let woche = fenster(limits.sevenDay)
        guard fuenf != nil || woche != nil else { return nil }
        return Kontingent(fuenfStunden: fuenf, woche: woche, standVon: limits.capturedAt)
    }

    // MARK: - Entscheiden

    /// `allow`, `deny` oder `always`. Die Quittung steht sofort und bleibt einen
    /// Moment stehen — der Knopf soll auf den Druck antworten.
    func entscheide(_ session: AgentSession, _ wahl: String) {
        entschieden[session.id] = wahl
        Klang.spiele(wahl == "deny" ? .zu : .abgelegt)
        halteQuittung()
        motor.decide(sessionID: session.id, decision: wahl, reason: nil)
    }

    /// Eine Frage beantworten. Erst wenn alle beantwortet sind, geht die Antwort
    /// hinaus — Claude wartet auf den vollstaendigen Satz.
    func beantworte(_ session: AgentSession, frage: AgentFrage, mit label: String) {
        antworten[frage.frage] = label
        guard let alle = session.freigabe?.fragen,
              alle.allSatisfy({ antworten[$0.frage] != nil }) else { return }
        entschieden[session.id] = "answer"
        Klang.spiele(.abgelegt)
        halteQuittung()
        motor.decide(sessionID: session.id, decision: "answer", reason: nil, answers: antworten)
    }

    func springe(zu session: AgentSession) {
        motor.jump(to: session.id)
    }

    private func halteQuittung() {
        haltBis = Date().addingTimeInterval(Self.quittungsDauer)
    }

    // MARK: - Neben der Kamera

    private func meldeLiveAktivitaet() {
        guard !sessions.isEmpty, let vorne = vorderste else {
            LiveAktivitaeten.shared.entferne("agenten")
            return
        }

        // Ein Punkt je Session, in der Farbe ihres Zustands. Kein Text: neben der
        // Kamera ist kein Platz, und die Farbe sagt es schneller.
        let punkte = sessions.map(\.zustand.farbe)
        let wartet = hatFreigabe

        LiveAktivitaeten.shared.zeige(LiveAktivitaet(
            id: "agenten",
            funktion: .agenten,
            // Eine anstehende Freigabe ist das Dringlichste, was die Insel je
            // zeigt, und schlaegt darum auch den Kalender (20). Laufende
            // Sessions treten hinter die Musik (10) zurueck: die aendert sich
            // staendig und will gesehen werden, Sessions warten geduldig.
            prioritaet: wartet ? 30 : 8,
            links: LiveInhalt(symbol: vorne.istClaude ? nil : vorne.zeichen,
                              marke: vorne.istClaude ? .claude : nil,
                              farbe: vorne.zustand.farbe),
            rechts: LiveInhalt(farbe: vorne.zustand.farbe, punkte: punkte)
        ))
    }
}

/// Welches Zeichen vor einer Session steht.
///
/// Claude traegt seine echte Marke (`Resources/ClaudeMark.png`), alle anderen ihr
/// typografisches Zeichen. Der Grundsatz dahinter: die Marke soll echt sein oder
/// gar nicht da.
enum AgentMarke {
    /// Das Orange der Claude-Marke. Die Marke traegt es ueberall, auch neben der
    /// Kamera: der Zustand steht dort in den Punkten, nicht in der Marke.
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.28)

    /// Als Schablone geladen, damit sie sich einfaerben laesst. Fehlt die Datei,
    /// faellt alles auf das Zeichen zurueck.
    static let claude: NSImage? = {
        guard let pfad = Bundle.main.path(forResource: "ClaudeMark", ofType: "png"),
              let bild = NSImage(contentsOfFile: pfad) else { return nil }
        bild.isTemplate = true
        return bild
    }()
}
