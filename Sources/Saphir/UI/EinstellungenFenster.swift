import AppKit
import SwiftUI

/// Das Einstellungsfenster. Ein gewoehnliches Fenster mit Seitenleiste — die
/// Insel selbst bleibt fuer die schnellen Schalter, hier steht das Ganze.
@MainActor
final class EinstellungenFenster: NSObject, NSWindowDelegate {
    static let shared = EinstellungenFenster()
    private var fenster: NSWindow?

    /// `bereich` schlaegt eine Seite der Seitenleiste auf (zum Beispiel "deckel").
    func zeigen(bereich: String? = nil) {
        if let bereich, let wahl = Bereich(rawValue: bereich) { BereichWahl.shared.bereich = wahl }
        if let fenster {
            fenster.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // NSHostingController, nicht NSHostingView: eine rohe Hosting-View als
        // contentView bleibt ohne Groesse und das Fenster bleibt leer.
        // Mindestgroesse als .frame statt preferredContentSize, siehe
        // WillkommenFenster — das Fenster darf hier trotzdem wachsen.
        let controller = NSHostingController(
            rootView: EinstellungenAnsicht().frame(minWidth: 760, minHeight: 540))

        let neu = NSWindow(contentViewController: controller)
        neu.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        neu.title = "Saphir"
        neu.setContentSize(NSSize(width: 760, height: 540))
        neu.center()
        neu.isReleasedWhenClosed = false
        neu.delegate = self
        fenster = neu

        neu.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Berechtigungen.shared.aktualisieren()
    }

    func windowWillClose(_ notification: Notification) {
        // Fenster behalten statt neu bauen: der Zustand der Seitenleiste bleibt.
    }
}

private enum Bereich: String, CaseIterable, Identifiable {
    case allgemein, funktionen, erweiterungen, agenten, deckel, freigaben, spotify, info
    var id: String { rawValue }

    var name: String {
        switch self {
        case .allgemein: return "Allgemein"
        case .funktionen: return "Funktionen"
        case .erweiterungen: return "Erweiterungen"
        case .agenten: return "Claude Code"
        case .deckel: return "Deckel zu"
        case .freigaben: return "Freigaben"
        case .spotify: return "Spotify"
        case .info: return "Ueber Saphir"
        }
    }

    var symbol: String {
        switch self {
        case .allgemein: return "gearshape"
        case .funktionen: return "square.grid.2x2"
        case .erweiterungen: return "puzzlepiece.extension"
        case .agenten: return "sparkle"
        case .deckel: return "laptopcomputer"
        case .freigaben: return "lock.shield"
        case .spotify: return "music.note.list"
        case .info: return "info.circle"
        }
    }
}

/// Welche Seite der Seitenleiste offen ist. Eigenes Objekt statt `@State`,
/// damit sich eine Seite auch von aussen aufschlagen laesst.
@MainActor
private final class BereichWahl: ObservableObject {
    static let shared = BereichWahl()
    @Published var bereich: Bereich = .allgemein
}

struct EinstellungenAnsicht: View {
    @ObservedObject private var wahl = BereichWahl.shared

    var body: some View {
        NavigationSplitView {
            List(Bereich.allCases, selection: $wahl.bereich) { b in
                Label(b.name, systemImage: b.symbol).tag(b)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch wahl.bereich {
                    case .allgemein: AllgemeinSeite()
                    case .funktionen: FunktionenSeite()
                    case .erweiterungen: ErweiterungenSeite()
                    case .agenten: AgentenSeite()
                    case .deckel: DeckelSeite()
                    case .freigaben: FreigabenSeite()
                    case .spotify: SpotifySeite()
                    case .info: InfoSeite()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AllgemeinSeite: View {
    @ObservedObject private var e = Einstellungen.shared

    var body: some View {
        Ueberschrift("Allgemein")

        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { e.startetBeimAnmelden }, set: { e.startetBeimAnmelden = $0 }))

        Toggle("Insel oeffnet sich, wenn die Maus darueber faehrt", isOn: Binding(
            get: { e.beiHoverOeffnen }, set: { e.beiHoverOeffnen = $0 }))

        Toggle("Klaenge", isOn: Binding(get: { e.klaengeAn }, set: { e.klaengeAn = $0 }))
        Toggle("Haptik auf dem Trackpad", isOn: Binding(get: { e.haptikAn }, set: { e.haptikAn = $0 }))

        Picker("Bildschirm", selection: Binding(
            get: { e.bildschirmWahl }, set: { e.bildschirmWahl = $0 })) {
            ForEach(BildschirmWahl.allCases, id: \.self) { Text($0.beschriftung).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

private struct FunktionenSeite: View {
    @ObservedObject private var e = Einstellungen.shared

    var body: some View {
        Ueberschrift("Funktionen")
        Text("Was aus ist, laeuft auch nicht im Hintergrund.")
            .font(.callout).foregroundStyle(.secondary)

        VStack(spacing: 0) {
            ForEach(Array(Funktion.gebaute.enumerated()), id: \.element.id) { index, f in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.body)
                        Text(f.erklaerung).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { e.istAn(f) }, set: { e.setze(f, an: $0) }))
                        .labelsHidden()
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }
}

private struct FreigabenSeite: View {
    @ObservedObject private var b = Berechtigungen.shared

    var body: some View {
        Ueberschrift("Freigaben")
        Text("macOS fragt jede Freigabe genau einmal. Danach fuehrt der Weg nur noch ueber die Systemeinstellungen.")
            .font(.callout).foregroundStyle(.secondary)

        VStack(spacing: 0) {
            ForEach(Array(Freigabe.allCases.enumerated()), id: \.element.id) { index, f in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    Kringel(stand: b.stand(f))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.body)
                        Text(f.wofuer).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(b.stand(f).text).font(.caption).foregroundStyle(.secondary)
                    Button("Erteilen") { b.anfragen(f) }
                        .disabled(b.stand(f) == .erteilt)
                    Button {
                        b.oeffneSystemeinstellungen(f)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .help("In den Systemeinstellungen oeffnen")
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))

        Button("Erneut pruefen") { b.aktualisieren() }
    }
}

private struct Kringel: View {
    let stand: Freigabestand

    var body: some View {
        Circle()
            .fill(farbe)
            .frame(width: 9, height: 9)
    }

    private var farbe: Color {
        switch stand {
        case .erteilt: return .green
        case .verweigert: return .orange
        case .ungefragt: return .secondary
        case .unbekannt: return .secondary.opacity(0.5)
        }
    }
}

/// Das Plus am Musik-Widget braucht ein eigenes Spotify-Konto — Spotifys
/// Skript-Schnittstelle kann nicht speichern, die Web-API schon, und die will
/// eine Anmeldung.
private struct SpotifySeite: View {
    @ObservedObject private var konto = SpotifyKonto.shared

    var body: some View {
        Ueberschrift("Spotify")
        Text("""
        Damit im Musik-Widget das Plus erscheint, mit dem ein Stueck in deine \
        Spotify-Bibliothek wandert. Ohne das hier bleibt alles andere am Widget \
        unveraendert.
        """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 12) {
            Schritt(1, "Auf developer.spotify.com eine App anlegen") {
                Button("Dashboard oeffnen") {
                    NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                }
            }

            Schritt(2, "Als Redirect URI genau diese Adresse eintragen") {
                HStack(spacing: 8) {
                    Text(SpotifyKonto.rueckleitung)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SpotifyKonto.rueckleitung, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Kopieren")
                }
            }

            Schritt(3, "Client-ID aus der App hierher") {
                TextField("Client-ID", text: $konto.clientId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))

        HStack(spacing: 12) {
            switch konto.stand {
            case .ohneKennung:
                Text("Client-ID fehlt noch").foregroundStyle(.secondary)
            case .getrennt:
                Button("Mit Spotify verbinden") { konto.verbinde() }
                    .buttonStyle(.borderedProminent)
            case .verbindet:
                ProgressView().controlSize(.small)
                Text("Warte auf den Browser ...").foregroundStyle(.secondary)
            case .verbunden:
                Label("Verbunden", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Trennen") { konto.trenne() }
            }
        }

        if let fehler = konto.fehler {
            Text(fehler).font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("""
        Saphir fragt nur die Rechte user-library-read und user-library-modify an: lesen \
        und aendern der eigenen Bibliothek, sonst nichts. Der Zugang liegt im \
        Schluesselbund, nicht in einer Datei.
        """)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Schritt<Inhalt: View>: View {
    let nummer: Int
    let text: String
    @ViewBuilder let inhalt: () -> Inhalt

    init(_ nummer: Int, _ text: String, @ViewBuilder inhalt: @escaping () -> Inhalt) {
        self.nummer = nummer
        self.text = text
        self.inhalt = inhalt
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(nummer)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                inhalt()
            }
        }
    }
}

private struct InfoSeite: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        Ueberschrift("Ueber Saphir")
        Text("Version \(version)")
        Text("""
        Saphir macht die Notch zur Bedienflaeche: laufende Vorgaenge links und rechts \
        der Kamera, Widgets darunter.

        Nachbau von Sapphire (sapphire-app.tech, AGPL-3.0). Die Claude-Sessions \
        stammen aus Agent Island. Face ID ist bewusst nicht dabei.

        Der Motor hinter "Deckel zu" stammt aus Insomnia von Krish Garg \
        (github.com/krishhgg/Insomnia, MIT-Lizenz, Copyright (c) 2026 Krish Garg).

        Alles laeuft lokal. Keine Cloud, keine Telemetrie, kein Konto.
        """)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct Ueberschrift: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title2).fontWeight(.semibold)
    }
}
