import SwiftUI

// Die Bausteine des System-Dashboards. Jeder malt eine Sache und kennt weder
// den Dienst noch die anderen: `SystemAnsicht` setzt sie zusammen.

/// Die Farben des Dashboards. Kuehle Toene als Grundlage, Warmes nur dort, wo ein
/// Wert heiss oder knapp wird.
enum SystemFarbe {
    static let cpu = Color(red: 0.36, green: 0.64, blue: 1.00)
    static let effizienz = Color(red: 0.38, green: 0.88, blue: 0.84)
    static let gpu = Color(red: 0.68, green: 0.56, blue: 1.00)
    static let ram = Color(red: 0.31, green: 0.86, blue: 0.62)
    static let luefter = Color(red: 0.48, green: 0.82, blue: 1.00)
    static let energie = Color(red: 1.00, green: 0.80, blue: 0.32)
    static let netzAb = Color(red: 0.36, green: 0.64, blue: 1.00)
    static let netzAuf = Color(red: 0.31, green: 0.86, blue: 0.62)
    static let platte = Color(red: 1.00, green: 0.64, blue: 0.38)
    static let system = Color(red: 0.78, green: 0.80, blue: 0.86)

    static let gut = Color(red: 0.31, green: 0.86, blue: 0.62)
    static let warnung = Color(red: 1.00, green: 0.80, blue: 0.32)
    static let heiss = Color(red: 1.00, green: 0.55, blue: 0.28)
    static let kritisch = Color(red: 1.00, green: 0.34, blue: 0.34)

    /// Je heisser, desto waermer die Farbe.
    static func temperatur(_ grad: Double) -> Color {
        switch grad {
        case ..<55: return gut
        case ..<70: return warnung
        case ..<85: return heiss
        default: return kritisch
        }
    }

    static let temperaturSkala = LinearGradient(
        colors: [gut, warnung, heiss, kritisch], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Kachel

/// Ein Symbol auf getoentem Grund: das Erkennungszeichen jeder Kachel.
struct SystemSymbol: View {
    let symbol: String
    let farbe: Color
    /// Drehwinkel in Grad, fuer den Luefter.
    var winkel: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(farbe.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(farbe.opacity(0.28), lineWidth: 0.5)
            )
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(farbe)
                    .rotationEffect(.degrees(winkel))
            )
    }
}

/// Der Rahmen einer Kachel: Symbol und Name oben, rechts ein kurzer Zusatz.
struct SystemKachel<Inhalt: View>: View {
    let symbol: String
    let titel: String
    let farbe: Color
    var zusatz: String? = nil
    var zusatzFarbe: Color = .white.opacity(0.42)
    var winkel: Double = 0
    let hoehe: CGFloat
    @ViewBuilder var inhalt: () -> Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Abstand 0 und die Luecken von Hand: bei 6 Punkt Abstand zaehlt auch der
            // Spacer doppelt, und in den schmalen Kacheln bliebe dem Zusatz nichts.
            HStack(spacing: 0) {
                SystemSymbol(symbol: symbol, farbe: farbe, winkel: winkel)
                // Der Name steht immer ganz da; weichen muss der Zusatz.
                Text(titel)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 6)
                Spacer(minLength: 4)
                if let zusatz {
                    Text(zusatz)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(zusatzFarbe)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            inhalt()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: hoehe, maxHeight: hoehe, alignment: .topLeading)
        .glas(radius: 14)
    }
}

// MARK: - Zahlen

/// Die grosse Zahl einer Kachel mit ihrer Einheit.
struct SystemWert: View {
    let zahl: String
    let einheit: String
    var groesse: CGFloat = 22
    var farbe: Color = .white

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(zahl)
                .font(.system(size: groesse, weight: .semibold, design: .rounded).monospacedDigit())
                // Ein fehlender Wert ist ein blasser Strich, kein weisser Balken.
                .foregroundStyle(zahl == "–" ? .white.opacity(0.28) : farbe)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(einheit)
                .font(.system(size: max(groesse * 0.48, 9.5), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }
}

// MARK: - Ring

/// Ein offener Ring, drei Viertel eines Kreises, unten Luft. Wie die Skala eines
/// Messgeraets: links unten null, rechts unten voll.
struct SystemRing: View {
    let anteil: Double
    let farbe: Color
    var strich: CGFloat = 6
    let mitte: String
    var einheit: String = "%"

    private static let bogen = 0.75

    var body: some View {
        let a = min(max(anteil, 0), 1)
        ZStack {
            Circle()
                .trim(from: 0, to: Self.bogen)
                .stroke(.white.opacity(0.09), style: StrokeStyle(lineWidth: strich, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0, to: Self.bogen * max(a, 0.004))
                .stroke(
                    AngularGradient(colors: [farbe.opacity(0.35), farbe],
                                    center: .center, startAngle: .degrees(0),
                                    endAngle: .degrees(360 * Self.bogen)),
                    style: StrokeStyle(lineWidth: strich, lineCap: .round))
                .rotationEffect(.degrees(135))

            VStack(spacing: -1) {
                Text(mitte)
                    .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(einheit)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .offset(y: 1)
        }
        .padding(strich / 2)
    }
}

// MARK: - Verlauf

struct VerlaufReihe {
    var werte: [Double]
    var farbe: Color
}

/// Eine Kurve ueber die letzten Messungen. Neue Werte kommen rechts herein, bis
/// die Reihe voll ist; vorher bleibt links Platz, die Kurve wird nicht gestreckt.
struct SystemVerlauf: View {
    let reihen: [VerlaufReihe]
    /// Hoechster Wert der Skala. Ohne Angabe passt sich die Skala an, mindestens
    /// aber `untergrenze`, damit ein ruhiges Netz keine Spitzen aus Rauschen malt.
    var obergrenze: Double? = 1
    var untergrenze: Double = 1

    var body: some View {
        Canvas { kontext, groesse in
            let hoehe = groesse.height - 3
            // Zwei feine Linien: die Haelfte und die Oberkante.
            for bruch in [0.0, 0.5] {
                var linie = Path()
                let y = 1.5 + hoehe * bruch
                linie.move(to: CGPoint(x: 0, y: y))
                linie.addLine(to: CGPoint(x: groesse.width, y: y))
                kontext.stroke(linie, with: .color(.white.opacity(0.05)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }

            let skala = max(obergrenze ?? (reihen.flatMap(\.werte).max() ?? 0), untergrenze)
            for reihe in reihen {
                let punkte = Self.punkte(reihe.werte, skala: skala, groesse: groesse)
                guard punkte.count > 1 else { continue }
                let linie = Self.kurve(punkte)

                var flaeche = linie
                flaeche.addLine(to: CGPoint(x: punkte[punkte.count - 1].x, y: groesse.height))
                flaeche.addLine(to: CGPoint(x: punkte[0].x, y: groesse.height))
                flaeche.closeSubpath()
                kontext.fill(flaeche, with: .linearGradient(
                    Gradient(colors: [reihe.farbe.opacity(0.32), reihe.farbe.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: groesse.height)))
                kontext.stroke(linie, with: .color(reihe.farbe),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

                // Der letzte Wert als Punkt mit Hof. Der Hof ist ein zweiter, blasser
                // Kreis statt einer Unschaerfe: die kostet hier bei jedem Bild Rechenzeit.
                let ende = punkte[punkte.count - 1]
                kontext.fill(Path(ellipseIn: CGRect(x: ende.x - 4, y: ende.y - 4, width: 8, height: 8)),
                             with: .color(reihe.farbe.opacity(0.28)))
                kontext.fill(Path(ellipseIn: CGRect(x: ende.x - 1.8, y: ende.y - 1.8, width: 3.6, height: 3.6)),
                             with: .color(reihe.farbe))
            }
        }
    }

    static func punkte(_ werte: [Double], skala: Double, groesse: CGSize) -> [CGPoint] {
        let n = Messreihe.laenge
        let hoehe = groesse.height - 3
        // Rechts anfuellen: der neueste Wert sitzt immer am rechten Rand.
        let rand = 3.0
        return werte.enumerated().map { i, w in
            let x = rand + (groesse.width - 2 * rand) * Double(n - werte.count + i) / Double(n - 1)
            let anteil = min(max(w / skala, 0), 1)
            return CGPoint(x: x, y: 1.5 + hoehe * (1 - anteil))
        }
    }

    /// Weiche Kurve durch die Punkte: jede Ecke wird zum Kontrollpunkt einer
    /// Rundung zwischen den Mitten ihrer Nachbarn.
    static func kurve(_ p: [CGPoint]) -> Path {
        var pfad = Path()
        pfad.move(to: p[0])
        for i in 1..<p.count {
            let mitte = CGPoint(x: (p[i - 1].x + p[i].x) / 2, y: (p[i - 1].y + p[i].y) / 2)
            pfad.addQuadCurve(to: mitte, control: p[i - 1])
        }
        pfad.addLine(to: p[p.count - 1])
        return pfad
    }
}

// MARK: - Balken

/// Ein schmaler Balken je Prozessorkern, von unten gefuellt.
struct SystemKernbalken: View {
    let leistung: [Double]
    let effizienz: [Double]
    var hoehe: CGFloat = 34

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(leistung.enumerated()), id: \.offset) { _, last in
                balken(last, farbe: SystemFarbe.cpu)
            }
            if !effizienz.isEmpty && !leistung.isEmpty {
                Capsule().fill(.white.opacity(0.10)).frame(width: 1, height: hoehe * 0.7)
            }
            ForEach(Array(effizienz.enumerated()), id: \.offset) { _, last in
                balken(last, farbe: SystemFarbe.effizienz)
            }
        }
        .frame(height: hoehe)
    }

    private func balken(_ last: Double, farbe: Color) -> some View {
        let a = min(max(last, 0), 1)
        return ZStack(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.08))
            Capsule()
                .fill(LinearGradient(colors: [farbe, farbe.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .frame(height: max(3, hoehe * a))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Ein waagrechter Balken aus mehreren Teilen, zum Beispiel der Arbeitsspeicher.
struct SystemSegmente: View {
    struct Teil {
        var anteil: Double
        var farbe: Color
    }

    let teile: [Teil]
    var hoehe: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.09))
                HStack(spacing: 1.5) {
                    ForEach(Array(teile.enumerated()), id: \.offset) { _, teil in
                        Capsule().fill(teil.farbe)
                            .frame(width: max(0, g.size.width * min(max(teil.anteil, 0), 1)))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: hoehe)
    }
}

/// Ein einfacher Fuellbalken.
struct SystemFuellung: View {
    let anteil: Double
    let farbe: Color
    var hoehe: CGFloat = 5

    var body: some View {
        SystemSegmente(teile: [.init(anteil: anteil, farbe: farbe)], hoehe: hoehe)
    }
}

/// Die Temperaturskala: ein Farbverlauf von kuehl bis heiss, darauf eine Marke.
struct SystemTemperaturskala: View {
    let grad: Double?
    private static let von = 25.0
    private static let bis = 100.0

    var body: some View {
        GeometryReader { g in
            let a = grad.map { min(max(($0 - Self.von) / (Self.bis - Self.von), 0), 1) }
            ZStack(alignment: .leading) {
                Capsule().fill(SystemFarbe.temperaturSkala).opacity(0.5)
                if let a {
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .offset(x: (g.size.width - 7) * a)
                }
            }
        }
        .frame(height: 5)
    }
}

/// Ein Punkt mit Text, fuer Zustaende wie den Speicherdruck.
struct SystemZustand: View {
    let farbe: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(farbe).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}
