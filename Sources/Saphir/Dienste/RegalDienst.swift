import AppKit
import SwiftUI

/// Ein Stueck im Regal.
struct RegalStueck: Identifiable, Codable, Equatable {
    let id: UUID
    /// Die Kopie, die Saphir haelt. Sie wird herausgezogen, nicht das Original.
    var ablage: URL
    /// Woher es kam. Nur zum Nachschauen im Finder.
    var herkunft: URL
    let wann: Date

    var name: String { ablage.lastPathComponent }
    var symbolbild: NSImage { NSWorkspace.shared.icon(forFile: ablage.path) }
}

/// Das Datei-Regal: was in die Notch gezogen wurde, liegt hier.
///
/// Saphir legt eine KOPIE unter ~/.saphir/regal ab, statt nur auf das Original
/// zu zeigen. Sonst waere das Regal leer, sobald der Ordner Downloads
/// aufgeraeumt wird — und genau dafuer ist es da. Nichts verfaellt von selbst;
/// weggeraeumt wird, was der Nutzer wegraeumt.
@MainActor
final class RegalDienst: ObservableObject {
    static let shared = RegalDienst()

    @Published private(set) var stuecke: [RegalStueck] = []

    private var liste: URL { Ablage.ordner.appendingPathComponent("regal.json") }

    private init() {
        lade()
    }

    /// Legt Dateien ins Regal. Das Kopieren laeuft abseits, damit ein grosses
    /// Video die Insel nicht einfriert.
    func lege(_ quellen: [URL]) {
        guard !quellen.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var neue: [RegalStueck] = []
            for quelle in quellen {
                guard let stueck = await Self.kopiere(quelle) else { continue }
                neue.append(stueck)
            }
            let fertige = neue
            await MainActor.run {
                guard !fertige.isEmpty else { return }
                RegalDienst.shared.stuecke.insert(contentsOf: fertige, at: 0)
                RegalDienst.shared.sichere()
                Klang.spiele(.abgelegt)
            }
        }
    }

    func entferne(_ stueck: RegalStueck) {
        stuecke.removeAll { $0.id == stueck.id }
        try? FileManager.default.removeItem(at: stueck.ablage.deletingLastPathComponent())
        sichere()
    }

    func zeigeImFinder(_ stueck: RegalStueck) {
        NSWorkspace.shared.activateFileViewerSelecting([stueck.ablage])
    }

    func oeffne(_ stueck: RegalStueck) {
        NSWorkspace.shared.open(stueck.ablage)
    }

    // MARK: - Ablage

    /// Jedes Stueck bekommt einen eigenen Unterordner. Nur so behaelt es seinen
    /// Namen, auch wenn zweimal dasselbe „Rechnung.pdf" hereinkommt.
    private nonisolated static func kopiere(_ quelle: URL) async -> RegalStueck? {
        let id = UUID()
        let ordner = Ablage.regal.appendingPathComponent(id.uuidString, isDirectory: true)
        let ziel = ordner.appendingPathComponent(quelle.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: quelle, to: ziel)
        } catch {
            Protokoll.fehler("Regal: \(quelle.lastPathComponent) liess sich nicht ablegen: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: ordner)
            return nil
        }
        return RegalStueck(id: id, ablage: ziel, herkunft: quelle, wann: Date())
    }

    private func lade() {
        guard let daten = try? Data(contentsOf: liste),
              let gelesen = try? JSONDecoder().decode([RegalStueck].self, from: daten) else { return }
        // Was von Hand geloescht wurde, steht nicht mehr im Regal.
        stuecke = gelesen.filter { FileManager.default.fileExists(atPath: $0.ablage.path) }
    }

    private func sichere() {
        Ablage.anlegen()
        try? FileManager.default.createDirectory(at: Ablage.regal, withIntermediateDirectories: true)
        guard let daten = try? JSONEncoder().encode(stuecke) else { return }
        try? daten.write(to: liste, options: .atomic)
    }
}
