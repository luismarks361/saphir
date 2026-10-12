import AVFoundation
import Foundation

/// Die Klaenge der Insel als reine Rechnung — keine Audiodateien im Paket.
///
/// Uebernommen aus Agent Island (Familie „Puls"): reiner
/// Sinus mit kaum hoerbarem Oktavanteil, trocken, Abklingen 130 ms, Lage um
/// A4. Kurz, weich, leise. Die Ereignisse sind andere als dort — eine Insel,
/// die Musik zeigt und Dateien annimmt, klingt bei anderen Gelegenheiten als
/// ein Agenten-Melder.
enum KlangSynthese {
    static let abtastrate: Double = 48_000
    private static let teiltoene: [(mult: Double, pegel: Double)] = [(1.0, 1.0), (2.0, 0.06)]
    private static let anstieg: Double = 0.005
    private static let maxAbkling: Double = 0.13
    private static let raster: Double = 0.068

    struct Ton {
        let hz: Double
        let dauer: Double
        var ab: Double? = nil
        var abkling: Double? = nil
        var pegel: Double = 1
    }

    enum Anlass: String, CaseIterable {
        /// Insel geht auf — soll kaum auffallen.
        case auf
        /// Insel geht zu.
        case zu
        /// Etwas ist im Regal gelandet.
        case abgelegt
        /// Eine Erinnerung meldet sich (Brille, Augenpause).
        case erinnerung
        /// Der Nachtmodus geht an.
        case nacht
        /// Eine Claude-Session ist mit ihrer Aufgabe fertig.
        case fertig
        /// Eine Claude-Session ist abgebrochen oder das Kontingent ist fast leer.
        case fehler

        var toene: [Ton] {
            switch self {
            case .auf: return [Ton(hz: 330.00, dauer: 0.055)]
            case .zu: return [Ton(hz: 261.63, dauer: 0.055)]
            // Etwas ist angekommen: Quarte aufwaerts, kurz und bestimmt.
            case .abgelegt: return [Ton(hz: 440.00, dauer: 0.110),
                                    Ton(hz: 587.33, dauer: 0.150)]
            // Zweimal derselbe Ton, der zweite leiser: das klingt wie Anklopfen
            // und nicht wie eine Meldung.
            case .erinnerung: return [Ton(hz: 493.88, dauer: 0.090, ab: 0.000, abkling: 0.055),
                                      Ton(hz: 493.88, dauer: 0.110, ab: 0.105, abkling: 0.055,
                                          pegel: 0.85)]
            // Abwaerts in ruhige Lage — der Tag geht zu Ende.
            case .nacht: return [Ton(hz: 440.00, dauer: 0.130),
                                 Ton(hz: 293.66, dauer: 0.220)]
            // Aus Agent Island: A4, Cis5, A5, endet eine Oktave ueber dem Start.
            case .fertig: return [Ton(hz: 440.00, dauer: 0.130),
                                  Ton(hz: 554.37, dauer: 0.130),
                                  Ton(hz: 880.00, dauer: 0.220)]
            // Faellt eine Quarte, tief und weich. Nie hart.
            case .fehler: return [Ton(hz: 329.63, dauer: 0.160),
                                  Ton(hz: 220.00, dauer: 0.240)]
            }
        }

        /// Spitzenpegel in dBFS. Die Insel gibt ungefragt Laut, also leiser als
        /// eine Seite, die auf einen Klick antwortet.
        var spitze: Double {
            switch self {
            case .auf, .zu: return -24
            default: return -17
            }
        }
    }

    private static func beginn(_ ton: Ton, index: Int) -> Double {
        ton.ab ?? Double(index) * raster
    }

    /// Weiche Huellkurve. Die letzten 6 ms laufen linear auf null, sonst knackt
    /// das Ende.
    private static func huelle(_ i: Int, laenge: Int, abkling: Double) -> Double {
        let t = Double(i) / abtastrate
        let a = pow(min(t / anstieg, 1.0), 0.7)
        let d = exp(-4.5 * t / abkling)
        let ende = min(Double(laenge - i) / (0.006 * abtastrate), 1.0)
        return a * d * max(ende, 0)
    }

    static func rechne(_ anlass: Anlass) -> [Float] {
        let toene = anlass.toene
        let gesamt = toene.enumerated()
            .map { beginn($0.element, index: $0.offset) + $0.element.dauer }
            .max() ?? 0
        let anzahl = Int(gesamt * abtastrate)
        guard anzahl > 0 else { return [] }

        var puffer = [Double](repeating: 0, count: anzahl)
        for (index, ton) in toene.enumerated() {
            let start = Int(beginn(ton, index: index) * abtastrate)
            let laenge = Int(ton.dauer * abtastrate)
            let abkling = ton.abkling ?? min(ton.dauer, maxAbkling)
            for i in 0..<laenge {
                let stelle = start + i
                guard stelle < anzahl else { break }
                let t = Double(i) / abtastrate
                var wert = 0.0
                for teil in teiltoene {
                    wert += teil.pegel * sin(2 * .pi * ton.hz * teil.mult * t)
                }
                puffer[stelle] += wert * huelle(i, laenge: laenge, abkling: abkling) * ton.pegel
            }
        }

        let spitze = puffer.reduce(0.0) { max($0, abs($1)) }
        guard spitze > 1e-9 else { return puffer.map { Float($0) } }
        let faktor = pow(10.0, anlass.spitze / 20.0) / spitze
        return puffer.map { Float($0 * faktor) }
    }
}

/// Spielt die Klaenge. Gerechnet wird beim ersten Mal, danach aus dem Speicher.
final class Klang {
    static let shared = Klang()

    private let maschine = AVAudioEngine()
    private let spieler = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KlangSynthese.abtastrate,
                                       channels: 1)!
    private var gerechnet: [KlangSynthese.Anlass: AVAudioPCMBuffer] = [:]
    private var haengtDrin = false

    private init() {
        // Wechselt das Ausgabegeraet oder nur dessen Abtastrate — Kopfhoerer
        // rein, Bluetooth verbunden, Aufwachen aus dem Ruhezustand —, dann
        // haelt macOS die Maschine an. Wer sich merkt „laeuft schon", schiebt
        // ab da Puffer in eine tote Maschine: kein Fehler, kein Ton.
        // Alles laeuft auf dem Hauptthread, darum keine Sperre: ein NSLock
        // bleibt fuer immer zu, wenn die Maschine dazwischen eine
        // Objective-C-Ausnahme wirft (dann laeuft kein `defer`), und beim
        // naechsten Aufklappen steht die ganze App.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: maschine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.spieler.stop()
            self.maschine.stop()
        }
    }

    static func spiele(_ anlass: KlangSynthese.Anlass) {
        shared.spiele(anlass)
    }

    func spiele(_ anlass: KlangSynthese.Anlass) {
        guard MainActor.assumeIsolated({ Einstellungen.shared.klaengeAn }) else { return }
        guard laeuft() else { return }

        let puffer = gerechnet[anlass] ?? baue(anlass)
        gerechnet[anlass] = puffer
        if !spieler.isPlaying { spieler.play() }
        spieler.scheduleBuffer(puffer, at: nil, options: [], completionHandler: nil)
    }

    private func laeuft() -> Bool {
        if maschine.isRunning { return true }
        if !haengtDrin {
            maschine.attach(spieler)
            haengtDrin = true
        }
        // Nach einem Geraetewechsel sind die alten Verbindungen hinfaellig.
        // Ohne dieses erneute Verbinden startet die Maschine zwar, spielt aber
        // ins Leere — und `isPlaying` bleibt dabei auf wahr stehen.
        spieler.stop()
        maschine.connect(spieler, to: maschine.mainMixerNode, format: format)
        do {
            try maschine.start()
        } catch {
            Protokoll.fehler("Klang: \(error.localizedDescription)")
            return false
        }
        spieler.play()
        return true
    }

    private func baue(_ anlass: KlangSynthese.Anlass) -> AVAudioPCMBuffer {
        let werte = KlangSynthese.rechne(anlass)
        let puffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(max(werte.count, 1)))!
        puffer.frameLength = AVAudioFrameCount(werte.count)
        if let kanal = puffer.floatChannelData?[0] {
            for (i, wert) in werte.enumerated() { kanal[i] = wert }
        }
        return puffer
    }
}
