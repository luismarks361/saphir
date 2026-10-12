import SwiftUI

/// Die Musik-Kachel: Cover, Titel, Steuerung, Fortschritt zum Ziehen.
struct MusikWidget: View {
    @ObservedObject private var dienst = MusikDienst.shared
    /// Waehrend gezogen wird, gilt dieser Wert statt der gemeldeten Position —
    /// sonst zuckt der Griff bei jedem Takt zurueck.
    @State private var zieht: Double?

    var body: some View {
        if let jetzt = dienst.jetzt {
            HStack(spacing: 12) {
                Cover(bild: dienst.cover, schein: dienst.coverFarbe)
                    .zurApp(jetzt.app)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            // Maße des Originals (`MusicPlayerViews`): Titel 15
                            // halbfett abgerundet, Kuenstler 12 mittel abgerundet.
                            Text(jetzt.titel)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Text(jetzt.kuenstler)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zurApp(jetzt.app)

                        Bibliothek(uri: jetzt.stueckId, farbe: dienst.coverFarbe)
                    }

                    Fortschritt(jetzt: jetzt, farbe: dienst.coverFarbe, zieht: $zieht)

                    // Mittig unter dem Wiedergabebalken, nicht linksbuendig.
                    HStack(spacing: 18) {
                        Knopf("backward.fill") { dienst.zurueck() }
                        Knopf(jetzt.laeuft ? "pause.fill" : "play.fill", gross: true) {
                            dienst.abspielenPause()
                        }
                        Knopf("forward.fill") { dienst.weiter() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            LeereFlaeche(symbol: "music.note")
        }
    }
}

/// Das Plus neben dem Titel — dasselbe wie das Plus in Spotify selbst.
///
/// Steht nur da, wenn ein Spotify-Konto verbunden ist und wirklich ein Stueck
/// laeuft (kein Podcast, keine lokale Datei). Gespeichert heisst: gleicher
/// Knopf, gleiche Groesse, nur Haken statt Plus und die Farbe des Covers.
private struct Bibliothek: View {
    @ObservedObject private var konto = SpotifyKonto.shared
    let uri: String
    let farbe: Color

    var body: some View {
        if konto.stand == .verbunden, SpotifyKonto.stueckKennung(uri) != nil {
            let drin = konto.gespeichert ?? false
            // Hat Spotify den letzten Druck abgewiesen, faellt der Knopf sichtbar
            // zurueck: gleiche Form, gleiche Groesse, nur die Farbe sagt, dass es
            // nicht geklappt hat. Warum es nicht geklappt hat, steht in den
            // Einstellungen — in der Insel steht kein Erklaertext.
            let abgewiesen = konto.abgewiesen == uri
            Button {
                if !drin { Klang.spiele(.abgelegt) }
                konto.umschalten(uri: uri)
            } label: {
                Image(systemName: drin ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .glasKreis(kraft: drin ? 1.3 : 0.8)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(abgewiesen ? Color(red: 0.95, green: 0.35, blue: 0.38)
                             : drin ? farbe : .white.opacity(0.7))
            .animation(.snappy(duration: 0.18), value: drin)
            .animation(.snappy(duration: 0.18), value: abgewiesen)
            .help(abgewiesen ? "Spotify hat das abgelehnt — siehe Einstellungen, Spotify"
                  : drin ? "Aus der Spotify-Bibliothek entfernen"
                  : "Zur Spotify-Bibliothek hinzufuegen")
        }
    }
}

private struct Cover: View {
    let bild: NSImage?
    /// Die tragende Farbe des Covers. Sie leuchtet nur hier, hinter dem Bild,
    /// und nur solange die Insel offen ist — an der eingeklappten Insel bleibt
    /// die Notch unberuehrt.
    let schein: Color

    var body: some View {
        ZStack {
            if let bild {
                Image(nsImage: bild).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.09))
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        // Bewusst groesser als im Original.
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Fortschrittsleiste, die sich ziehen laesst.
private struct Fortschritt: View {
    let jetzt: Wiedergabe
    /// Die tragende Farbe des Covers — wie im Original faerbt sie die Leiste.
    let farbe: Color
    @Binding var zieht: Double?

    private var anteil: Double {
        if let zieht, jetzt.dauer > 0 { return min(max(zieht / jetzt.dauer, 0), 1) }
        return jetzt.anteil
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(farbe)
                        .frame(width: max(2, geo.size.width * anteil))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { wert in
                            let a = min(max(wert.location.x / geo.size.width, 0), 1)
                            zieht = a * jetzt.dauer
                        }
                        .onEnded { _ in
                            if let ziel = zieht { MusikDienst.shared.springeAuf(ziel) }
                            zieht = nil
                        }
                )
            }
            .frame(height: 4)

            HStack {
                Text(Self.zeit(zieht ?? jetzt.position))
                Spacer(minLength: 0)
                Text(Self.zeit(jetzt.dauer))
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    static func zeit(_ sekunden: Double) -> String {
        guard sekunden.isFinite, sekunden >= 0 else { return "0:00" }
        let ganz = Int(sekunden)
        return String(format: "%d:%02d", ganz / 60, ganz % 60)
    }
}

private struct Knopf: View {
    let symbol: String
    var gross: Bool = false
    let tun: () -> Void

    init(_ symbol: String, gross: Bool = false, tun: @escaping () -> Void) {
        self.symbol = symbol
        self.gross = gross
        self.tun = tun
    }

    /// Maße des Originals (`MusicPlayerViews`): Trefferflaeche 44 x 44, das
    /// Zeichen 22 pt, bei Abspielen/Pause 28 pt. **Kein Kreis dahinter** — das
    /// Original setzt hier nackte Zeichen, und Apples Dynamic Island auch. Die
    /// Glaskreise waren eine Zutat von uns und liessen die Steuerung kleiner und
    /// zugeknoepfter wirken, als sie sein soll.
    var body: some View {
        Button(action: tun) {
            Image(systemName: symbol)
                .font(.system(size: gross ? 28 : 22))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(gross ? 0.95 : 0.8))
    }
}

/// Cover und Titel fuehren zur Musik-App. Der Zeiger wird zur Hand, damit man
/// sieht, dass hier etwas passiert.
private extension View {
    func zurApp(_ app: Musikapp) -> some View {
        contentShape(Rectangle())
            .onTapGesture { MusikDienst.shared.zeigeInApp() }
            .onHover { drin in
                if drin { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("In \(app.name) oeffnen")
    }
}
