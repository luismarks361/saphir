import Foundation
import SwiftUI

struct Notiz: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var wann: Date
}

/// Schnellnotizen. Liegen als eine Datei in ~/.saphir und ueberleben den
/// Neustart — anders als die Zwischenablage, die bewusst nur im Arbeitsspeicher
/// steht.
@MainActor
final class NotizDienst: ObservableObject {
    static let shared = NotizDienst()

    @Published private(set) var notizen: [Notiz] = []

    private var datei: URL { Ablage.ordner.appendingPathComponent("notizen.json") }

    private init() { lade() }

    func schreibe(_ text: String) {
        let sauber = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sauber.isEmpty else { return }
        notizen.insert(Notiz(id: UUID(), text: sauber, wann: Date()), at: 0)
        sichere()
    }

    func entferne(_ notiz: Notiz) {
        notizen.removeAll { $0.id == notiz.id }
        sichere()
    }

    private func lade() {
        guard let daten = try? Data(contentsOf: datei),
              let gelesen = try? JSONDecoder().decode([Notiz].self, from: daten) else { return }
        notizen = gelesen
    }

    private func sichere() {
        Ablage.anlegen()
        guard let daten = try? JSONEncoder().encode(notizen) else { return }
        try? daten.write(to: datei, options: .atomic)
    }
}
