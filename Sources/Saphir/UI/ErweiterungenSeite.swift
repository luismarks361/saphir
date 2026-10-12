import AppKit
import SwiftUI

/// Die Erweiterungen aus `~/.saphir/plugins`: ein- und ausschalten, ihre
/// Zugangsdaten eintragen, sehen, ob sie antworten.
struct ErweiterungenSeite: View {
    @ObservedObject private var verwalter = PluginVerwalter.shared

    var body: some View {
        Ueberschrift("Erweiterungen")

        if verwalter.plugins.isEmpty {
            Text("Noch keine Erweiterung in ~/.saphir/plugins.")
                .font(.callout).foregroundStyle(.secondary)
        }

        ForEach(verwalter.plugins) { info in
            PluginKarte(info: info)
        }

        HStack(spacing: 10) {
            Button("Neu einlesen") { verwalter.neuEinlesen() }
            Button("Ordner oeffnen") {
                try? FileManager.default.createDirectory(
                    at: PluginVerwalter.standardOrdner, withIntermediateDirectories: true)
                NSWorkspace.shared.open(PluginVerwalter.standardOrdner)
            }
        }
    }
}

private struct PluginKarte: View {
    let info: PluginInfo
    @ObservedObject private var verwalter = PluginVerwalter.shared

    private var stand: PluginStand { verwalter.stand[info.id] ?? .aus }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: info.manifest?.symbol ?? "puzzlepiece.extension")
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.body)
                    Text(untertitel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if info.manifest != nil {
                    Toggle("", isOn: Binding(
                        get: { verwalter.istAn(info.id) },
                        set: { verwalter.setzeAn(info.id, $0) }))
                        .labelsHidden()
                }
            }

            if let mangel = info.mangel {
                Text(mangel).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let manifest = info.manifest {
                ForEach(manifest.felder) { feld in
                    FeldZeile(plugin: info.id, feld: feld)
                }
                if verwalter.istAn(info.id) {
                    Button("Jetzt abfragen") { verwalter.frageAb(info.id) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    private var untertitel: String {
        switch stand {
        case .aus: return info.manifest.map { "Version \($0.version ?? "?"), aus" } ?? info.id
        case .wartet: return "Wartet auf die erste Antwort"
        case .ok(let wann): return "Letzte Antwort um \(Self.uhr.string(from: wann))"
        case .fehler(let text): return text
        }
    }

    private static let uhr: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct FeldZeile: View {
    let plugin: String
    let feld: PluginManifest.Feld
    @State private var eingabe: String

    init(plugin: String, feld: PluginManifest.Feld) {
        self.plugin = plugin
        self.feld = feld
        _eingabe = State(initialValue: PluginVerwalter.shared.wert(plugin, feld))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(feld.name).frame(width: 110, alignment: .leading)
            Group {
                if feld.typ == .geheim {
                    SecureField("", text: $eingabe)
                } else {
                    TextField("", text: $eingabe)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
            .onChange(of: eingabe) { _, neu in
                PluginVerwalter.shared.setzeWert(plugin, feld, neu)
            }
        }
    }
}
