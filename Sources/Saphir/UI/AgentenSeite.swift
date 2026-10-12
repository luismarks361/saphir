import AppKit
import SwiftUI

/// Die Einstellungsseite „Claude Code": Verbindung, Freigaben, Meldungen.
struct AgentenSeite: View {
    @ObservedObject private var dienst = AgentDienst.shared
    @ObservedObject private var o = AgentenOptionen.shared
    @ObservedObject private var e = Einstellungen.shared

    var body: some View {
        Ueberschrift("Claude Code")
        Text("""
        Zeigt die laufenden Claude-Code-Sessions in der Insel und laesst dich Freigaben \
        und Fragen dort beantworten, statt im Terminal. Dazu traegt Saphir kleine Hooks \
        in die Einstellungen von Claude Code ein. Alles bleibt auf diesem Mac.
        """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VerbindungKarte()

        if !e.istAn(.agenten) {
            Text("Die Funktion ist unter Funktionen ausgeschaltet. Dann laeuft auch der lokale Server nicht.")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Gruppe("Freigaben") {
            Toggle("Freigaben in der Insel beantworten", isOn: Binding(
                get: { o.freigabenInInsel }, set: { o.freigabenInInsel = $0 }))
            Text("Aus: Claude fragt wie gewohnt nur im Terminal.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Danach geht die Frage ans Terminal zurueck", selection: Binding(
                get: { o.freigabeFrist }, set: { o.freigabeFrist = $0 })) {
                Text("nach 30 Sekunden").tag(30.0)
                Text("nach 1 Minute").tag(60.0)
                Text("nach 3 Minuten").tag(180.0)
                Text("nach 10 Minuten").tag(600.0)
            }
            .frame(maxWidth: 420, alignment: .leading)
            Text("So bleibt nie etwas haengen, auch wenn du nicht am Mac bist.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if !o.immerErlaubt.isEmpty {
            Gruppe("Immer erlaubt") {
                ForEach(o.immerErlaubt, id: \.self) { regel in
                    HStack {
                        Text(regel).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button {
                            o.vergissImmerErlaubt(regel)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Regel vergessen")
                    }
                }
                Text("Diese Aufrufe laufen ohne Rueckfrage durch. Befehle, die etwas anhaengen oder umlenken, fragen trotzdem noch einmal.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Gruppe("Darstellung") {
            Toggle("Bei Freigaben automatisch aufklappen", isOn: Binding(
                get: { o.beiFreigabeAufklappen }, set: { o.beiFreigabeAufklappen = $0 }))
            Toggle("Bei fertigen Aufgaben kurz aufklappen", isOn: Binding(
                get: { o.beiFertigAufklappen }, set: { o.beiFertigAufklappen = $0 }))
            if o.beiFertigAufklappen {
                Picker("Dabei offen bleiben", selection: Binding(
                    get: { o.aufklappDauer }, set: { o.aufklappDauer = $0 })) {
                    Text("2 Sekunden").tag(2.0)
                    Text("4 Sekunden").tag(4.0)
                    Text("8 Sekunden").tag(8.0)
                    Text("15 Sekunden").tag(15.0)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
            Text("Freigaben und Fragen bleiben offen, bis du sie beantwortest.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Gruppe("Kontingent") {
            Toggle("Kontingent anzeigen und warnen", isOn: Binding(
                get: { o.kontingentZeigen }, set: { o.kontingentZeigen = $0 }))
            Text("""
            Zeigt die echten Prozente von Anthropic auch in der Statuszeile von Claude Code \
            und warnt in der Insel, wenn es knapp wird. Die Zahlen kommen aus der \
            Statuszeile, einen anderen Weg gibt es nicht. Aus: Saphir holt sie weiter, \
            druckt aber nichts.
            """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Gruppe("Meldungen") {
            Toggle("Systemmitteilung bei Freigabe, Rueckfrage und fertiger Aufgabe", isOn: Binding(
                get: { o.mitteilungen }, set: { o.mitteilungen = $0 }))
            Text("Fuer die Momente, in denen du gerade in einer anderen App oder auf einem anderen Schreibtisch bist. Die Toene folgen dem Schalter unter Allgemein.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ob Saphir mit Claude Code verbunden ist, und der Knopf dazu.
private struct VerbindungKarte: View {
    @ObservedObject private var dienst = AgentDienst.shared
    @ObservedObject private var o = AgentenOptionen.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(dienst.hooksEingetragen ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(dienst.hooksEingetragen ? "Mit Claude Code verbunden" : "Noch nicht verbunden")
                    .font(.body.weight(.medium))
                Spacer()
                if dienst.hooksEingetragen {
                    Button("Neu schreiben") { dienst.verbinde() }
                    Button("Trennen") { dienst.trenne() }
                } else {
                    Button("Mit Claude Code verbinden") { dienst.verbinde() }
                        .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 6) {
                Text("Lokaler Server")
                    .font(.caption).foregroundStyle(.secondary)
                Text(dienst.laeuft ? "127.0.0.1:\(dienst.port)" : "aus")
                    .font(.system(.caption, design: .monospaced))
            }

            if let fehler = dienst.fehler {
                Text(fehler).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("""
            Verbinden traegt Hooks und eine Statuszeile in ~/.claude/settings.json ein. \
            Was dort schon steht, bleibt: eine vorhandene Statuszeile wird weitergereicht, \
            und vor jeder Aenderung liegt eine Sicherung in ~/.saphir. Trennen nimmt alles \
            wieder heraus. Neu gestartete Sessions kennen die Hooks sofort, bereits \
            laufende erst nach einem Neustart.
            """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }
}

/// Ein Block mit Ueberschrift, wie auf den anderen Seiten.
private struct Gruppe<Inhalt: View>: View {
    let titel: String
    @ViewBuilder let inhalt: () -> Inhalt

    init(_ titel: String, @ViewBuilder inhalt: @escaping () -> Inhalt) {
        self.titel = titel
        self.inhalt = inhalt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel).font(.headline)
            inhalt()
        }
    }
}
