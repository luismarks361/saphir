import AppKit
import CoreAudio

/// Lautstaerke und Helligkeit lesen und setzen.
///
/// Entspricht `SystemControl` im Original. Die Lautstaerke laeuft ueber
/// CoreAudio mit AppleScript als Rueckfall, die Helligkeit ueber
/// DisplayServices.
enum Systemsteuerung {

    // MARK: - Lautstaerke

    static func lautstaerke() -> Float {
        if let geraet = ausgabegeraet(),
           let wert = zahl(von: geraet, kAudioDevicePropertyVolumeScalar) {
            return wert
        }
        return skript("output volume of (get volume settings)").map { Float($0) / 100 } ?? 0.5
    }

    static func setzeLautstaerke(_ wert: Float) {
        let sauber = min(max(wert, 0), 1)
        if let geraet = ausgabegeraet(),
           setze(sauber, an: geraet, kAudioDevicePropertyVolumeScalar) {
            return
        }
        // Unter 5 Prozent aufrunden, sonst landet der erste Schritt aus der
        // Stille wieder bei null und die Taste scheint nicht zu wirken.
        let prozent = sauber < 0.05
            ? Int(ceil(sauber * 100))
            : Int((sauber * 100).rounded(.toNearestOrAwayFromZero))
        _ = skript("set volume output volume \(prozent)")
    }

    static func istStumm() -> Bool {
        if let geraet = ausgabegeraet(), let wert = schalter(von: geraet, kAudioDevicePropertyMute) {
            return wert
        }
        return skript("output muted of (get volume settings)").map { $0 != 0 } ?? false
    }

    static func setzeStumm(_ stumm: Bool) {
        if let geraet = ausgabegeraet(), setze(stumm, an: geraet, kAudioDevicePropertyMute) { return }
        _ = skript(stumm ? "set volume with output muted" : "set volume without output muted")
    }

    // MARK: - Helligkeit

    static func helligkeit() -> Float {
        guard let hole = anzeigedienst?.hole,
              let bildschirm = NSScreen.main,
              let kennung = bildschirmKennung(bildschirm) else { return 0.5 }
        var wert: Float = 0
        return hole(kennung, &wert) == 0 ? wert : 0.5
    }

    /// Setzt alle Bildschirme, wie im Original: die Helligkeitstaste des Macs
    /// meint den ganzen Arbeitsplatz, nicht nur das eingebaute Display.
    static func setzeHelligkeit(_ wert: Float) {
        guard let setze = anzeigedienst?.setze else { return }
        let sauber = min(max(wert, 0), 1)
        for bildschirm in NSScreen.screens {
            guard let kennung = bildschirmKennung(bildschirm) else { continue }
            _ = setze(kennung, sauber)
        }
    }

    /// Ob die Helligkeit ueberhaupt gestellt werden kann.
    static var helligkeitVerfuegbar: Bool { anzeigedienst != nil }

    // MARK: - CoreAudio

    private static func ausgabegeraet() -> AudioDeviceID? {
        var kennung = AudioDeviceID(kAudioObjectUnknown)
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var groesse = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &adresse, 0, nil, &groesse, &kennung) == noErr,
              kennung != kAudioObjectUnknown else { return nil }
        return kennung
    }

    /// Manche Geraete fuehren die Lautstaerke am Hauptkanal, andere nur an
    /// Kanal 0. Das Original probiert beides, hier steht es an einer Stelle.
    private static func kanaele(_ auswahl: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        [kAudioObjectPropertyElementMain, 0].map {
            AudioObjectPropertyAddress(mSelector: auswahl,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: $0)
        }
    }

    private static func zahl(von geraet: AudioDeviceID,
                             _ auswahl: AudioObjectPropertySelector) -> Float? {
        for var adresse in kanaele(auswahl) {
            var wert: Float = 0
            var groesse = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(geraet, &adresse, 0, nil, &groesse, &wert) == noErr {
                return wert
            }
        }
        return nil
    }

    private static func schalter(von geraet: AudioDeviceID,
                                 _ auswahl: AudioObjectPropertySelector) -> Bool? {
        for var adresse in kanaele(auswahl) {
            guard AudioObjectHasProperty(geraet, &adresse) else { continue }
            var wert: UInt32 = 0
            var groesse = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(geraet, &adresse, 0, nil, &groesse, &wert) == noErr {
                return wert != 0
            }
        }
        return nil
    }

    private static func setze(_ wert: Float, an geraet: AudioDeviceID,
                              _ auswahl: AudioObjectPropertySelector) -> Bool {
        for var adresse in kanaele(auswahl) {
            var neu = wert
            let groesse = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(geraet, &adresse, 0, nil, groesse, &neu) == noErr {
                return true
            }
        }
        return false
    }

    private static func setze(_ wert: Bool, an geraet: AudioDeviceID,
                              _ auswahl: AudioObjectPropertySelector) -> Bool {
        for var adresse in kanaele(auswahl) {
            var neu: UInt32 = wert ? 1 : 0
            let groesse = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(geraet, &adresse, 0, nil, groesse, &neu) == noErr {
                return true
            }
        }
        return false
    }

    @discardableResult
    private static func skript(_ quelle: String) -> Int32? {
        var fehler: NSDictionary?
        let ergebnis = NSAppleScript(source: quelle)?.executeAndReturnError(&fehler)
        guard fehler == nil else { return nil }
        return ergebnis?.int32Value
    }

    // MARK: - DisplayServices

    private typealias Holen = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setzen = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Die Helligkeit laesst sich nur ueber DisplayServices stellen, und das
    /// ist ein privates Framework.
    ///
    /// Nachgeladen statt fest dazugebunden: waere es fest gebunden und Apple
    /// benennt es um, startet Saphir gar nicht mehr. So faellt nur die
    /// Helligkeitsanzeige aus, und die Taste macht wieder das Uebliche.
    private static let anzeigedienst: (hole: Holen, setze: Setzen)? = {
        let pfad = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let griff = dlopen(pfad, RTLD_LAZY),
              let h = dlsym(griff, "DisplayServicesGetBrightness"),
              let s = dlsym(griff, "DisplayServicesSetBrightness") else {
            Protokoll.info("DisplayServices nicht verfuegbar, Helligkeit bleibt beim System")
            return nil
        }
        return (unsafeBitCast(h, to: Holen.self), unsafeBitCast(s, to: Setzen.self))
    }()

    private static func bildschirmKennung(_ bildschirm: NSScreen) -> CGDirectDisplayID? {
        bildschirm.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
