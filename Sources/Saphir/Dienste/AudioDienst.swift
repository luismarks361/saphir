import CoreAudio
import Foundation
import SwiftUI

struct Ausgabegeraet: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let symbol: String
    var istAktiv: Bool
}

/// Ausgabegeraete: welche es gibt, welches spielt, und der Wechsel dazwischen.
///
/// Was hier NICHT steht, ist die Lautstaerke je App und der Equalizer. Beides
/// laesst sich nur bauen, indem die App den Ton jeder fremden App abgreift,
/// selbst umrechnet und wieder ausgibt — mit eigenem Sammelgeraet und einem
/// zweiten Ausgabeweg. Das Original hat dafuer einen eigenen Audio-Unterbau
/// mit ueber vierzig Dateien. Halb gebaut waere es schlimmer als gar nicht:
/// jeder Aussetzer trifft den Ton, den man gerade hoert.
@MainActor
final class AudioDienst: ObservableObject {
    static let shared = AudioDienst()

    @Published private(set) var geraete: [Ausgabegeraet] = []
    @Published private(set) var lautstaerke: Float = 0.5

    private var takt: Timer?

    private init() {}

    func taktPruefen() {
        if Einstellungen.shared.istAn(.audioJeApp) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        lies()
        takt = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { AudioDienst.shared.lies() }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        geraete = []
    }

    func lies() {
        let aktiv = Self.standardAusgabe()
        lautstaerke = Systemsteuerung.lautstaerke()
        geraete = Self.alleAusgaben().map {
            Ausgabegeraet(id: $0.id, name: $0.name, symbol: Self.symbol(fuer: $0.name),
                          istAktiv: $0.id == aktiv)
        }
    }

    func waehle(_ geraet: Ausgabegeraet) {
        var kennung = geraet.id
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let groesse = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &adresse, 0, nil, groesse, &kennung)
        lies()
    }

    func setzeLautstaerke(_ wert: Float) {
        Systemsteuerung.setzeLautstaerke(wert)
        lautstaerke = wert
    }

    // MARK: - CoreAudio

    private static func standardAusgabe() -> AudioDeviceID {
        var kennung = AudioDeviceID(kAudioObjectUnknown)
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var groesse = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &adresse, 0, nil, &groesse, &kennung)
        return kennung
    }

    private static func alleAusgaben() -> [(id: AudioDeviceID, name: String)] {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var groesse: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &adresse, 0, nil, &groesse) == noErr else { return [] }
        let anzahl = Int(groesse) / MemoryLayout<AudioDeviceID>.size
        var kennungen = [AudioDeviceID](repeating: 0, count: anzahl)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &adresse, 0, nil, &groesse, &kennungen) == noErr else { return [] }

        return kennungen.compactMap { kennung in
            guard hatAusgang(kennung), let name = name(kennung) else { return nil }
            return (kennung, name)
        }
    }

    /// Nur Geraete, die wirklich etwas ausgeben. Mikrofone stehen sonst mit in
    /// der Liste.
    private static func hatAusgang(_ kennung: AudioDeviceID) -> Bool {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var groesse: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(kennung, &adresse, 0, nil, &groesse) == noErr,
              groesse > 0 else { return false }

        let puffer = UnsafeMutableRawPointer.allocate(byteCount: Int(groesse),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { puffer.deallocate() }
        guard AudioObjectGetPropertyData(kennung, &adresse, 0, nil, &groesse, puffer) == noErr else {
            return false
        }
        let liste = UnsafeMutableAudioBufferListPointer(puffer.assumingMemoryBound(to: AudioBufferList.self))
        return liste.contains { $0.mNumberChannels > 0 }
    }

    private static func name(_ kennung: AudioDeviceID) -> String? {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var groesse = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(kennung, &adresse, 0, nil, &groesse, &name) == noErr else {
            return nil
        }
        let text = name as String
        return text.isEmpty ? nil : text
    }

    static func symbol(fuer name: String) -> String {
        let klein = name.lowercased()
        if klein.contains("airpods max") { return "airpods.max" }
        if klein.contains("airpods pro") { return "airpods.pro" }
        if klein.contains("airpods") { return "airpods.gen3" }
        if klein.contains("kopfhoerer") || klein.contains("headphone") { return "headphones" }
        if klein.contains("macbook") || klein.contains("intern") || klein.contains("built") {
            return "laptopcomputer"
        }
        if klein.contains("display") || klein.contains("monitor") { return "display" }
        if klein.contains("homepod") { return "homepod" }
        return "hifispeaker"
    }
}
