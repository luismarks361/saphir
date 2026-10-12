import AppKit
import SwiftUI

/// Randloses, nicht aktivierendes Panel ueber der Notch.
///
/// Es muss *ueber* der Menueleistenebene liegen, um die Notch zu ueberdecken,
/// und `constrainFrameRect` muss ausgehebelt werden, sonst schiebt AppKit es
/// wieder nach unten.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Baut das Fenster, verfolgt die Maus, klappt auf und zu.
///
/// Aufbau aus Agent Island uebernommen: das Fenster aendert nie seine Groesse,
/// alles Bewegte wird darin gezeichnet. Genau daran haengt, dass das Auf- und
/// Zuklappen fluessig laeuft — ein NSWindow pro Bild zu vergroessern ruckelt.
@MainActor
final class NotchFenster {
    private(set) var panel: NotchPanel!
    let zustand = InselZustand()

    private var zuklappenArbeit: DispatchWorkItem?
    private var hudArbeit: DispatchWorkItem?
    private var globalerMonitor: Any?
    private var lokalerMonitor: Any?
    /// Behaelt die Menueleiste im Blick (Vollbild an/aus). Laeuft dauerhaft,
    /// aber langsam — ein Blick in die Fensterliste pro Sekunde.
    private var menueleisteTimer: Timer?
    /// Laeuft nur solange offen ist, als Rueckfall fuer die seltenen Faelle, in
    /// denen kein Mausereignis bei uns ankommt (Vollbild-Apps, Ziehen).
    private var verlassenWaechter: Timer?

    init() {
        baueFenster()
        verfolgeMaus()
        beobachteBildschirme()
        beobachteMenueleiste()
        beobachteLiveAktivitaeten()

        NotificationCenter.default.addObserver(
            forName: .saphirHudSchliessen, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hudArbeit?.cancel()
                self.zustand.hud = nil
                self.flaecheNachfuehren()
            }
        }
    }

    deinit {
        if let globalerMonitor { NSEvent.removeMonitor(globalerMonitor) }
        if let lokalerMonitor { NSEvent.removeMonitor(lokalerMonitor) }
    }

    // MARK: - Fenster

    private func baueFenster() {
        let geo = NotchGeometrie.aktuell()
        zustand.geometrie = geo

        let panel = NotchPanel(
            contentRect: geo.fensterRahmen,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        // Startet vollstaendig klickdurchlaessig; der Mausmonitor schaltet das
        // ein, sobald der Zeiger wirklich ueber der Insel steht — sonst waere
        // die Menueleiste neben der Notch nicht mehr bedienbar.
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: InselWurzel(zustand: zustand))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()

        self.panel = panel
    }

    // MARK: - Maus

    private func verfolgeMaus() {
        globalerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.mausBewegt(zieht: event.type == .leftMouseDragged) }
        }
        lokalerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.mausBewegt() }
            return event
        }
    }

    private func mausBewegt(zieht: Bool = false) {
        let drin = heisseFlaeche.contains(NSEvent.mouseLocation)
        // Klicks nur annehmen, solange der Zeiger wirklich ueber uns steht.
        if panel.ignoresMouseEvents == drin {
            panel.ignoresMouseEvents = !drin
        }

        // Wer etwas an die Notch zieht, will es ablegen. Dafuer geht die Insel
        // auf und zeigt das Regal — auch wenn Aufklappen bei Hover aus ist.
        if drin, zieht, Einstellungen.shared.istAn(.dateiRegal) {
            zuklappenArbeit?.cancel()
            zustand.seite = .regal
            klappeAuf()
        }

        guard drin != zustand.istUeberfahren else { return }
        zustand.istUeberfahren = drin
        if drin {
            zuklappenArbeit?.cancel()
            // Ein Angebot (Nachtmodus) wartet auf einen Klick auf Ja oder Nein. Die
            // Zeile mit den Knoepfen steht unter der Notch, der Zeiger muss also
            // hindurch. Klappte die Insel dabei auf, ersetzte die grosse Flaeche
            // die Zeile, noch bevor der Zeiger die Knoepfe erreicht hat.
            let angebotSteht = zustand.hud?.angebot == true
            if Einstellungen.shared.beiHoverOeffnen, !angebotSteht { klappeAuf() }
        } else {
            klappeZuWennRuhig()
        }
    }

    /// Die Flaeche, die gerade als „die Insel" zaehlt, in Bildschirmkoordinaten.
    /// Eingeklappt und ohne Aktivitaet ist das genau die Notch, damit nichts
    /// anderes in der Menueleiste von uns verdeckt wird.
    private var heisseFlaeche: CGRect {
        let geo = zustand.geometrie
        let groesse = zustand.zielGroesse
        return CGRect(x: geo.notchRect.midX - groesse.width / 2,
                      y: geo.notchRect.maxY - groesse.height,
                      width: groesse.width,
                      height: groesse.height)
    }

    // MARK: - Auf und zu

    func klappeAufErzwungen() {
        zuklappenArbeit?.cancel()
        klappeAuf()
    }

    /// Eine anstehende Freigabe draengt sich vor: die Insel geht von selbst auf
    /// und schlaegt die Sessions auf. Angeheftet wird sie dabei nicht — sie soll
    /// von allein wieder zugehen, sobald entschieden ist.
    func zeigeFreigabe() {
        hudArbeit?.cancel()
        zustand.hud = nil
        zustand.seite = .agenten
        klappeAufErzwungen()
        flaecheNachfuehren()
    }

    /// Kurze Anzeige unter der Notch, die sich selbst wieder schliesst.
    func zeigeHud(_ anzeige: HudAnzeige, sekunden: Double = 1.6) {
        hudArbeit?.cancel()
        zustand.hud = anzeige
        flaecheNachfuehren()

        let arbeit = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.zustand.hud = nil
                self.flaecheNachfuehren()
            }
        }
        hudArbeit = arbeit
        DispatchQueue.main.asyncAfter(deadline: .now() + sekunden, execute: arbeit)
    }

    func klappeZuWennRuhig() {
        guard !zustand.istUeberfahren, !zustand.istAngeheftet,
              !AgentDienst.shared.hatFreigabe else { return }
        planeZuklappen()
    }

    func klappeSofortZu() {
        if zustand.istOffen { Klang.spiele(.zu) }
        zuklappenArbeit?.cancel()
        hudArbeit?.cancel()
        zustand.hud = nil
        zustand.istUeberfahren = false
        zustand.istAngeheftet = false
        zustand.istOffen = false
        stoppeWaechter()
        panel.ignoresMouseEvents = true
    }

    private func klappeAuf() {
        guard !zustand.istOffen else { return }
        zustand.istOffen = true
        Klang.spiele(.auf)
        starteWaechter()
    }

    private func planeZuklappen() {
        zuklappenArbeit?.cancel()
        let arbeit = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.zustand.istUeberfahren, !self.zustand.istAngeheftet,
                      !AgentDienst.shared.hatFreigabe else { return }
                self.zustand.istOffen = false
                self.stoppeWaechter()
                self.panel.ignoresMouseEvents = true
            }
        }
        zuklappenArbeit = arbeit
        // Kurze Gnadenfrist, damit der Weg von der Notch zum Panel es nicht
        // sofort wieder zuschlagen laesst.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: arbeit)
    }

    private func starteWaechter() {
        guard verlassenWaechter == nil else { return }
        verlassenWaechter = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mausBewegt() }
        }
    }

    private func stoppeWaechter() {
        verlassenWaechter?.invalidate()
        verlassenWaechter = nil
    }

    /// Aufzurufen, wenn sich der Inhalt geaendert hat, damit die Trefferflaeche
    /// dem folgt.
    func flaecheNachfuehren() {
        mausBewegt()
    }

    // MARK: - Live-Aktivitaeten

    /// Die Breite der eingeklappten Insel steht im Zustand, nicht in der View:
    /// die Trefferflaeche wird in AppKit gebraucht, also muss sie feststehen,
    /// bevor SwiftUI zeichnet.
    private func beobachteLiveAktivitaeten() {
        NotificationCenter.default.addObserver(
            forName: .saphirLiveAktivitaetGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.breitenNachfuehren() }
        }
        breitenNachfuehren()
    }

    private func breitenNachfuehren() {
        // Beide Seiten bekommen dieselbe Breite, sonst wandert die Mitte von
        // der physischen Notch weg (siehe LiveAktivitaet.ohrBreite).
        let breite = LiveAktivitaeten.shared.vorne?.ohrBreite ?? 0
        guard breite != zustand.breiteLinks || breite != zustand.breiteRechts else { return }
        zustand.breiteLinks = breite
        zustand.breiteRechts = breite
        flaecheNachfuehren()
    }

    // MARK: - Bildschirme

    private func beobachteMenueleiste() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruefeMenueleiste() }
        }

        menueleisteTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruefeMenueleiste() }
        }
        pruefeMenueleiste()
    }

    private func pruefeMenueleiste() {
        let sichtbar = MenueleisteSichtbar.isShowing(on: zustand.geometrie.screen)
        guard sichtbar != zustand.menueleisteSichtbar else { return }
        zustand.menueleisteSichtbar = sichtbar
    }

    private func beobachteBildschirme() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.umziehen() }
        }
    }

    func umziehen() {
        let geo = NotchGeometrie.aktuell(bevorzugt: bevorzugterBildschirm())
        zustand.geometrie = geo
        panel.setFrame(geo.fensterRahmen, display: true)
        pruefeMenueleiste()
    }

    private func bevorzugterBildschirm() -> NSScreen? {
        switch Einstellungen.shared.bildschirmWahl {
        case .mitNotch: return nil // NotchGeometrie sucht sich den passenden selbst
        case .haupt: return NSScreen.main
        case .aktiv:
            let maus = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(maus) } ?? NSScreen.main
        }
    }
}
