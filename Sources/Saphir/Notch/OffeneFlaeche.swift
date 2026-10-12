import SwiftUI

/// Die aufgeklappte Widget-Flaeche.
///
/// Die Reiter sitzen auf Hoehe der Menueleiste neben der Notch, darunter steht
/// die Seite. Gezeigt werden nur Seiten, deren Funktion eingeschaltet ist.
struct OffeneFlaeche: View {
    @ObservedObject var zustand: InselZustand

    var body: some View {
        VStack(spacing: 0) {
            // Die Reiter stehen auf Hoehe der Menueleiste, links neben der
            // physischen Notch — in einer Reihe mit Apfel, Ablage, Bearbeiten.
            // Dadurch braucht die Flaeche keine eigene Zeile dafuer und die
            // Insel faehrt nicht weiter aus als noetig. Die Mitte bleibt frei,
            // dort sitzt die Kamera.
            HStack(spacing: 0) {
                reiterreihe
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)

                Color.clear.frame(width: zustand.geometrie.notchBreite)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    reiter(.einstellungen)
                    anheftKnopf
                }
                .frame(maxWidth: .infinity)
                .padding(.trailing, 14)
            }
            .frame(height: zustand.geometrie.notchHoehe)

            // Bis zur Obergrenze ist die Flaeche so hoch wie ihr Inhalt,
            // darueber wird gerollt. Ohne das Rollen laeuft langer Inhalt oben
            // aus der Insel heraus, weil die Hoehe gedeckelt ist.
            ScrollView(.vertical, showsIndicators: false) {
                seiteninhalt
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    // `contentBottomPadding` des Originals: 10, nicht 14.
                    .padding(.bottom, 10)
                    // Ohne dies misst sich der Inhalt in der Hoehe, die die
                    // Insel ihm gerade laesst — und meldet sie zurueck. Die
                    // Flaeche schrumpfte dann Bild fuer Bild in sich zusammen.
                    .fixedSize(horizontal: false, vertical: true)
                    // Die Flaeche ist genau so hoch wie ihr Inhalt. Ohne diese
                    // Meldung stuende unter jedem Widget schwarzer Platz.
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HoeheOffenKey.self,
                                               value: geo.size.height)
                    })
            }
            .frame(height: zustand.hoeheInhalt)
            .scrollDisabled(!zustand.inhaltRollt)
        }
        .foregroundStyle(.white)
        .onPreferenceChange(HoeheOffenKey.self) { hoehe in
            Task { @MainActor in
                zustand.hoeheOffen = zustand.geometrie.notchHoehe + hoehe
            }
        }
    }

    private var reiterreihe: some View {
        // Kein Abstand zwischen den Reitern: den Platz nimmt jeder Reiter selbst
        // als Trefferflaeche mit, sichtbar bleibt die Luecke trotzdem.
        HStack(spacing: 0) {
            ForEach(WidgetSeite.reiter) { seite in
                reiter(seite)
            }
        }
        .animation(InselBewegung.seitenwechsel, value: zustand.seite)
    }

    /// Wie gross ein Reiter zu treffen ist.
    ///
    /// Gezeichnet wird eine Kapsel von 28 x 28; getroffen werden darf die ganze
    /// Zeile, also 32 x Notch-Hoehe. Die Symbole sitzen auf Hoehe der
    /// Menueleiste, und dort zielt man im Vorbeifahren — ein 28er Quadrat ist
    /// dafuer zu wenig. Am Platzbedarf aendert sich nichts: 32 ist genau das,
    /// was ein Reiter mit Abstand vorher schon belegt hat, und mit dieser Zahl
    /// rechnet `InselZustand.groesseOffen` die Breite der Flaeche aus.
    private static let reiterFeld: CGFloat = 32

    private func reiter(_ seite: WidgetSeite) -> some View {
        Button {
            zustand.seite = seite
        } label: {
            Image(systemName: seite.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(zustand.seite == seite
                                   ? AnyShapeStyle(LinearGradient(
                                       colors: [.white.opacity(0.20), .white.opacity(0.10)],
                                       startPoint: .top, endPoint: .bottom))
                                   : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    Capsule().strokeBorder(.white.opacity(zustand.seite == seite ? 0.16 : 0),
                                           lineWidth: 0.5)
                )
                .frame(width: Self.reiterFeld, height: zustand.geometrie.notchHoehe)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(zustand.seite == seite ? .white : .white.opacity(0.5))
    }

    private var anheftKnopf: some View {
        Button {
            zustand.istAngeheftet.toggle()
        } label: {
            Image(systemName: zustand.istAngeheftet ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(zustand.istAngeheftet ? .white : .white.opacity(0.4))
        .help("Offen halten")
    }

    @ViewBuilder
    private var seiteninhalt: some View {
        switch zustand.seite {
        case .start:
            Uebersicht()
        case .agenten:
            AgentWidget()
        case .musik:
            MusikWidget()
        case .regal:
            RegalWidget()
        case .kalender:
            KalenderWidget()
        case .zwischenablage:
            ZwischenablageWidget()
        case .notizen:
            NotizWidget()
        case .zonen:
            ZonenWidget()
        case .einstellungen:
            SchnellEinstellungen()
        }
    }
}

/// Was eine Seite zeigt, solange sie nichts zu zeigen hat: ihr eigenes Symbol,
/// blass. Kein Satz — in der Insel steht kein erklaerender Text.
struct LeereFlaeche: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(.white.opacity(0.18))
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// Die Funktionsschalter direkt in der Insel — als Symbolraster, ohne Namen.
/// Die Beschriftungen stehen im Einstellungsfenster, hier zaehlt der Griff.
struct SchnellEinstellungen: View {
    @ObservedObject private var einstellungen = Einstellungen.shared

    private let spalten = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: spalten, spacing: 8) {
                ForEach(Funktion.gebaute) { funktion in
                    let an = einstellungen.istAn(funktion)
                    Button {
                        einstellungen.setze(funktion, an: !an)
                    } label: {
                        Image(systemName: funktion.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(an ? .white.opacity(0.16) : .white.opacity(0.05)))
                            .foregroundStyle(an ? .white : .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help(funktion.name)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 114)
    }
}
