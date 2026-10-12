import AppKit
import Combine

/// Das Symbol in der Menueleiste. Es spiegelt, was die Insel kann, damit die App
/// auch auf einem Mac ohne Notch bedienbar bleibt.
@MainActor
final class MenueleisteController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let notch: NotchFenster
    private var wachAbo: AnyCancellable?
    private var deckelAbo: AnyCancellable?

    init(notch: NotchFenster) {
        self.notch = notch
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        symbolSetzen(wach: false)

        // Solange der Mac wach gehalten wird, sagt das Symbol es. In der Insel
        // steht es nicht immer: dort zeigt sich nur eine Sache zugleich, und
        // laufende Musik gewinnt.
        wachAbo = WachDienst.shared.$istAn.sink { [weak self] wach in
            MainActor.assumeIsolated { self?.symbolSetzen(wach: wach) }
        }
        // Dasselbe fuer eine Deckel-zu-Sitzung, mit eigenem Symbol.
        deckelAbo = NotificationCenter.default
            .publisher(for: .saphirDeckelGeaendert)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.symbolSetzen(wach: WachDienst.shared.istAn) }
            }

        let menue = NSMenu()
        menue.delegate = self
        item.menu = menue
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(eintrag("Insel oeffnen", #selector(inselOeffnen)))

        let wach = eintrag("Wach halten", #selector(wachUmschalten))
        let deckel = DeckelDienst.shared
        let imDeckelModus = deckel.modusAn || deckel.istAn
        wach.state = (imDeckelModus ? deckel.istAn : WachDienst.shared.istAn) ? .on : .off
        menu.addItem(wach)

        let nacht = eintrag("Anti-Blaulicht", #selector(nachtUmschalten))
        nacht.state = NachtDienst.shared.istAn ? .on : .off
        menu.addItem(nacht)
        menu.addItem(.separator())

        let funktionen = NSMenu()
        for funktion in Funktion.allCases {
            let eintrag = NSMenuItem(title: funktion.name,
                                     action: #selector(funktionUmschalten(_:)),
                                     keyEquivalent: "")
            eintrag.target = self
            eintrag.representedObject = funktion.rawValue
            eintrag.state = Einstellungen.shared.istAn(funktion) ? .on : .off
            funktionen.addItem(eintrag)
        }
        let funktionenEintrag = NSMenuItem(title: "Funktionen", action: nil, keyEquivalent: "")
        funktionenEintrag.submenu = funktionen
        menu.addItem(funktionenEintrag)

        menu.addItem(eintrag("Einstellungen …", #selector(einstellungenOeffnen)))
        menu.addItem(eintrag("Kurzeinfuehrung …", #selector(willkommenOeffnen)))
        menu.addItem(.separator())
        menu.addItem(eintrag("Saphir beenden", #selector(beenden)))
    }

    private func eintrag(_ titel: String, _ aktion: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: titel, action: aktion, keyEquivalent: "")
        item.target = self
        return item
    }

    private func symbolSetzen(wach: Bool) {
        guard let button = item.button else { return }
        let name = DeckelDienst.shared.istAn ? "laptopcomputer"
            : wach ? "cup.and.saucer.fill" : "diamond.fill"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Saphir")
        button.image?.isTemplate = true
    }

    @objc private func wachUmschalten() {
        // Wie die Kachel: im Deckel-Modus (Standard) startet der Eintrag eine
        // Deckel-zu-Sitzung, sonst das klassische Wach halten.
        let deckel = DeckelDienst.shared
        if deckel.modusAn || deckel.istAn {
            if deckel.istAn { deckel.aus() } else { deckel.an(dauer: DeckelDienst.zeiten[1]) }
            return
        }
        if WachDienst.shared.istAn {
            WachDienst.shared.aus()
        } else {
            WachDienst.shared.an(dauer: nil)
        }
    }

    @objc private func nachtUmschalten() {
        NachtDienst.shared.schalte()
    }

    @objc private func inselOeffnen() {
        notch.klappeAufErzwungen()
        notch.zustand.istAngeheftet = true
        notch.flaecheNachfuehren()
    }

    @objc private func funktionUmschalten(_ sender: NSMenuItem) {
        guard let roh = sender.representedObject as? String,
              let funktion = Funktion(rawValue: roh) else { return }
        Einstellungen.shared.setze(funktion, an: !Einstellungen.shared.istAn(funktion))
    }

    @objc private func einstellungenOeffnen() {
        EinstellungenFenster.shared.zeigen()
    }

    @objc private func willkommenOeffnen() {
        WillkommenFenster.shared.zeigen()
    }

    @objc private func beenden() {
        NSApp.terminate(nil)
    }
}
