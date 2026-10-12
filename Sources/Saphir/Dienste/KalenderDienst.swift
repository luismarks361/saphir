import EventKit
import SwiftUI

struct Termin: Identifiable, Equatable {
    let id: String
    let titel: String
    let beginn: Date
    let ende: Date
    let ganztaegig: Bool
    let farbe: Color

    var laeuft: Bool { Date() >= beginn && Date() < ende }
    var inMinuten: Int { Int(beginn.timeIntervalSinceNow / 60) }
}

/// Die naechsten Termine.
///
/// Gezeigt wird, was heute und morgen noch kommt. Kurz vor einem Termin meldet
/// sich die Insel von selbst — das ist der eigentliche Zweck: nicht ein
/// Kalender in der Notch, sondern rechtzeitig Bescheid wissen.
@MainActor
final class KalenderDienst: ObservableObject {
    static let shared = KalenderDienst()

    @Published private(set) var termine: [Termin] = []
    @Published private(set) var darfLesen = false

    /// Wie lange vorher gewarnt wird.
    static let warnungMinuten = 5

    private let speicher = EKEventStore()
    private var takt: Timer?
    private var gewarnt: Set<String> = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: speicher, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lies() }
        }
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.kalender) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        frage()
        // Jede Minute: davon haengt die Warnung ab, und teuer ist es nicht.
        takt = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                KalenderDienst.shared.lies()
                KalenderDienst.shared.warneWennNoetig()
            }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        termine = []
        LiveAktivitaeten.shared.entferne("kalender")
    }

    private func frage() {
        speicher.requestFullAccessToEvents { [weak self] erlaubt, _ in
            Task { @MainActor in
                self?.darfLesen = erlaubt
                self?.lies()
            }
        }
    }

    func lies() {
        let stand = EKEventStore.authorizationStatus(for: .event)
        guard stand == .fullAccess else {
            if darfLesen { Protokoll.info("Kalender: keine Freigabe (Stand \(stand.rawValue))") }
            darfLesen = false
            return
        }
        darfLesen = true

        let jetzt = Date()
        let bis = Calendar.current.date(byAdding: .day, value: 2, to: jetzt) ?? jetzt
        let suche = speicher.predicateForEvents(withStart: jetzt.addingTimeInterval(-3600),
                                                end: bis, calendars: nil)
        let vorher = termine.count
        termine = speicher.events(matching: suche)
            .filter { $0.endDate > jetzt }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { ereignis in
                Termin(id: ereignis.eventIdentifier ?? UUID().uuidString,
                       titel: ereignis.title ?? "",
                       beginn: ereignis.startDate,
                       ende: ereignis.endDate,
                       ganztaegig: ereignis.isAllDay,
                       farbe: Color(nsColor: ereignis.calendar.color ?? .systemBlue))
            }
        if vorher != termine.count {
            Protokoll.info("Kalender: \(termine.count) Termine")
        }
    }

    /// Fuenf Minuten vorher zieht der Termin in die Insel ein und bleibt dort,
    /// bis er begonnen hat.
    private func warneWennNoetig() {
        let naechster = termine.first {
            !$0.ganztaegig && $0.inMinuten >= 0 && $0.inMinuten <= Self.warnungMinuten
        }
        guard let naechster else {
            LiveAktivitaeten.shared.entferne("kalender")
            return
        }
        LiveAktivitaeten.shared.zeige(LiveAktivitaet(
            id: "kalender", funktion: .kalender, prioritaet: 20,
            links: LiveInhalt(symbol: "calendar", farbe: naechster.farbe),
            rechts: LiveInhalt(text: "\(naechster.inMinuten) min", farbe: naechster.farbe)
        ))
    }

    /// Was unter dem Titel steht: Uhrzeitspanne, bei ganztaegigen Terminen das
    /// Datum, und ab morgen zusaetzlich der Wochentag.
    static func wann(_ termin: Termin) -> String {
        let heute = Calendar.current.isDateInToday(termin.beginn)
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")

        if termin.ganztaegig {
            f.dateFormat = heute ? "d. MMMM" : "EEEE, d. MMMM"
            return f.string(from: termin.beginn)
        }
        let spanne = "\(uhrzeit(termin.beginn)) – \(uhrzeit(termin.ende))"
        guard !heute else { return spanne }
        f.dateFormat = "EEEE"
        return "\(f.string(from: termin.beginn)) \(spanne)"
    }

    static func uhrzeit(_ datum: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: datum)
    }
}
