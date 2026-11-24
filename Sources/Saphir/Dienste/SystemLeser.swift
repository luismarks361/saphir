import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Liest alle Werte des System-Dashboards vom Mac.
///
/// Gedacht fuer genau einen Faden: der Leser merkt sich die letzten Zaehlerstaende,
/// um daraus Raten zu bilden, und ist deshalb nicht fuer Zugriffe von mehreren
/// Seiten gleichzeitig gebaut. `SystemDienst` ruft ihn nur von seiner eigenen
/// Warteschlange aus.
final class SystemLeser {
    private let chip: String
    private let kerneP: Int
    private let kerneE: Int
    private let gpuKerne: Int

    private let temperatur: HIDTemperatur?
    private let smc: SMC?

    private var vorherKerne: [KernTicks]
    private var vorherNetz: [String: (ein: UInt32, aus: UInt32)] = [:]
    private var vorherPlatte: (gelesen: UInt64, geschrieben: UInt64)?
    private var vorherZeit = Date()

    // Temperatur und SMC aendern sich langsam und kosten mehr als die Zaehler:
    // sie werden nur bei jeder zweiten Messung gelesen und dazwischen gehalten.
    private var runde = 0
    private var letzteTemperaturen = Temperaturen()
    private var letzteLuefter: [Luefter] = []
    private var letzteLeistung: Double?
    // Der freie Platz aendert sich langsam, die Abfrage rechnet aber den
    // „kaufbaren“ Speicher mit und dauert rund 30 Millisekunden.
    private var letzterPlatz: (frei: UInt64, gesamt: UInt64) = (0, 0)

    init() {
        chip = Self.sysctlText("machdep.cpu.brand_string") ?? "Mac"
        // Auf Apple-Silicon ist Stufe 0 „Performance“, Stufe 1 „Efficiency“.
        // Ein Intel-Mac kennt die Stufen nicht: dort sind alle Kerne gleich.
        let gesamt = Self.sysctlZahl("hw.logicalcpu") ?? 0
        kerneP = Self.sysctlZahl("hw.perflevel0.logicalcpu") ?? gesamt
        kerneE = Self.sysctlZahl("hw.perflevel1.logicalcpu") ?? 0
        gpuKerne = Self.gpuKerneLesen()
        temperatur = HIDTemperatur()
        smc = SMC()
        vorherKerne = Self.kernTicks()
        vorherNetz = Self.netzZaehler()
        vorherPlatte = Self.plattenZaehler()
    }

    func messe() -> SystemStand {
        let jetzt = Date()
        let dt = max(jetzt.timeIntervalSince(vorherZeit), 0.05)
        vorherZeit = jetzt

        var s = SystemStand()
        s.chip = chip
        s.kerneP = kerneP
        s.kerneE = kerneE
        s.gpuKerne = gpuKerne

        let kerne = Self.kernTicks()
        s.kernLast = SystemRechnung.kernLast(vorher: vorherKerne, nachher: kerne)
        s.cpu = SystemRechnung.gesamtLast(vorher: vorherKerne, nachher: kerne)
        vorherKerne = kerne

        s.gpu = Self.gpuLast()
        s.speicher = Self.speicherLesen()

        if runde % 2 == 0 {
            if let t = temperatur { letzteTemperaturen = SystemRechnung.temperaturen(aus: t.lesungen()) }
            if let smc {
                letzteLuefter = smc.luefter()
                letzteLeistung = smc.systemLeistung()
            }
        }
        runde += 1
        s.temperaturen = letzteTemperaturen
        s.luefter = letzteLuefter
        s.leistung = letzteLeistung

        let netz = Self.netzZaehler()
        var ein: UInt64 = 0
        var aus: UInt64 = 0
        for (name, neu) in netz {
            guard let alt = vorherNetz[name] else { continue }
            ein += SystemRechnung.zaehlerDifferenz(alt: alt.ein, neu: neu.ein)
            aus += SystemRechnung.zaehlerDifferenz(alt: alt.aus, neu: neu.aus)
        }
        vorherNetz = netz
        s.down = Double(ein) / dt
        s.up = Double(aus) / dt

        if let platte = Self.plattenZaehler() {
            if let alt = vorherPlatte {
                // Die Summe laeuft nur vorwaerts, solange kein Laufwerk verschwindet.
                s.plattenLesen = Double(platte.gelesen >= alt.gelesen ? platte.gelesen - alt.gelesen : 0) / dt
                s.plattenSchreiben = Double(platte.geschrieben >= alt.geschrieben ? platte.geschrieben - alt.geschrieben : 0) / dt
            }
            vorherPlatte = platte
        }
        if runde % 15 == 1 { letzterPlatz = Self.plattenPlatz() }
        (s.plattenFrei, s.plattenGesamt) = letzterPlatz

        (s.akkuProzent, s.laedt, s.amNetzteil) = Self.akkuLesen()
        s.laufzeit = Self.laufzeitLesen()
        s.thermisch = Self.thermischLesen()
        return s
    }

    // MARK: - sysctl

    private static func sysctlZahl(_ name: String) -> Int? {
        var wert: Int64 = 0
        var groesse = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &wert, &groesse, nil, 0) == 0 else {
            // Manche Schluessel sind 32 Bit breit.
            var klein: Int32 = 0
            var kleinGroesse = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &klein, &kleinGroesse, nil, 0) == 0 else { return nil }
            return Int(klein)
        }
        return Int(wert)
    }

    private static func sysctlText(_ name: String) -> String? {
        var groesse = 0
        guard sysctlbyname(name, nil, &groesse, nil, 0) == 0, groesse > 0 else { return nil }
        var puffer = [CChar](repeating: 0, count: groesse)
        guard sysctlbyname(name, &puffer, &groesse, nil, 0) == 0 else { return nil }
        return String(cString: puffer)
    }

    // MARK: - Prozessor

    private static func kernTicks() -> [KernTicks] {
        var anzahl: natural_t = 0
        var info: processor_info_array_t?
        var infoAnzahl: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &anzahl, &info, &infoAnzahl) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoAnzahl) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let breite = Int(CPU_STATE_MAX)
        return (0..<Int(anzahl)).map { kern in
            func zaehler(_ zustand: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: info[kern * breite + Int(zustand)]))
            }
            let arbeit = zaehler(CPU_STATE_USER) + zaehler(CPU_STATE_SYSTEM) + zaehler(CPU_STATE_NICE)
            return KernTicks(arbeit: arbeit, gesamt: arbeit + zaehler(CPU_STATE_IDLE))
        }
    }

    // MARK: - Grafik

    private static func gpuKerneLesen() -> Int {
        let dienst = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard dienst != 0 else { return 0 }
        defer { IOObjectRelease(dienst) }
        let wert = IORegistryEntryCreateCFProperty(dienst, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return (wert?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
    }

    /// Auslastung der staerksten Grafikeinheit, 0 bis 1.
    private static func gpuLast() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        var hoechste = 0.0
        var eintrag = IOIteratorNext(iterator)
        while eintrag != 0 {
            if let roh = IORegistryEntryCreateCFProperty(eintrag, "PerformanceStatistics" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let werte = roh as? [String: Any],
               let last = (werte["Device Utilization %"] as? NSNumber)?.doubleValue {
                hoechste = max(hoechste, last / 100)
            }
            IOObjectRelease(eintrag)
            eintrag = IOIteratorNext(iterator)
        }
        return min(max(hoechste, 0), 1)
    }

    // MARK: - Arbeitsspeicher

    private static func speicherLesen() -> SpeicherStand {
        var stat = vm_statistics64()
        var anzahl = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(anzahl)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &anzahl)
            }
        }
        let gesamt = ProcessInfo.processInfo.physicalMemory
        guard r == KERN_SUCCESS else { return SpeicherStand(gesamt: gesamt) }

        let seite = UInt64(sysctlZahl("hw.pagesize") ?? 16384)
        var s = SystemRechnung.speicher(
            seiten: SeitenZaehler(intern: UInt64(stat.internal_page_count),
                                  kaufbar: UInt64(stat.purgeable_count),
                                  extern: UInt64(stat.external_page_count),
                                  wired: UInt64(stat.wire_count),
                                  komprimiert: UInt64(stat.compressor_page_count)),
            seitenGroesse: seite, gesamt: gesamt)
        s.druck = Speicherdruck(stufe: sysctlZahl("kern.memorystatus_vm_pressure_level"))
        return s
    }

    // MARK: - Netzwerk

    /// Zaehlerstand je Netzwerkkarte. Nur `en*`: das sind WLAN und Kabel. Ein VPN
    /// (`utun`) wuerde dieselben Bytes ein zweites Mal zaehlen.
    private static func netzZaehler() -> [String: (ein: UInt32, aus: UInt32)] {
        var liste: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&liste) == 0, let erste = liste else { return [:] }
        defer { freeifaddrs(liste) }

        var ergebnis: [String: (ein: UInt32, aus: UInt32)] = [:]
        var zeiger: UnsafeMutablePointer<ifaddrs>? = erste
        while let eintrag = zeiger {
            defer { zeiger = eintrag.pointee.ifa_next }
            let flags = Int32(eintrag.pointee.ifa_flags)
            guard let adresse = eintrag.pointee.ifa_addr,
                  adresse.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let daten = eintrag.pointee.ifa_data else { continue }
            let name = String(cString: eintrag.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let zaehler = daten.assumingMemoryBound(to: if_data.self).pointee
            ergebnis[name] = (zaehler.ifi_ibytes, zaehler.ifi_obytes)
        }
        return ergebnis
    }

    // MARK: - Datentraeger

    /// Summe aller gelesenen und geschriebenen Bytes seit dem Start.
    private static func plattenZaehler() -> (gelesen: UInt64, geschrieben: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var gelesen: UInt64 = 0
        var geschrieben: UInt64 = 0
        var gefunden = false
        var eintrag = IOIteratorNext(iterator)
        while eintrag != 0 {
            if let roh = IORegistryEntryCreateCFProperty(eintrag, "Statistics" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let werte = roh as? [String: Any] {
                gelesen += (werte["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                geschrieben += (werte["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                gefunden = true
            }
            IOObjectRelease(eintrag)
            eintrag = IOIteratorNext(iterator)
        }
        return gefunden ? (gelesen, geschrieben) : nil
    }

    private static func plattenPlatz() -> (frei: UInt64, gesamt: UInt64) {
        let schluessel: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let werte = try? URL(fileURLWithPath: "/").resourceValues(forKeys: schluessel) else { return (0, 0) }
        return (UInt64(max(werte.volumeAvailableCapacityForImportantUsage ?? 0, 0)),
                UInt64(max(werte.volumeTotalCapacity ?? 0, 0)))
    }

    // MARK: - Strom und Betrieb

    private static func akkuLesen() -> (prozent: Int?, laedt: Bool, amNetzteil: Bool) {
        guard let roh = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let liste = IOPSCopyPowerSourcesList(roh)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false, false)
        }
        for quelle in liste {
            guard let werte = IOPSGetPowerSourceDescription(roh, quelle)?.takeUnretainedValue() as? [String: Any],
                  let jetzt = werte[kIOPSCurrentCapacityKey] as? Int,
                  let voll = werte[kIOPSMaxCapacityKey] as? Int, voll > 0 else { continue }
            let laedt = (werte[kIOPSIsChargingKey] as? Bool) ?? false
            let amNetz = (werte[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Int((Double(jetzt) / Double(voll) * 100).rounded()), laedt, amNetz)
        }
        return (nil, false, false)
    }

    private static func laufzeitLesen() -> TimeInterval {
        var start = timeval()
        var groesse = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &start, &groesse, nil, 0) == 0, start.tv_sec > 0 else { return 0 }
        return max(Date().timeIntervalSince1970 - TimeInterval(start.tv_sec), 0)
    }

    private static func thermischLesen() -> ThermischerZustand {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .normal
        case .fair: return .erhoeht
        case .serious: return .hoch
        case .critical: return .kritisch
        @unknown default: return .normal
        }
    }
}
