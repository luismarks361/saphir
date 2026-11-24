import SwiftUI

/// Die Seite „System“ der aufgeklappten Flaeche. Sie weckt den Dienst, solange
/// sie zu sehen ist, und schlaeft ihn wieder ein, wenn die Insel zugeht.
struct SystemSeite: View {
    @ObservedObject private var dienst = SystemDienst.shared

    var body: some View {
        SystemAnsicht(stand: dienst.stand, verlaeufe: dienst.verlaeufe)
            .onAppear { SystemDienst.shared.starte() }
            .onDisappear { SystemDienst.shared.stoppe() }
    }
}

/// Das Bento-Raster. Nimmt seine Werte als Parameter, damit es sich ohne Dienst
/// und ohne Mac-Sensoren malen und pruefen laesst.
///
/// Vier gleich breite Spalten, drei Zeilen: oben die drei Schwergewichte (CPU
/// doppelt breit), in der Mitte die Messwerte zum Ablesen, unten Netz, Platte
/// und Betrieb. Jede Kachel zeigt eine grosse Zahl; nichts erklaert sich selbst.
struct SystemAnsicht: View {
    let stand: SystemStand
    let verlaeufe: Verlaeufe

    private static let hoeheOben: CGFloat = 124
    private static let hoeheMitte: CGFloat = 84
    private static let hoeheUnten: CGFloat = 92

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                cpu.gridCellColumns(2)
                gpu
                ram
            }
            GridRow {
                temperatur
                luefter
                energie
                akku
            }
            GridRow {
                netz.gridCellColumns(2)
                platte
                system
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Oben

    private var cpu: some View {
        let leistung = Array(stand.kernLast.dropFirst(stand.kerneE))
        let effizienz = Array(stand.kernLast.prefix(stand.kerneE))
        return SystemKachel(symbol: "cpu", titel: "CPU", farbe: SystemFarbe.cpu,
                            zusatz: stand.kerneE > 0 ? "\(stand.kerneP) P · \(stand.kerneE) E" : "\(stand.kerneP) Kerne",
                            hoehe: Self.hoeheOben) {
            HStack(spacing: 12) {
                SystemRing(anteil: stand.cpu, farbe: SystemFarbe.cpu, strich: 7,
                           mitte: SystemRechnung.prozent(stand.cpu))
                    .frame(width: 74, height: 74)
                VStack(spacing: 8) {
                    SystemKernbalken(leistung: leistung, effizienz: effizienz, hoehe: 32)
                    SystemVerlauf(reihen: [VerlaufReihe(werte: verlaeufe.cpu.werte, farbe: SystemFarbe.cpu)])
                        .frame(height: 28)
                }
            }
        }
    }

    private var gpu: some View {
        SystemKachel(symbol: "square.stack.3d.up.fill", titel: "GPU", farbe: SystemFarbe.gpu,
                     zusatz: stand.gpuKerne > 0 ? "\(stand.gpuKerne) K" : nil,
                     hoehe: Self.hoeheOben) {
            VStack(spacing: 6) {
                SystemRing(anteil: stand.gpu, farbe: SystemFarbe.gpu, strich: 6,
                           mitte: SystemRechnung.prozent(stand.gpu))
                    .frame(width: 58, height: 58)
                    .frame(maxWidth: .infinity)
                SystemVerlauf(reihen: [VerlaufReihe(werte: verlaeufe.gpu.werte, farbe: SystemFarbe.gpu)])
                    .frame(height: 16)
            }
        }
    }

    private var ram: some View {
        let s = stand.speicher
        let gesamt = Double(max(s.gesamt, 1))
        let benutzt = SystemRechnung.groesse(Double(s.benutzt))
        let von = SystemRechnung.groesse(Double(s.gesamt))
        let frei = SystemRechnung.groesse(Double(s.frei))
        return SystemKachel(symbol: "memorychip", titel: "RAM", farbe: SystemFarbe.ram,
                            zusatz: nil, hoehe: Self.hoeheOben) {
            VStack(alignment: .leading, spacing: 5) {
                SystemWert(zahl: benutzt.zahl, einheit: benutzt.einheit)
                Text("von \(von.zahl) \(von.einheit)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
                SystemSegmente(teile: [
                    .init(anteil: Double(s.app) / gesamt, farbe: SystemFarbe.ram),
                    .init(anteil: Double(s.wired) / gesamt, farbe: SystemFarbe.warnung),
                    .init(anteil: Double(s.komprimiert) / gesamt, farbe: SystemFarbe.gpu)
                ])
                Spacer(minLength: 0)
                HStack {
                    SystemZustand(farbe: druckFarbe(s.druck), text: "\(frei.zahl) \(frei.einheit) frei")
                }
            }
        }
    }

    // MARK: - Mitte

    private var temperatur: some View {
        let t = stand.temperaturen
        return SystemKachel(symbol: "thermometer.medium", titel: "TEMP", farbe: SystemFarbe.temperatur(t.cpuMittel ?? 0),
                            hoehe: Self.hoeheMitte) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    SystemWert(zahl: t.cpuMittel.map { "\(Int($0.rounded()))" } ?? "–", einheit: "°C",
                               farbe: t.cpuMittel.map(SystemFarbe.temperatur) ?? .white)
                    Spacer(minLength: 4)
                    // Die heisseste Stelle des Chips, damit eine Spitze nicht im Mittel untergeht.
                    if let spitze = t.cpuMax {
                        Text("↑\(Int(spitze.rounded()))°")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
                SystemTemperaturskala(grad: t.cpuMittel)
            }
        }
    }

    private var luefter: some View {
        let schnellster = stand.luefter.max { $0.drehzahl < $1.drehzahl }
        let drehzahl = schnellster?.drehzahl ?? 0
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: drehzahl < 1)) { zeit in
            SystemKachel(symbol: "fan", titel: "LÜFTER", farbe: SystemFarbe.luefter,
                         zusatz: stand.luefter.count > 1 ? "\(stand.luefter.count)×" : nil,
                         winkel: Self.fluegelWinkel(zeit.date, anteil: schnellster?.anteil ?? 0, dreht: drehzahl >= 1),
                         hoehe: Self.hoeheMitte) {
                VStack(alignment: .leading, spacing: 5) {
                    SystemWert(zahl: schnellster == nil ? "–" : "\(Int(drehzahl.rounded()))", einheit: "rpm")
                    SystemFuellung(anteil: schnellster?.anteil ?? 0, farbe: SystemFarbe.luefter)
                }
            }
        }
    }

    /// Wie weit sich der Fluegel gedreht hat. Das Auge folgt echten 7000 U/min
    /// nicht, also dreht er zwischen einer und fuenf Umdrehungen pro Sekunde:
    /// schneller heisst schneller, aber nie schneller als das Bild sich erneuert.
    static func fluegelWinkel(_ zeit: Date, anteil: Double, dreht: Bool) -> Double {
        guard dreht else { return 0 }
        let umdrehungenProSekunde = 1 + 4 * min(max(anteil, 0), 1)
        let t = zeit.timeIntervalSinceReferenceDate
        return (t * umdrehungenProSekunde * 360).truncatingRemainder(dividingBy: 360)
    }

    private var energie: some View {
        let watt = stand.leistung
        return SystemKachel(symbol: "bolt.fill", titel: "ENERGIE", farbe: SystemFarbe.energie,
                            hoehe: Self.hoeheMitte) {
            VStack(alignment: .leading, spacing: 4) {
                SystemWert(zahl: watt.map { SystemRechnung.dezimal($0, stellen: $0 < 10 ? 1 : 0) } ?? "–", einheit: "W")
                SystemVerlauf(reihen: [VerlaufReihe(werte: verlaeufe.leistung.werte, farbe: SystemFarbe.energie)],
                              obergrenze: nil, untergrenze: 10)
                    .frame(height: 12)
            }
        }
    }

    private var akku: some View {
        let prozent = stand.akkuProzent
        let farbe = prozent.map { $0 <= 10 ? SystemFarbe.kritisch : ($0 <= 20 ? SystemFarbe.warnung : SystemFarbe.gut) }
            ?? SystemFarbe.gut
        let zusatz = prozent == nil ? nil : (stand.laedt ? "lädt" : (stand.amNetzteil ? "Netz" : "Akku"))
        return SystemKachel(symbol: stand.laedt ? "battery.100.bolt" : "battery.100", titel: "AKKU", farbe: farbe,
                            zusatz: zusatz, hoehe: Self.hoeheMitte) {
            VStack(alignment: .leading, spacing: 5) {
                SystemWert(zahl: prozent.map(String.init) ?? "–", einheit: "%")
                SystemFuellung(anteil: Double(prozent ?? 0) / 100, farbe: farbe)
            }
        }
    }

    // MARK: - Unten

    private var netz: some View {
        let ab = SystemRechnung.rate(stand.down)
        let auf = SystemRechnung.rate(stand.up)
        return SystemKachel(symbol: "arrow.up.arrow.down", titel: "NETZ", farbe: SystemFarbe.netzAb,
                            hoehe: Self.hoeheUnten) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    rate(symbol: "arrow.down", farbe: SystemFarbe.netzAb, wert: ab)
                    rate(symbol: "arrow.up", farbe: SystemFarbe.netzAuf, wert: auf)
                }
                .frame(width: 92, alignment: .leading)
                SystemVerlauf(reihen: [
                    VerlaufReihe(werte: verlaeufe.down.werte, farbe: SystemFarbe.netzAb),
                    VerlaufReihe(werte: verlaeufe.up.werte, farbe: SystemFarbe.netzAuf)
                ], obergrenze: nil, untergrenze: 50_000)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func rate(symbol: String, farbe: Color, wert: (zahl: String, einheit: String)) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(farbe)
                .frame(width: 9)
            SystemWert(zahl: wert.zahl, einheit: wert.einheit, groesse: 16)
        }
    }

    private var platte: some View {
        let frei = SystemRechnung.groesse(Double(stand.plattenFrei), basis: 1000)
        let lesen = SystemRechnung.groesse(stand.plattenLesen, basis: 1000, kompakt: true)
        let schreiben = SystemRechnung.groesse(stand.plattenSchreiben, basis: 1000, kompakt: true)
        return SystemKachel(symbol: "internaldrive", titel: "SSD", farbe: SystemFarbe.platte,
                            zusatz: stand.plattenGesamt > 0 ? "\(SystemRechnung.prozent(stand.plattenBelegt)) %" : nil,
                            hoehe: Self.hoeheUnten) {
            VStack(alignment: .leading, spacing: 5) {
                SystemWert(zahl: frei.zahl, einheit: "\(frei.einheit) frei")
                SystemFuellung(anteil: stand.plattenBelegt, farbe: SystemFarbe.platte, hoehe: 4)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").font(.system(size: 7.5, weight: .heavy))
                    Text("\(lesen.zahl) \(lesen.einheit)")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up").font(.system(size: 7.5, weight: .heavy))
                    Text("\(schreiben.zahl) \(schreiben.einheit)")
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    private var system: some View {
        let kurz = stand.chip.replacingOccurrences(of: "Apple ", with: "")
        return SystemKachel(symbol: "laptopcomputer", titel: "MAC", farbe: SystemFarbe.system,
                            zusatz: kurz.isEmpty ? nil : kurz, hoehe: Self.hoeheUnten) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stand.laufzeit > 0 ? SystemRechnung.laufzeit(stand.laufzeit) : "–")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                zustand
            }
        }
    }

    private var zustand: some View {
        switch stand.thermisch {
        case .normal: return SystemZustand(farbe: SystemFarbe.gut, text: "Normal")
        case .erhoeht: return SystemZustand(farbe: SystemFarbe.warnung, text: "Erhöht")
        case .hoch: return SystemZustand(farbe: SystemFarbe.heiss, text: "Hoch")
        case .kritisch: return SystemZustand(farbe: SystemFarbe.kritisch, text: "Kritisch")
        }
    }

    private func druckFarbe(_ druck: Speicherdruck) -> Color {
        switch druck {
        case .normal: return SystemFarbe.gut
        case .erhoeht: return SystemFarbe.warnung
        case .kritisch: return SystemFarbe.kritisch
        }
    }
}
