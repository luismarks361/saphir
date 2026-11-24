import Foundation
import IOKit

// Die beiden Quellen, die macOS nicht als Programmierschnittstelle anbietet,
// aber ohne Root-Rechte herausgibt: die Temperatursensoren (ueber das HID-System,
// wie es die Sensoranzeigen anderer Apps auch tun) und den SMC fuer Luefter und
// Leistungsaufnahme.
//
// Beides ist undokumentiert. Darum werden die Funktionen erst zur Laufzeit per
// `dlsym` gesucht: benennt Apple etwas um, fehlen dem Dashboard ein paar Werte,
// aber Saphir startet weiter. Mit festem Linken waere es beim Start abgestuerzt.

/// Temperatursensoren des Chips, des Akkus und der SSD.
final class HIDTemperatur {
    private typealias ErzeugeFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetzeFilterFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias DiensteFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias EigenschaftFn = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias EreignisFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias WertFn = @convention(c) (AnyObject, Int32) -> Double

    private let client: AnyObject
    /// Nur die Sensoren, die das Dashboard zeigt, mit ihrem Namen. Das System meldet
    /// ueber siebzig, viele doppelt oder mit Platzhaltern; jedes Lesen kostet einen
    /// Aufruf in den Treiber, und alle zu lesen war der groesste Posten der Messung.
    private let dienste: [(name: String, dienst: AnyObject)]
    private let ereignis: EreignisFn
    private let wert: WertFn

    /// Typ 15 ist `kIOHIDEventTypeTemperature`; das Wertfeld liegt bei Typ << 16.
    private static let typTemperatur: Int64 = 15
    private static let feldTemperatur: Int32 = 15 << 16

    init?() {
        let h = dlopen(nil, RTLD_NOW)
        func suche<T>(_ name: String, als _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let erzeuge = suche("IOHIDEventSystemClientCreate", als: ErzeugeFn.self),
              let filter = suche("IOHIDEventSystemClientSetMatching", als: SetzeFilterFn.self),
              let liste = suche("IOHIDEventSystemClientCopyServices", als: DiensteFn.self),
              let eigenschaft = suche("IOHIDServiceClientCopyProperty", als: EigenschaftFn.self),
              let ereignis = suche("IOHIDServiceClientCopyEvent", als: EreignisFn.self),
              let wert = suche("IOHIDEventGetFloatValue", als: WertFn.self),
              let client = erzeuge(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }

        // Seite 0xff00, Nutzung 5: die Temperatursensoren.
        _ = filter(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let alle = liste(client)?.takeRetainedValue() as? [AnyObject], !alle.isEmpty else { return nil }

        var gesehen = Set<String>()
        var relevante: [(name: String, dienst: AnyObject)] = []
        for dienst in alle {
            guard let name = eigenschaft(dienst, "Product" as CFString)?.takeRetainedValue() as? String,
                  Self.zeigtDasDashboard(name), gesehen.insert(name).inserted else { continue }
            relevante.append((name, dienst))
        }
        guard !relevante.isEmpty else { return nil }

        self.client = client
        self.dienste = relevante
        self.ereignis = ereignis
        self.wert = wert
    }

    /// Chip-Sensoren (`PMU tdie…`), Akku und SSD. `tdev` und `tcal` zeigen nichts Brauchbares.
    static func zeigtDasDashboard(_ name: String) -> Bool {
        name.hasPrefix("PMU tdie") || name == "gas gauge battery" || name.hasPrefix("NAND")
    }

    func lesungen() -> [(name: String, wert: Double)] {
        dienste.compactMap { eintrag in
            guard let e = ereignis(eintrag.dienst, Self.typTemperatur, 0, 0)?.takeRetainedValue() else { return nil }
            return (eintrag.name, wert(e, Self.feldTemperatur))
        }
    }
}

/// Der System Management Controller: Luefter, Leistungsaufnahme.
final class SMC {
    // Der Aufbau muss Bit fuer Bit stimmen, sonst antwortet der Treiber mit
    // Unsinn oder gar nicht. Ein Test prueft die Gesamtgroesse (80 Byte).
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct Grenze { var version: UInt16 = 0, laenge: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, speicher: UInt32 = 0 }
    struct SchluesselInfo { var datenGroesse: UInt32 = 0, datenTyp: UInt32 = 0, attribute: UInt8 = 0 }
    struct Bytes32 {
        var b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
    struct Anfrage {
        var schluessel: UInt32 = 0
        var version = Version()
        var grenze = Grenze()
        var info = SchluesselInfo()
        var fuell: UInt16 = 0
        var ergebnis: UInt8 = 0
        var status: UInt8 = 0
        var befehl: UInt8 = 0
        var daten32: UInt32 = 0
        var bytes = Bytes32()
    }

    private static let befehlInfo: UInt8 = 9
    private static let befehlLesen: UInt8 = 5

    private var verbindung: io_connect_t = 0

    init?() {
        let dienst = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard dienst != 0 else { return nil }
        defer { IOObjectRelease(dienst) }
        guard IOServiceOpen(dienst, mach_task_self_, 0, &verbindung) == KERN_SUCCESS else { return nil }
    }

    deinit {
        if verbindung != 0 { IOServiceClose(verbindung) }
    }

    private static func vierZeichen(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func vierZeichen(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)],
               encoding: .ascii) ?? ""
    }

    private func rufe(_ anfrage: inout Anfrage) -> Bool {
        var antwort = Anfrage()
        var groesse = MemoryLayout<Anfrage>.stride
        // Selektor 2 ist `kSMCHandleYPCEvent`.
        let r = IOConnectCallStructMethod(verbindung, 2, &anfrage, MemoryLayout<Anfrage>.stride, &antwort, &groesse)
        anfrage = antwort
        return r == KERN_SUCCESS && antwort.ergebnis == 0
    }

    /// Typ und Rohbytes eines Schluessels, oder nil wenn dieser Mac ihn nicht kennt.
    func roh(_ schluessel: String) -> (typ: String, bytes: [UInt8])? {
        var a = Anfrage()
        a.schluessel = Self.vierZeichen(schluessel)
        a.befehl = Self.befehlInfo
        guard rufe(&a) else { return nil }
        let info = a.info
        // Den Schluessel neu setzen: die Antwort des Treibers gibt ihn nicht zurueck.
        var b = Anfrage()
        b.schluessel = Self.vierZeichen(schluessel)
        b.info = info
        b.befehl = Self.befehlLesen
        guard rufe(&b) else { return nil }
        let n = min(Int(info.datenGroesse), 32)
        let bytes = withUnsafeBytes(of: b.bytes.b) { Array($0.prefix(n)) }
        return (Self.vierZeichen(info.datenTyp), bytes)
    }

    /// Ein Zahlenwert, egal ob der SMC ihn als Gleitkomma oder Ganzzahl fuehrt.
    func zahl(_ schluessel: String) -> Double? {
        guard let (typ, b) = roh(schluessel) else { return nil }
        switch typ {
        case "flt " where b.count >= 4:
            // Der SMC liefert Gleitkommazahlen in der Byte-Reihenfolge des Prozessors.
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ui8 " where b.count >= 1:
            return Double(b[0])
        case "ui16" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    func luefter() -> [Luefter] {
        let anzahl = Int(zahl("FNum") ?? 0)
        guard anzahl > 0 else { return [] }
        return (0..<min(anzahl, 4)).compactMap { i in
            guard let ist = zahl("F\(i)Ac") else { return nil }
            return Luefter(drehzahl: max(ist, 0), minimum: zahl("F\(i)Mn") ?? 0, maximum: zahl("F\(i)Mx") ?? 0)
        }
    }

    /// Leistungsaufnahme des ganzen Macs in Watt.
    func systemLeistung() -> Double? {
        guard let w = zahl("PSTR"), w >= 0, w < 1000 else { return nil }
        return w
    }
}
