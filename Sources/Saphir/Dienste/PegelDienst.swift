import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

/// Vier Pegel aus dem Ton, der gerade wirklich laeuft: tief, tiefmittig,
/// hochmittig, hoch. Genau das, was ein Equalizer zeigt.
///
/// Warum echter Ton und nicht die Schleife des Originals: Apples Dynamic Island
/// und Sapphire messen nichts, sie lassen eine feste Figur laufen. Das faellt
/// auf, sobald ein Stueck leise wird und die Balken munter weitertanzen. Hier
/// bewegt sich, was man hoert.
///
/// Der Weg dorthin ist ein **Prozess-Tap** (macOS 14.4+): CoreAudio legt eine
/// Abzweigung auf den Systemton und haengt sie als Aggregatgeraet ein. Kein
/// virtuelles Ausgabegeraet, kein Umweg ueber die Bildschirmaufnahme, keine
/// Freigabe. Der eigene Ton der App ist ausgenommen — sonst wuerden Saphirs
/// eigene Klaenge die Balken bewegen.
///
/// Klappt der Tap nicht (kein Ausgabegeraet, aeltere Systeme), liefert `lies()`
/// eine gerechnete Figur wie im Original. Die Ansicht kennt darum nur einen
/// Weg: Pegel holen, Balken setzen.
final class PegelDienst: @unchecked Sendable {
    static let shared = PegelDienst()

    /// Vier Baender — mehr passen neben die Kamera nicht, weniger trennen Bass
    /// und Stimme nicht mehr.
    static let anzahl = 4

    /// Grenzen in Hertz. Bass, Grundton, Praesenz, Hoehen — die vier Bereiche,
    /// in denen sich Musik hoerbar unterscheidet.
    private static let grenzen: [Float] = [40, 180, 700, 2600, 10000]

    /// Fensterlaenge. 1024 bei 48 kHz sind 21 ms: fein genug fuer den Bass
    /// (47 Hz je Punkt) und schnell genug fuer rund 45 Messungen je Sekunde.
    private static let n = 1024

    /// Ab wo ein Band als still gilt und wo es voll ausschlaegt (in dB).
    /// Je Band verschoben, weil Musik nach oben hin leiser wird: ohne den
    /// Ausgleich zappelt links alles und rechts passiert nichts.
    /// Gemessen mit rosa Rauschen bei -16 dBFS (so laut wie ein gemastertes
    /// Stueck): so stehen alle vier Balken dann bei rund 0,8 und haben nach
    /// oben noch Luft fuer Schlaege.
    private static let leise: [Float] = [-58, -65, -76, -82]
    private static let laut: [Float] = [-16, -23, -34, -40]

    private let sperre = NSLock()
    private var pegel = [Float](repeating: 0, count: PegelDienst.anzahl)
    private var laeuft = false

    // Tap
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var geraetId = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var horcht = false
    private var wachposten: AudioObjectPropertyListenerBlock?

    // Analyse (nur vom Audio-Thread benutzt)
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let fenster = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                      count: PegelDienst.n, isHalfWindow: false)
    private var puffer = [Float](repeating: 0, count: PegelDienst.n)
    private var fuellstand = 0
    private var bereiche: [(Int, Int)] = []

    private init() {}

    // MARK: - Nach aussen

    /// Der aktuelle Stand, 0 bis 1 je Band. Von jedem Thread aufrufbar.
    func lies() -> [Float] {
        sperre.lock()
        let werte = pegel
        let echt = laeuft
        sperre.unlock()
        return echt ? werte : Self.ersatzfigur()
    }

    /// An, solange die Balken zu sehen sind. Doppelt schadet nicht.
    func setzeBedarf(_ an: Bool) {
        if an { starte() } else { stoppe() }
    }

    // MARK: - Tap

    private func starte() {
        guard !horcht else { return }
        horcht = true
        guard baueAuf() else {
            Protokoll.fehler("Pegel: kein Zugriff auf den Systemton, Balken laufen als Figur.")
            return
        }
        // Wechselt das Ausgabegeraet (AirPods rein), zeigt das Aggregat ins
        // Leere. Ohne diesen Wachposten stuenden die Balken ab dann still.
        // Er meldet sich auf dem Hauptthread, wie `starte`/`stoppe` auch —
        // sonst baut er Taps um, waehrend dort gerade einer abgerissen wird.
        let posten: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.horcht else { return }
            self.reisseAb()
            _ = self.baueAuf()
        }
        wachposten = posten
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.standardAdresse, .main, posten)
    }

    private func stoppe() {
        guard horcht else { return }
        horcht = false
        // Abmelden geht nur mit genau dem Block, der angemeldet wurde. Ein
        // neuer Block trifft nichts: dann sammeln sich bei jedem Einblenden
        // weitere Wachposten an, und beim Geraetewechsel bauen alle zugleich
        // Taps auf, die in denselben Puffer schreiben (Absturz 23.09.2026).
        if let posten = wachposten {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.standardAdresse, .main, posten)
            wachposten = nil
        }
        reisseAb()
    }

    private func baueAuf() -> Bool {
        guard let uid = Self.standardAusgabeUid() else { return false }

        let beschreibung = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.eigenerProzess())
        beschreibung.uuid = UUID()
        beschreibung.muteBehavior = CATapMuteBehavior.unmuted
        beschreibung.isPrivate = true
        guard AudioHardwareCreateProcessTap(beschreibung, &tapId) == noErr else { return false }

        let aggregat: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Saphir Pegel",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            // Privat heisst: taucht in den Toneinstellungen nicht auf und
            // verschwindet mit der App.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: beschreibung.uuid.uuidString]]
        ]
        guard AudioHardwareCreateAggregateDevice(aggregat as CFDictionary, &geraetId) == noErr else {
            reisseAb()
            return false
        }

        let rate = Self.abtastrate(tapId)
        bereiche = Self.grenzenInPunkte(rate: rate)
        fuellstand = 0

        let warteschlange = DispatchQueue(label: "saphir.pegel", qos: .userInitiated)
        let fehler = AudioDeviceCreateIOProcIDWithBlock(&proc, geraetId, warteschlange) {
            [weak self] _, daten, _, _, _ in
            self?.nimmAuf(daten)
        }
        guard fehler == noErr, AudioDeviceStart(geraetId, proc) == noErr else {
            reisseAb()
            return false
        }

        sperre.lock(); laeuft = true; sperre.unlock()
        return true
    }

    private func reisseAb() {
        sperre.lock(); laeuft = false; pegel = [Float](repeating: 0, count: Self.anzahl); sperre.unlock()
        if let proc, geraetId != kAudioObjectUnknown {
            AudioDeviceStop(geraetId, proc)
            AudioDeviceDestroyIOProcID(geraetId, proc)
        }
        proc = nil
        if geraetId != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(geraetId) }
        if tapId != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapId) }
        geraetId = AudioObjectID(kAudioObjectUnknown)
        tapId = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Analyse

    /// Laeuft auf dem Audio-Thread. Hier wird nichts gewartet und nichts
    /// angelegt — nur gerechnet.
    private func nimmAuf(_ daten: UnsafePointer<AudioBufferList>) {
        let liste = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: daten))
        guard let puf = liste.first, let roh = puf.mData else { return }
        let kanaele = Int(puf.mNumberChannels)
        guard kanaele > 0 else { return }
        let werte = roh.assumingMemoryBound(to: Float.self)
        let anzahl = Int(puf.mDataByteSize) / MemoryLayout<Float>.size
        let rahmen = anzahl / kanaele

        // Auf ein Ohr zusammenlegen: der Balken links soll nicht davon
        // abhaengen, ob der Bass im linken Kanal sitzt.
        for i in 0..<rahmen {
            var summe: Float = 0
            for k in 0..<kanaele { summe += werte[i * kanaele + k] }
            puffer[fuellstand] = summe / Float(kanaele)
            fuellstand += 1
            if fuellstand == Self.n { fuellstand = 0; rechne() }
        }
    }

    private var gefenstert = [Float](repeating: 0, count: PegelDienst.n)
    private var real = [Float](repeating: 0, count: PegelDienst.n / 2)
    private var imag = [Float](repeating: 0, count: PegelDienst.n / 2)
    private var realAus = [Float](repeating: 0, count: PegelDienst.n / 2)
    private var imagAus = [Float](repeating: 0, count: PegelDienst.n / 2)
    private var leistung = [Float](repeating: 0, count: PegelDienst.n / 2)

    private func rechne() {
        vDSP.multiply(puffer, fenster, result: &gefenstert)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                realAus.withUnsafeMutableBufferPointer { rap in
                    imagAus.withUnsafeMutableBufferPointer { iap in
                        var ein = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        var aus = DSPSplitComplex(realp: rap.baseAddress!, imagp: iap.baseAddress!)
                        gefenstert.withUnsafeBytes { roh in
                            let paare = roh.bindMemory(to: DSPComplex.self)
                            vDSP_ctoz(paare.baseAddress!, 2, &ein, 1, vDSP_Length(Self.n / 2))
                        }
                        fft.forward(input: ein, output: &aus)
                        vDSP_zvmags(&aus, 1, &leistung, 1, vDSP_Length(Self.n / 2))
                    }
                }
            }
        }

        // vDSP rechnet ohne Normierung und legt den Faktor 2 der Hin-
        // transformation obendrauf; das Hann-Fenster nimmt die Haelfte weg.
        let norm = Float(Self.n) * Float(Self.n)

        sperre.lock()
        for b in 0..<Self.anzahl {
            let (von, bis) = bereiche[b]
            var summe: Float = 0
            leistung.withUnsafeBufferPointer { p in
                vDSP_sve(p.baseAddress! + von, 1, &summe, vDSP_Length(bis - von))
            }
            // Mittel je Punkt, nicht Summe: die oberen Baender sind viel
            // breiter und wuerden sonst allein durch ihre Breite gewinnen.
            let db = 10 * log10(summe / Float(bis - von) / norm + 1e-12)
            let roh = min(max((db - Self.leise[b]) / (Self.laut[b] - Self.leise[b]), 0), 1)
            // Schnell hoch, gebremst zurueck — sonst flackert jeder Schlag.
            let alt = pegel[b]
            pegel[b] = roh > alt ? alt + (roh - alt) * 0.65 : alt + (roh - alt) * 0.20
        }
        sperre.unlock()
    }

    // MARK: - Kleinkram

    private static var standardAdresse = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func standardAusgabeUid() -> String? {
        var kennung = AudioDeviceID(kAudioObjectUnknown)
        var groesse = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &standardAdresse, 0, nil, &groesse, &kennung) == noErr,
              kennung != kAudioObjectUnknown else { return nil }

        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var g2 = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(kennung, &adresse, 0, nil, &g2, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Saphirs eigener Ton bleibt draussen.
    private static func eigenerProzess() -> [AudioObjectID] {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var objekt = AudioObjectID(kAudioObjectUnknown)
        var groesse = UInt32(MemoryLayout<AudioObjectID>.size)
        let fehler = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &adresse, UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &groesse, &objekt)
        guard fehler == noErr, objekt != kAudioObjectUnknown else { return [] }
        return [objekt]
    }

    private static func abtastrate(_ tap: AudioObjectID) -> Float {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var groesse = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &adresse, 0, nil, &groesse, &format) == noErr,
              format.mSampleRate > 0 else { return 48000 }
        return Float(format.mSampleRate)
    }

    private static func grenzenInPunkte(rate: Float) -> [(Int, Int)] {
        let breite = rate / Float(n)
        return (0..<anzahl).map { b in
            let von = max(1, Int(grenzen[b] / breite))
            let bis = min(n / 2, max(von + 1, Int(grenzen[b + 1] / breite)))
            return (von, bis)
        }
    }

    /// Notnagel, wenn kein Ton abzugreifen ist: dieselbe Figur wie im Original,
    /// nur aus der Uhr statt aus einer Animation.
    private static func ersatzfigur() -> [Float] {
        let t = CACurrentMediaTime()
        let tempo: [Double] = [1.7, 2.3, 2.9, 2.1]
        let hoehe: [Double] = [0.85, 0.6, 0.75, 0.55]
        return (0..<anzahl).map { i in
            Float((sin(t * tempo[i] * .pi) * 0.5 + 0.5) * hoehe[i])
        }
    }
}
