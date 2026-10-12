import SwiftUI

/// Eine Kachel auf der aufgeklappten Flaeche.
struct WidgetKachel: Identifiable {
    let id: String
    /// Zu welcher Funktion sie gehoert. Ist die aus, erscheint sie nicht.
    let funktion: Funktion
    let titel: String
    let symbol: String
    /// Wie breit sie im Raster liegt: 1 = halb, 2 = ganz.
    var spalten: Int = 1
    /// Kleiner heisst weiter oben.
    var reihenfolge: Int = 0
    let inhalt: () -> AnyView
}

/// Wo sich Widgets eintragen.
///
/// Die Widgets melden sich beim Start selbst an, statt dass eine Liste
/// irgendwo alle kennt — sonst muesste jede neue Funktion an zwei Stellen
/// eingetragen werden und die zweite wird vergessen.
@MainActor
final class WidgetRegister: ObservableObject {
    static let shared = WidgetRegister()

    @Published private(set) var kacheln: [WidgetKachel] = []

    private init() {}

    func melde(_ kachel: WidgetKachel) {
        kacheln.removeAll { $0.id == kachel.id }
        kacheln.append(kachel)
        kacheln.sort { ($0.reihenfolge, $0.id) < ($1.reihenfolge, $1.id) }
    }

    func entferne(_ id: String) {
        kacheln.removeAll { $0.id == id }
    }

    var sichtbare: [WidgetKachel] {
        kacheln.filter { Einstellungen.shared.istAn($0.funktion) }
    }
}
