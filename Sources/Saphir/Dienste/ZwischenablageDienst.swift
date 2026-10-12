import AppKit
import SwiftUI

struct Ablagestueck: Identifiable, Equatable {
    let id: UUID
    let text: String
    let wann: Date
}

/// Der Verlauf der Zwischenablage.
///
/// Gehalten wird nur Text und nur im Arbeitsspeicher: was kopiert wird, sind
/// oft Passwoerter und Zugangsdaten, und die haben auf der Platte nichts zu
/// suchen. Mit dem Beenden von Saphir ist der Verlauf weg.
@MainActor
final class ZwischenablageDienst: ObservableObject {
    static let shared = ZwischenablageDienst()

    @Published private(set) var stuecke: [Ablagestueck] = []

    static let hoechstens = 20

    private let brett = NSPasteboard.general
    private var standVorher = 0
    private var takt: Timer?
    /// Was Saphir selbst einsetzt, soll nicht als neuer Eintrag zurueckkommen.
    private var eigenerText: String?

    private init() {
        standVorher = brett.changeCount
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.zwischenablage) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        // Zwei Blicke je Sekunde. NSPasteboard meldet keine Aenderung, es gibt
        // nur den Zaehler zum Nachsehen.
        takt = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ZwischenablageDienst.shared.sieheNach() }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        stuecke = []
    }

    private func sieheNach() {
        guard brett.changeCount != standVorher else { return }
        standVorher = brett.changeCount
        guard let text = brett.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text != eigenerText else { return }
        guard stuecke.first?.text != text else { return }

        stuecke.removeAll { $0.text == text }
        stuecke.insert(Ablagestueck(id: UUID(), text: text, wann: Date()), at: 0)
        if stuecke.count > Self.hoechstens { stuecke.removeLast(stuecke.count - Self.hoechstens) }
    }

    func setzeEin(_ stueck: Ablagestueck) {
        eigenerText = stueck.text
        brett.clearContents()
        brett.setString(stueck.text, forType: .string)
        standVorher = brett.changeCount
        stuecke.removeAll { $0.id == stueck.id }
        stuecke.insert(stueck, at: 0)
    }

    func entferne(_ stueck: Ablagestueck) {
        stuecke.removeAll { $0.id == stueck.id }
    }

    func leere() { stuecke = [] }
}
