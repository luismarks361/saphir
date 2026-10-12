import SwiftUI

/// Die Insel selbst: eine Form, die zwischen eingeklappter Leiste, HUD-Zeile und
/// offener Flaeche wandert.
///
/// Bewusst *eine* Ansicht statt drei mit Uebergaengen — nur so liest sich das
/// Auf- und Zuklappen als eine durchgehende Bewegung.
struct InselWurzel: View {
    @ObservedObject var zustand: InselZustand

    private var groesse: CGSize { zustand.zielGroesse }

    /// Wie stark der Schatten sein darf.
    ///
    /// Eingeklappt ist die Insel genau so hoch wie die Notch. Laeuft eine App im
    /// Vollbild, ist der Streifen dort ohnehin schwarz — das Schwarz der Insel
    /// verschmilzt damit, und sichtbar bliebe allein der Schatten als weicher
    /// Rand im App-Inhalt. Also weg damit.
    private var schattenStaerke: CGFloat {
        if zustand.istStumm { return 0 }
        let passtInDieNotch = !zustand.istOffen && zustand.hud == nil
        return passtInDieNotch && !zustand.menueleisteSichtbar ? 0 : 1
    }

    private var radius: CGFloat {
        if zustand.istOffen { return InselMasse.radiusOffen }
        if zustand.hud != nil { return InselMasse.radiusHud(zustand.geometrie.screen) }
        return InselMasse.radiusEingeklappt(zustand.geometrie.screen)
    }

    private var kehle: CGFloat {
        zustand.istOffen ? 9 : zustand.hud != nil ? 7 : 6
    }

    /// Aufwaerts darf die Feder ueberschwingen, abwaerts nicht: Eingeklappt ist
    /// die Insel exakt so hoch wie die Notch. Schwingt sie beim Zuklappen unter
    /// diese Hoehe, liegt die Form kurz kleiner als die Kamera-Aussparung und die
    /// echte Notch blitzt darunter hervor. Die Zuklapp-Feder (Daempfung 0,98)
    /// laeuft aus, ohne die Zielgroesse zu unterschreiten.
    private var groessenBewegung: Animation {
        zustand.istOffen || zustand.hud != nil ? InselBewegung.groesse : InselBewegung.zuklappen
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Kein farbiger Schein an der Insel selbst: eingeklappt soll die
                // Notch unberuehrt aussehen. Der Schein sitzt aufgeklappt hinter
                // dem Cover (siehe MusikWidget).
                NotchForm(untenRadius: radius, kehle: kehle)
                    .fill(.black)
                    .inselSchatten(staerke: schattenStaerke)
                    .animation(InselBewegung.blende, value: schattenStaerke)

                // Die Kehle zieht den Koerper auf jeder Seite um `kehle` nach
                // innen. Ohne die passende Polsterung landet der aeusserste
                // Inhalt in dieser Luecke und sitzt auf der Menueleiste statt
                // auf der Insel.
                inhalt
                    .padding(.horizontal, kehle)
                    .clipShape(NotchForm(untenRadius: radius, kehle: kehle))
            }
            // Je eine Animation pro Eigenschaft, getrieben allein vom Wert der
            // sich geaendert hat. Das Fenster verpackt seine Aenderungen bewusst
            // NICHT zusaetzlich in `withAnimation` — sonst liefe die Groesse
            // doppelt animiert und die Kurve kaempfte sichtbar mit sich selbst.
            .frame(width: groesse.width + kehle * 2, height: groesse.height)
            .animation(groessenBewegung, value: groesse.width)
            .animation(groessenBewegung, value: groesse.height)
            .opacity(zustand.istStumm ? 0 : 1)
            .animation(InselBewegung.blende, value: zustand.istStumm)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Blendet ueber, waehrend die Form darunter wandert. Die Blende ist
    /// absichtlich schneller als die Groessenaenderung, damit der Inhalt lesbar
    /// ist, bevor die Flaeche fertig gewachsen ist.
    @ViewBuilder
    private var inhalt: some View {
        ZStack(alignment: .top) {
            if zustand.istOffen {
                OffeneFlaeche(zustand: zustand)
                    .transition(.opacity)
            } else if let hud = zustand.hud {
                HudLeiste(anzeige: hud, zustand: zustand)
                    .transition(.opacity)
            } else {
                EingeklappteLeiste(zustand: zustand)
                    .transition(.opacity)
            }
        }
        .animation(InselBewegung.inhalt, value: zustand.istOffen)
        .animation(InselBewegung.inhalt, value: zustand.hud)
    }
}

// MARK: - Eingeklappt

/// Links und rechts der Notch je ein Streifen fuer die laufende Aktivitaet.
/// In der Mitte bleibt die Notch frei — dort ist die Kamera.
struct EingeklappteLeiste: View {
    @ObservedObject var zustand: InselZustand

    var body: some View {
        HStack(spacing: 0) {
            LiveAktivitaetSlot(seite: .links, zustand: zustand)
                .frame(width: zustand.breiteLinks)

            Color.clear.frame(width: zustand.geometrie.notchBreite)

            LiveAktivitaetSlot(seite: .rechts, zustand: zustand)
                .frame(width: zustand.breiteRechts)
        }
        .frame(height: zustand.geometrie.notchHoehe)
    }
}

/// Ein Streifen neben der Kamera. Ohne laufende Aktivitaet bleibt er leer und
/// die Insel sieht aus wie eine unberuehrte Notch.
struct LiveAktivitaetSlot: View {
    enum Seite { case links, rechts }
    let seite: Seite
    @ObservedObject var zustand: InselZustand
    @ObservedObject private var aktivitaeten = LiveAktivitaeten.shared

    private var inhalt: LiveInhalt? {
        guard let vorne = aktivitaeten.vorne else { return nil }
        return seite == .links ? vorne.links : vorne.rechts
    }

    var body: some View {
        if let inhalt {
            LiveInhaltAnsicht(inhalt: inhalt)
                // Links buendig nach rechts an die Kamera, rechts nach links:
                // so bleibt der Inhalt in Kameranaehe und der Rand aussen frei.
                .frame(maxWidth: .infinity,
                       alignment: seite == .links ? .trailing : .leading)
                .transition(.opacity)
        } else {
            Color.clear
        }
    }
}

/// Symbol oder Bild, Text, Balken — in dieser Reihenfolge, immer gleich.
struct LiveInhaltAnsicht: View {
    let inhalt: LiveInhalt

    var body: some View {
        HStack(spacing: LiveInhalt.abstand) {
            if let bild = inhalt.bild {
                Image(nsImage: bild)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: LiveInhalt.symbolBreite, height: LiveInhalt.symbolBreite)
                    .clipShape(RoundedRectangle(cornerRadius: LiveInhalt.symbolRadius,
                                                style: .continuous))
            } else if inhalt.marke == .claude, let marke = AgentMarke.claude {
                // Die echte Marke, in Claude-Orange. Den Zustand tragen die
                // Punkte rechts. Fehlt die Datei, uebernimmt das Zeichen daneben.
                Image(nsImage: marke)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: LiveInhalt.markeBreite, height: LiveInhalt.markeBreite)
                    .foregroundStyle(AgentMarke.claudeOrange)
            } else if let symbol = inhalt.symbol {
                symbolOderZeichen(symbol)
            }

            if let text = inhalt.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: LiveInhalt.schriftGroesse, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let wellen = inhalt.wellen {
                Wellenform(farbe: inhalt.farbe, tanzt: wellen == .tanzt)
            }

            if let punkte = inhalt.punkte, !punkte.isEmpty {
                HStack(spacing: LiveInhalt.punktLuecke) {
                    ForEach(Array(punkte.enumerated()), id: \.offset) { _, farbe in
                        Circle()
                            .fill(farbe)
                            .frame(width: LiveInhalt.punktBreite,
                                   height: LiveInhalt.punktBreite)
                    }
                }
            }

            if let anteil = inhalt.anteil {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(inhalt.farbe)
                            .frame(width: max(3, geo.size.width * min(max(anteil, 0), 1)))
                    }
                }
                .frame(width: LiveInhalt.balkenBreite, height: 4)
            }
        }
        .padding(.horizontal, LiveInhalt.rand)
    }

    /// Ein SF-Symbol hat einen Namen mit Punkt darin, ein typografisches
    /// Agenten-Zeichen ist ein einzelnes Schriftzeichen. Beides steht im selben
    /// Feld, weil beides an derselben Stelle steht.
    @ViewBuilder
    private func symbolOderZeichen(_ symbol: String) -> some View {
        if symbol.count == 1, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
            Text(symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(inhalt.farbe)
                .frame(width: LiveInhalt.symbolBreite)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(inhalt.farbe)
                .frame(width: LiveInhalt.symbolBreite)
        }
    }
}

/// Die tanzenden Balken neben der Kamera — bei Saphir ein echter Equalizer.
///
/// Wie diese Bewegung funktioniert:
/// * **Vier Balken, vier Tonlagen.** Links der Bass, dann die Grundtoene, die
///   Praesenz und rechts die Hoehen. Wummert der Bass, waechst der linke
///   Balken; zischen die Becken, der rechte. Die Werte kommen aus
///   [`PegelDienst`], der den Systemton mitliest und in vier Baender zerlegt.
/// * Das ist der Unterschied zum Original (`CoreAnimationWaveformView`) und zu
///   Apples Dynamic Island: dort laeuft eine feste Figur im Kreis, die auch in
///   einer stillen Stelle munter weitertanzt. Hier bewegt sich, was man hoert.
/// * Jeder Balken waechst **aus der Mitte** nach oben und unten zugleich. Der
///   Ankerpunkt sitzt mittig, animiert wird allein die Hoehe. Ein Equalizer,
///   der von unten hochwaechst, saesse in der Notch sichtbar schief.
/// * Pausiert schrumpft alles auf die Mindesthoehe: ein runder Punkt von der
///   Breite des Balkens.
/// * Gezeichnet wird von Core Animation, nicht von SwiftUI. Ein Bildtakt
///   schreibt nur vier Zahlen in vier Ebenen — die View wird nie neu gebaut.
struct Wellenform: NSViewRepresentable {
    let farbe: Color
    let tanzt: Bool

    /// Vier Balken zu 3,5 mit 3 Luecke sind 23; ein Punkt Rand links und
    /// rechts macht 25. Die Hoehe bleibt bei den 22 des Originals.
    static let breite: CGFloat = 25
    fileprivate static let hoehe: CGFloat = 22
    fileprivate static let anzahl = PegelDienst.anzahl
    fileprivate static let dicke: CGFloat = 3.5
    fileprivate static let luecke: CGFloat = 3
    /// Voller Ausschlag laesst oben und unten je einen Punkt Luft.
    fileprivate static let hoechst: CGFloat = hoehe - 2

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.frame = CGRect(x: 0, y: 0, width: Self.breite, height: Self.hoehe)
        context.coordinator.baueAuf(in: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setze(farbe: farbe, tanzt: tanzt)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: Self.breite, height: Self.hoehe)
    }

    func makeCoordinator() -> Koordinator { Koordinator() }

    final class Koordinator: NSObject {
        private var masken: [CALayer] = []
        private var letzteFarbe: Color?
        private var tanzt = false
        /// Was die Balken gerade zeigen. Zieht dem gemessenen Pegel nach, damit
        /// zwischen zwei Messungen (rund 45 je Sekunde) nichts stuft.
        private var stand = [Float](repeating: 0, count: PegelDienst.anzahl)
        private var takt: CADisplayLink?
        private weak var view: NSView?

        func baueAuf(in view: NSView) {
            guard masken.isEmpty, let eltern = view.layer else { return }
            self.view = view

            let gesamt = CGFloat(Wellenform.anzahl) * Wellenform.dicke
                + CGFloat(Wellenform.anzahl - 1) * Wellenform.luecke
            var x = (Wellenform.breite - gesamt) / 2

            for _ in 0..<Wellenform.anzahl {
                let saeule = CALayer()
                saeule.frame = CGRect(x: x, y: 0,
                                      width: Wellenform.dicke, height: Wellenform.hoehe)

                // Der Verlauf steht still; bewegt wird nur die Maske davor.
                let verlauf = CAGradientLayer()
                verlauf.frame = saeule.bounds
                verlauf.startPoint = CGPoint(x: 0.5, y: 0)
                verlauf.endPoint = CGPoint(x: 0.5, y: 1)

                let maske = CALayer()
                maske.backgroundColor = NSColor.black.cgColor
                maske.cornerRadius = Wellenform.dicke / 2
                maske.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                maske.position = CGPoint(x: saeule.bounds.midX, y: saeule.bounds.midY)
                maske.bounds = CGRect(x: 0, y: 0,
                                      width: Wellenform.dicke, height: Wellenform.dicke)

                verlauf.mask = maske
                saeule.addSublayer(verlauf)
                eltern.addSublayer(saeule)
                masken.append(maske)

                x += Wellenform.dicke + Wellenform.luecke
            }
        }

        func setze(farbe: Color, tanzt: Bool) {
            if farbe != letzteFarbe {
                letzteFarbe = farbe
                let oben = NSColor(farbe.opacity(0.85)).cgColor
                let unten = NSColor(farbe.opacity(0.65)).cgColor
                Self.ohneAutomatik {
                    for maske in masken {
                        (maske.superlayer as? CAGradientLayer)?.colors = [oben, unten]
                    }
                }
            }

            guard tanzt != self.tanzt else { return }
            self.tanzt = tanzt
            PegelDienst.shared.setzeBedarf(tanzt)
            if tanzt { starteTakt() } else { stoppeTakt() }
        }

        private func starteTakt() {
            guard takt == nil, let view else { return }
            let link = view.displayLink(target: self, selector: #selector(schlag))
            link.add(to: .main, forMode: .common)
            takt = link
        }

        private func stoppeTakt() {
            takt?.invalidate()
            takt = nil
            stand = [Float](repeating: 0, count: Wellenform.anzahl)
            zeichne()
        }

        @objc private func schlag(_ link: CADisplayLink) {
            let ziel = PegelDienst.shared.lies()
            for i in 0..<Wellenform.anzahl {
                stand[i] += (ziel[i] - stand[i]) * 0.5
            }
            zeichne()
        }

        private func zeichne() {
            let mindest = Wellenform.dicke
            let spanne = Wellenform.hoechst - mindest
            Self.ohneAutomatik {
                for (i, maske) in masken.enumerated() {
                    maske.bounds = CGRect(x: 0, y: 0, width: Wellenform.dicke,
                                          height: mindest + spanne * CGFloat(stand[i]))
                }
            }
        }

        deinit {
            takt?.invalidate()
            PegelDienst.shared.setzeBedarf(false)
        }

        /// CALayer animiert jede Zuweisung von selbst. Bei 60 Bildern je Sekunde
        /// legt sich das uebereinander und die Balken kriechen hinterher.
        private static func ohneAutomatik(_ arbeit: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arbeit()
            CATransaction.commit()
        }
    }
}

// MARK: - HUD

/// Eine Zeile unterhalb der Notch: Symbol, Balken, Wert. Mehr nicht.
///
/// Maße aus dem Original (`SystemHUDView`): Flaeche 280 breit, Rand 16 zu den
/// Seiten und 12 nach oben und unten, Abstand 12; Symbol 20 pt in einem 40
/// breiten Feld, Balken 14 hoch, Prozentzahl 12 pt einbreit in einem Feld von
/// 40. Die Farbe des Balkens waechst mit dem Wert mit und wirft einen Schein
/// in derselben Farbe.
struct HudLeiste: View {
    let anzeige: HudAnzeige
    @ObservedObject var zustand: InselZustand

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: zustand.geometrie.notchHoehe)

            HStack(spacing: 12) {
                if anzeige.angebot {
                    Spacer(minLength: 0)
                    Image(systemName: anzeige.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(anzeige.farbe)

                    Button {
                        NachtDienst.shared.an()
                        NotificationCenter.default.post(name: .saphirHudSchliessen, object: nil)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 24)
                            .glas(radius: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                    Button {
                        NotificationCenter.default.post(name: .saphirHudSchliessen, object: nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 24)
                            .glas(radius: 12, kraft: 0.6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                } else if anzeige.glanz {
                    GlanzSymbol(symbol: anzeige.symbol, farbe: anzeige.farbe)
                        .frame(maxWidth: .infinity)
                } else {
                    Image(systemName: anzeige.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 40)
                }

                if anzeige.glanz || anzeige.angebot {
                    EmptyView()
                } else if let anteil = anzeige.anteil {
                    HudBalken(anteil: anteil, farbe: anzeige.farbe)
                        .frame(height: 14)

                    Text(anzeige.text)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40)
                } else {
                    Text(anzeige.text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: InselZustand.hudZeilenHoehe)
        }
    }
}

/// Ein Symbol, ueber das ein Glanz wandert. Fuer die Brillen-Erinnerung.
///
/// Der Glanz ist ein heller Streifen, der schraeg ueber das Symbol laeuft und
/// durch das Symbol selbst maskiert wird — er leuchtet also nur im Zeichen,
/// nicht im Schwarz daneben. Er laeuft, solange die Zeile steht, und die steht
/// nur wenige Sekunden.
private struct GlanzSymbol: View {
    let symbol: String
    let farbe: Color

    @State private var wo: CGFloat = -1

    private var zeichen: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .medium))
    }

    var body: some View {
        ZStack {
            zeichen.foregroundStyle(farbe)
            // Der Streifen bleibt auf dem Zeichen, statt weit daneben zu
            // warten: sonst sieht man den Glanz in den paar Sekunden, die die
            // Zeile steht, nur ein einziges Mal kurz aufblitzen.
            LinearGradient(colors: [.clear, .white, .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
                .rotationEffect(.degrees(18))
                .offset(x: wo * 24)
                .blendMode(.plusLighter)
                .mask(zeichen)
        }
        .onAppear {
            wo = -1
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                wo = 1
            }
        }
    }
}

/// Der Balken des HUD. Schein in der eigenen Farbe, Radius mit dem Wert
/// wachsend — beides steht so im Original.
private struct HudBalken: View {
    let anteil: Double
    let farbe: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.3))
                Capsule()
                    .fill(farbe)
                    .frame(width: geo.size.width * min(max(anteil, 0), 1))
            }
            .clipShape(Capsule())
            .shadow(color: farbe.opacity(0.9), radius: anteil * 10)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: anteil)
        .animation(.easeInOut(duration: 0.2), value: farbe)
    }
}
