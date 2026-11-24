import Foundation

// Alles, was das System-Dashboard rechnet und formatiert, ohne etwas vom Mac zu
// lesen. Das Lesen steht in `SystemLeser`; hier liegt nur, was sich ohne Hardware
// pruefen laesst.

/// Zaehlerstand eines Prozessorkerns: wie viele Ticks er gearbeitet hat und wie
/// viele insgesamt vergangen sind, jeweils seit dem Start.
struct KernTicks: Equatable {
    var arbeit: UInt64
    var gesamt: UInt64
}

/// Seitenzaehler aus der Speicherverwaltung des Kernels (`vm_statistics64`).
struct SeitenZaehler: Equatable {
    /// `internal_page_count`: Speicher, den Programme selbst angelegt haben.
    var intern: UInt64
    /// `purgeable_count`: davon der Teil, den das System jederzeit zurueckholen darf.
    var kaufbar: UInt64
    /// `external_page_count`: zwischengespeicherte Dateien.
    var extern: UInt64
    var wired: UInt64
    /// `compressor_page_count`: Seiten, die im Kompressor liegen.
    var komprimiert: UInt64
}

enum Speicherdruck: Equatable {
    case normal, erhoeht, kritisch

    /// `kern.memorystatus_vm_pressure_level`: 1, 2 oder 4.
    init(stufe: Int?) {
        switch stufe {
        case 2: self = .erhoeht
        case 4: self = .kritisch
        default: self = .normal
        }
    }
}

struct SpeicherStand: Equatable {
    var gesamt: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var komprimiert: UInt64 = 0
    var cache: UInt64 = 0
    var druck: Speicherdruck = .normal

    /// So rechnet die Aktivitaetsanzeige: Programme, fest verdrahtet, komprimiert.
    /// Der Dateicache zaehlt nicht mit, denn das System gibt ihn bei Bedarf her.
    var benutzt: UInt64 { app + wired + komprimiert }
    var frei: UInt64 { gesamt > benutzt ? gesamt - benutzt : 0 }
    var anteilBenutzt: Double { gesamt == 0 ? 0 : min(Double(benutzt) / Double(gesamt), 1) }
}

struct Luefter: Equatable {
    var drehzahl: Double
    var minimum: Double
    var maximum: Double

    /// Wie weit der Luefter zwischen Stillstand und Hoechstdrehzahl steht.
    var anteil: Double { maximum > 0 ? min(max(drehzahl / maximum, 0), 1) : 0 }
}

struct Temperaturen: Equatable {
    var cpuMittel: Double?
    var cpuMax: Double?
    var akku: Double?
    var ssd: Double?
}

enum ThermischerZustand: Equatable {
    case normal, erhoeht, hoch, kritisch
}

/// Ein vollstaendiger Messpunkt. Alles, was ein Mac nicht hat (Luefter im Air,
/// Akku im Mac mini), bleibt leer; die Ansicht zeigt dann einen Strich.
struct SystemStand: Equatable {
    var chip = ""
    var kerneP = 0
    var kerneE = 0
    var gpuKerne = 0

    /// Auslastung je Kern von 0 bis 1, in der Reihenfolge des Kernels:
    /// zuerst die Effizienz-, dann die Leistungskerne.
    var kernLast: [Double] = []
    var cpu: Double = 0
    var gpu: Double = 0

    var speicher = SpeicherStand()
    var temperaturen = Temperaturen()
    var luefter: [Luefter] = []

    /// Leistungsaufnahme des ganzen Macs in Watt.
    var leistung: Double?
    var akkuProzent: Int?
    var laedt = false
    var amNetzteil = false

    /// Bytes pro Sekunde.
    var down: Double = 0
    var up: Double = 0
    var plattenLesen: Double = 0
    var plattenSchreiben: Double = 0
    var plattenFrei: UInt64 = 0
    var plattenGesamt: UInt64 = 0

    var laufzeit: TimeInterval = 0
    var thermisch: ThermischerZustand = .normal

    var plattenBelegt: Double {
        plattenGesamt == 0 ? 0 : 1 - min(Double(plattenFrei) / Double(plattenGesamt), 1)
    }
}

/// Die letzten Messwerte einer Groesse, aelteste zuerst.
struct Messreihe: Equatable {
    static let laenge = 60
    private(set) var werte: [Double] = []

    mutating func fuegeAn(_ wert: Double) {
        werte.append(wert)
        if werte.count > Self.laenge { werte.removeFirst(werte.count - Self.laenge) }
    }
}

struct Verlaeufe: Equatable {
    var cpu = Messreihe()
    var gpu = Messreihe()
    var ram = Messreihe()
    var down = Messreihe()
    var up = Messreihe()
    var leistung = Messreihe()

    mutating func fuegeAn(_ s: SystemStand) {
        cpu.fuegeAn(s.cpu)
        gpu.fuegeAn(s.gpu)
        ram.fuegeAn(s.speicher.anteilBenutzt)
        down.fuegeAn(s.down)
        up.fuegeAn(s.up)
        leistung.fuegeAn(s.leistung ?? 0)
    }
}

enum SystemRechnung {

    // MARK: - Messen

    /// Auslastung je Kern zwischen zwei Zaehlerstaenden. Ein Kern, dessen Zaehler
    /// nicht weitergelaufen ist, steht bei null statt durch null zu teilen.
    static func kernLast(vorher: [KernTicks], nachher: [KernTicks]) -> [Double] {
        guard vorher.count == nachher.count else { return [] }
        return zip(vorher, nachher).map { alt, neu in
            guard neu.gesamt > alt.gesamt, neu.arbeit >= alt.arbeit else { return 0 }
            let arbeit = Double(neu.arbeit - alt.arbeit)
            let gesamt = Double(neu.gesamt - alt.gesamt)
            return min(max(arbeit / gesamt, 0), 1)
        }
    }

    /// Gesamtauslastung: alle Kerne gleich gewichtet, wie in der Aktivitaetsanzeige.
    static func gesamtLast(vorher: [KernTicks], nachher: [KernTicks]) -> Double {
        guard vorher.count == nachher.count, !vorher.isEmpty else { return 0 }
        var arbeit: UInt64 = 0
        var gesamt: UInt64 = 0
        for (alt, neu) in zip(vorher, nachher) where neu.gesamt > alt.gesamt && neu.arbeit >= alt.arbeit {
            arbeit += neu.arbeit - alt.arbeit
            gesamt += neu.gesamt - alt.gesamt
        }
        return gesamt == 0 ? 0 : min(Double(arbeit) / Double(gesamt), 1)
    }

    static func speicher(seiten z: SeitenZaehler, seitenGroesse: UInt64, gesamt: UInt64) -> SpeicherStand {
        var s = SpeicherStand()
        s.gesamt = gesamt
        s.app = (z.intern > z.kaufbar ? z.intern - z.kaufbar : 0) * seitenGroesse
        s.wired = z.wired * seitenGroesse
        s.komprimiert = z.komprimiert * seitenGroesse
        s.cache = (z.extern + z.kaufbar) * seitenGroesse
        return s
    }

    /// Temperaturen aus den Sensoren, die das System unter ihren Namen meldet.
    ///
    /// Die Chip-Sensoren heissen `PMU tdie1` bis `tdieN` (der Kern der Silizium-
    /// plaettchen), Akku und SSD je einmal. `tdev`-Sensoren liefern auf manchen
    /// Macs Platzhalter wie -9202, und `tcal` ist ein Kalibrierwert: beide gehoeren
    /// nicht in die Anzeige. Werte ausserhalb von 1 bis 130 Grad sind kein Messwert.
    static func temperaturen(aus lesungen: [(name: String, wert: Double)]) -> Temperaturen {
        func gueltig(_ w: Double) -> Bool { w > 1 && w < 130 }
        let chip = lesungen.filter { $0.name.hasPrefix("PMU tdie") && gueltig($0.wert) }.map(\.wert)
        let akku = lesungen.filter { $0.name == "gas gauge battery" && gueltig($0.wert) }.map(\.wert)
        let ssd = lesungen.filter { $0.name.hasPrefix("NAND") && gueltig($0.wert) }.map(\.wert)
        func mittel(_ w: [Double]) -> Double? { w.isEmpty ? nil : w.reduce(0, +) / Double(w.count) }
        return Temperaturen(cpuMittel: mittel(chip), cpuMax: chip.max(), akku: mittel(akku), ssd: mittel(ssd))
    }

    /// Zaehlerdifferenz eines 32-Bit-Zaehlers, der ueberlaufen darf. Ein Sprung
    /// ueber zwei Milliarden in einer Messung ist ein zurueckgesetzter Zaehler,
    /// keine Datenmenge.
    static func zaehlerDifferenz(alt: UInt32, neu: UInt32) -> UInt64 {
        let d = neu &- alt
        return d > UInt32(Int32.max) ? 0 : UInt64(d)
    }

    // MARK: - Zeigen

    /// Dezimalzahl mit Komma, ohne Rundungsueberraschungen je nach Region.
    static func dezimal(_ x: Double, stellen: Int = 1) -> String {
        String(format: "%.\(stellen)f", x).replacingOccurrences(of: ".", with: ",")
    }

    /// Eine Groesse in der passenden Einheit. `basis` ist 1024 fuer Arbeitsspeicher
    /// (so nennt ihn auch „Ueber diesen Mac“) und 1000 fuer Datentraeger und Netz.
    ///
    /// `kompakt` spart die Nachkommastelle ab zehn, fuer enge Zeilen: „12 MB“ statt „12,0 MB“.
    static func groesse(_ bytes: Double, basis: Double = 1024, kompakt: Bool = false) -> (zahl: String, einheit: String) {
        let einheiten = ["B", "KB", "MB", "GB", "TB"]
        var wert = max(bytes, 0)
        var stufe = 0
        while wert >= basis && stufe < einheiten.count - 1 {
            wert /= basis
            stufe += 1
        }
        // Bytes sind ganze Zahlen; ab 100 (kompakt ab 10) braucht keine Einheit eine Nachkommastelle.
        let stellen = (stufe == 0 || wert >= (kompakt ? 10 : 100)) ? 0 : 1
        return (dezimal(wert, stellen: stellen), einheiten[stufe])
    }

    static func rate(_ bytesProSekunde: Double) -> (zahl: String, einheit: String) {
        let g = groesse(bytesProSekunde, basis: 1000)
        return (g.zahl, g.einheit + "/s")
    }

    static func prozent(_ anteil: Double) -> String {
        "\(Int((min(max(anteil, 0), 1) * 100).rounded()))"
    }

    static func laufzeit(_ sekunden: TimeInterval) -> String {
        let minuten = Int(sekunden / 60)
        let tage = minuten / 1440
        let stunden = (minuten % 1440) / 60
        if tage > 0 { return "\(tage) T \(stunden) Std" }
        if stunden > 0 { return "\(stunden) Std \(minuten % 60) Min" }
        return "\(minuten) Min"
    }
}
