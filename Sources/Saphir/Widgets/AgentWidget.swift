import SwiftUI

/// Die Claude-Sessions in der Insel: was laeuft, was wartet, und wie viel vom
/// Kontingent noch da ist.
///
/// Reihenfolge ist Dringlichkeit: die anstehende Freigabe oben, darunter die
/// Sessions, ganz unten die Limits. Wer hinsieht, weil es geklopft hat, findet
/// oben, was geklopft hat.
struct AgentWidget: View {
    @ObservedObject private var dienst = AgentDienst.shared

    var body: some View {
        if dienst.sessions.isEmpty && dienst.kontingent == nil {
            if dienst.hooksEingetragen {
                LeereFlaeche(symbol: "sparkle")
            } else {
                NichtVerbunden()
            }
        } else {
            VStack(spacing: 8) {
                if let wartend = dienst.offeneFreigabe, let freigabe = wartend.freigabe {
                    Freigabekarte(session: wartend, freigabe: freigabe)
                }

                ForEach(dienst.sessions) { session in
                    if session.id != dienst.offeneFreigabe?.id {
                        Sessionzeile(session: session)
                    }
                }

                if let kontingent = dienst.kontingent {
                    Kontingentleiste(kontingent: kontingent)
                        .padding(.top, dienst.sessions.isEmpty ? 0 : 6)
                        // Die untere Rundung der Insel schneidet sonst an den
                        // Balkenenden: 10 Punkt Rand der Flaeche reichen fuer
                        // Karten, nicht fuer eine Zeile, die bis in die Ecke geht.
                        .padding(.bottom, 8)
                }
            }
            .animation(InselBewegung.inhalt, value: dienst.sessions)
        }
    }
}

/// Solange Saphir nicht mit Claude Code verbunden ist, kann hier nichts
/// erscheinen. Ein Knopf fuehrt zur Einstellung, ein Satz erklaert nichts.
private struct NichtVerbunden: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.18))
            Button {
                EinstellungenFenster.shared.zeigen(bereich: "agenten")
            } label: {
                Text("Mit Claude Code verbinden")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// Eine laufende Session. Ein Druck springt in ihren Terminal-Tab.
private struct Sessionzeile: View {
    let session: AgentSession

    var body: some View {
        Button {
            AgentDienst.shared.springe(zu: session)
        } label: {
            HStack(spacing: 10) {
                AgentZeichen(session: session, groesse: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(session.taetigkeit ?? session.zustand.text)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Zustandspunkt(zustand: session.zustand)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glas(radius: 12, kraft: 0.75)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help("In den Terminal-Tab springen")
    }
}

/// Der Punkt rechts in der Zeile. Arbeitet die Session, atmet er.
private struct Zustandspunkt: View {
    let zustand: AgentZustand
    @State private var hell = false

    var body: some View {
        Circle()
            .fill(zustand.farbe)
            .frame(width: 7, height: 7)
            .opacity(zustand == .working && hell ? 0.35 : 1)
            .onAppear {
                guard zustand == .working else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    hell = true
                }
            }
    }
}

/// Claudes echte Marke, sonst das typografische Zeichen des Agenten.
private struct AgentZeichen: View {
    let session: AgentSession
    var groesse: CGFloat = 15

    var body: some View {
        if session.istClaude, let marke = AgentMarke.claude {
            Image(nsImage: marke)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: groesse, height: groesse)
                .foregroundStyle(AgentMarke.claudeOrange)
        } else {
            Text(session.zeichen)
                .font(.system(size: groesse - 2, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: groesse)
        }
    }
}

// MARK: - Freigabe

/// Was Claude wissen will, mit den Knoepfen daneben.
///
/// Der Rahmen traegt die Farbe des Zustands als haarfeine Kante — mehr nicht.
/// Eine Freigabe darf sich vordraengeln, aber sie soll nicht schreien.
private struct Freigabekarte: View {
    let session: AgentSession
    let freigabe: AgentFreigabe
    @ObservedObject private var dienst = AgentDienst.shared

    private var quittung: String? { dienst.entschieden[session.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentZeichen(session: session, groesse: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text(freigabe.ueberschrift)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text(session.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if freigabe.art == .question {
                Fragen(session: session, fragen: freigabe.fragen, quittung: quittung)
            } else {
                Wahl(session: session, quittung: quittung)
            }
        }
        .padding(10)
        .glas(radius: 12, kraft: 1.2)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AgentZustand.needsApproval.farbe.opacity(0.45), lineWidth: 0.75)
        )
    }
}

/// Nur die Frage: dieselbe Karte wie oben in den Sessions, aber allein unter der
/// Notch, ohne Reiter und ohne Session-Liste.
///
/// Gezeigt wird immer die eine Freigabe, die gerade dran ist. Warten mehrere, rueckt
/// die naechste nach, sobald entschieden ist; das Panel bleibt dabei stehen. Die
/// Karte selbst ist unveraendert, damit Knoepfe und Quittung an beiden Orten
/// dasselbe tun.
struct FragePanel: View {
    @ObservedObject var zustand: InselZustand
    @ObservedObject private var dienst = AgentDienst.shared

    var body: some View {
        VStack(spacing: 0) {
            // Die Kamera bleibt frei, wie bei der HUD-Zeile.
            Color.clear.frame(height: zustand.geometrie.notchHoehe)

            if let wartend = dienst.offeneFreigabe, let freigabe = wartend.freigabe {
                Freigabekarte(session: wartend, freigabe: freigabe)
                    .padding(.horizontal, 14)
                    // Wie unten in der offenen Flaeche: 10 Rand, damit die
                    // Rundung der Insel die Karte nicht anschneidet.
                    .padding(.bottom, 10)
                    // Sonst misst sich die Karte in der Hoehe, die die Insel ihr
                    // gerade laesst, und meldet sie zurueck (siehe OffeneFlaeche).
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HoeheFrageKey.self, value: geo.size.height)
                    })
            }
        }
        .foregroundStyle(.white)
        .onPreferenceChange(HoeheFrageKey.self) { hoehe in
            // Null heisst: die Karte ist weg und das Panel geht gleich zu. Den
            // letzten echten Wert behalten, sonst faengt das naechste Panel klein an.
            guard hoehe > 0 else { return }
            Task { @MainActor in zustand.hoeheFrage = hoehe }
        }
    }
}

/// Ablehnen, Immer, Erlauben.
private struct Wahl: View {
    let session: AgentSession
    let quittung: String?

    var body: some View {
        HStack(spacing: 6) {
            Freigabeknopf(titel: "Ablehnen", wahl: "deny",
                          farbe: AgentZustand.failed.farbe, quittung: quittung) {
                AgentDienst.shared.entscheide(session, "deny")
            }
            Freigabeknopf(titel: "Immer", wahl: "always",
                          farbe: AgentZustand.done.farbe, quittung: quittung) {
                AgentDienst.shared.entscheide(session, "always")
            }
            Freigabeknopf(titel: "Erlauben", wahl: "allow",
                          farbe: AgentZustand.done.farbe, quittung: quittung, betont: true) {
                AgentDienst.shared.entscheide(session, "allow")
            }
        }
    }
}

/// Die Auswahl einer `AskUserQuestion`. Eine Frage nach der anderen; erst wenn
/// alle beantwortet sind, geht die Antwort hinaus.
private struct Fragen: View {
    let session: AgentSession
    let fragen: [AgentFrage]
    let quittung: String?
    @ObservedObject private var dienst = AgentDienst.shared

    /// Die erste noch offene Frage. Ist keine mehr offen, ist die Antwort schon
    /// unterwegs und die Knoepfe tragen ihre Quittung.
    private var dran: AgentFrage? {
        fragen.first { dienst.antworten[$0.frage] == nil } ?? fragen.last
    }

    var body: some View {
        if let dran {
            VStack(alignment: .leading, spacing: 6) {
                if fragen.count > 1, dienst.antworten[dran.frage] == nil {
                    Text(dran.frage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                WrapZeile(dran.auswahl) { label in
                    Freigabeknopf(titel: label, wahl: label,
                                  farbe: AgentZustand.done.farbe,
                                  quittung: dienst.antworten[dran.frage] ?? quittung,
                                  dehnt: false) {
                        dienst.beantworte(session, frage: dran, mit: label)
                    }
                }
            }
        }
    }
}

/// Ein Knopf, der nach dem Druck seine Form behaelt.
///
/// Keine Quittung, die als Kreis aus dem Nichts aufpoppt: derselbe Knopf, in
/// derselben Groesse, bekommt die Farbe seiner Entscheidung und einen Haken.
/// Die anderen Knoepfe treten zurueck, statt zu verschwinden — sonst springt
/// die Zeile in der Breite.
private struct Freigabeknopf: View {
    let titel: String
    let wahl: String
    let farbe: Color
    let quittung: String?
    var betont: Bool = false
    var dehnt: Bool = true
    let druck: () -> Void

    private var gewaehlt: Bool { quittung == wahl }
    private var erledigt: Bool { quittung != nil }

    var body: some View {
        Button(action: druck) {
            HStack(spacing: 4) {
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(titel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: dehnt ? .infinity : nil)
            .padding(.horizontal, dehnt ? 4 : 10)
            .frame(height: 24)
            .background(
                Capsule().fill(gewaehlt
                               ? AnyShapeStyle(farbe.opacity(0.28))
                               : AnyShapeStyle(Color.white.opacity(betont ? 0.14 : 0.07)))
            )
            .overlay(
                Capsule().strokeBorder(gewaehlt ? farbe.opacity(0.55) : .white.opacity(0.10),
                                       lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(gewaehlt ? farbe : .white.opacity(erledigt ? 0.3 : 0.85))
        .disabled(erledigt)
        .animation(.snappy(duration: 0.18), value: quittung)
    }
}

/// Knoepfe nebeneinander, und was nicht mehr passt, kommt in die naechste Zeile.
/// Fuer Antwortmoeglichkeiten, deren Laenge niemand vorher kennt.
private struct WrapZeile<Inhalt: View>: View {
    let werte: [String]
    let inhalt: (String) -> Inhalt

    init(_ werte: [String], @ViewBuilder inhalt: @escaping (String) -> Inhalt) {
        self.werte = werte
        self.inhalt = inhalt
    }

    var body: some View {
        // Zwei je Zeile: bei 500 Punkten Inselbreite ist das die Aufteilung, in
        // der eine uebliche Antwort noch ganz dasteht.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: werte.count, by: 2)), id: \.self) { i in
                HStack(spacing: 6) {
                    inhalt(werte[i])
                    if i + 1 < werte.count { inhalt(werte[i + 1]) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Kontingent

/// Die echten Rate-Limits: fuenf Stunden und sieben Tage, je ein feiner Balken.
///
/// Die Zahlen sind Anthropics eigene. Sie stehen nirgends sonst auf der Platte —
/// einziger Kanal ist das Feld `rate_limits` im Statusline-Payload, das Saphir
/// mitschneidet.
private struct Kontingentleiste: View {
    let kontingent: Kontingent

    var body: some View {
        HStack(spacing: 12) {
            if let fuenf = kontingent.fuenfStunden, fuenf.laeuft {
                Fenster(titel: "5h", fenster: fuenf, mitUhrzeit: true)
            }
            if let woche = kontingent.woche, woche.laeuft {
                Fenster(titel: "Woche", fenster: woche, mitUhrzeit: false)
            }
        }
        .opacity(kontingent.veraltet ? 0.55 : 1)
        .help(kontingent.veraltet
              ? "Stand \(Self.uhr.string(from: kontingent.standVon)) — seitdem lief keine Session"
              : "Anthropics eigene Zahlen")
    }

    static let uhr: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private struct Fenster: View {
        let titel: String
        let fenster: Kontingent.Fenster
        let mitUhrzeit: Bool

        /// Ampel nach dem, was noch uebrig ist — so steht sie auch in der
        /// Statusline.
        private var farbe: Color {
            if fenster.frei < 10 { return AgentZustand.failed.farbe }
            if fenster.frei < 25 { return AgentZustand.needsApproval.farbe }
            return AgentZustand.done.farbe
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(titel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("\(fenster.frei) %")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                    if mitUhrzeit {
                        Text(Kontingentleiste.uhr.string(from: fenster.resetAm))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule()
                            .fill(farbe)
                            .frame(width: max(3, geo.size.width * Double(fenster.frei) / 100))
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
