import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchFenster!
    private var menueleiste: MenueleisteController!
    private var beendetGerade = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Ablage.anlegen()
        Protokoll.info("Saphir startet")

        notch = NotchFenster()
        menueleiste = MenueleisteController(notch: notch)
        Widgets.anmelden()
        // Vor allem anderen: eine liegengebliebene Deckel-zu-Sitzung gehoert
        // sofort abgeraeumt, nicht erst, wenn jemand die Kachel anfasst.
        DeckelDienst.shared.starte()
        hudVerdrahten()
        // Nach der Verdrahtung: eine erste HUD-Meldung braucht schon ihr Ziel.
        PluginVerwalter.shared.starte()

        // Bildschirmwahl und Funktionsschalter koennen die Insel umziehen oder
        // ihren Inhalt aendern; beides muss die Trefferflaeche nachfuehren.
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch.flaecheNachfuehren() }
        }

        steuerkanalOeffnen()
        WillkommenFenster.shared.zeigeWennErsterStart()
    }

    /// Die Sondertasten schreiben in die Zeile unter der Notch.
    ///
    /// Der Dienst kennt das Fenster nicht, das Fenster kennt den Dienst nicht.
    /// Zusammengesteckt wird hier, damit keiner von beiden den anderen
    /// festhaelt.
    private func hudVerdrahten() {
        HudDienst.shared.anzeigen = { [weak self] anzeige in
            self?.notch.zeigeHud(anzeige, sekunden: HudDienst.standzeit)
        }
        HudDienst.shared.starte()

        BrilleDienst.shared.erinnere = { [weak self] anzeige in
            self?.notch.zeigeHud(anzeige, sekunden: BrilleDienst.standzeit)
        }
        BrilleDienst.shared.taktPruefen()

        NachtDienst.shared.biete = { [weak self] anzeige in
            // Ein Angebot will bedient werden, nicht nur gesehen: es steht
            // laenger als eine Meldung.
            self?.notch.zeigeHud(anzeige, sekunden: 20)
        }
        NachtDienst.shared.starte()

        AugenDienst.shared.zeige = { [weak self] anzeige in
            self?.notch.zeigeHud(anzeige, sekunden: 2)
        }

        PluginVerwalter.shared.zeigeHud = { [weak self] anzeige, sekunden in
            self?.notch.zeigeHud(anzeige, sekunden: sekunden)
        }

        // Eine wartende Freigabe haelt eine Claude-Session an. Sie ist damit
        // das Dringlichste, was die Insel zeigt, und darf sich vordraengeln.
        AgentDienst.shared.freigabeKamAn = { [weak self] in
            self?.notch.zeigeFreigabe()
        }
        // Das Frage-Panel besteht nur aus der Karte und geht mit ihr zu; die
        // Quittung am Knopf hat der Dienst vorher schon stehen lassen. Der
        // Abgleich passiert in `flaecheNachfuehren`.
        //
        // Eine offene Insel dagegen noch einen Moment stehen lassen, bevor sie
        // zugeht.
        AgentDienst.shared.freigabeVorbei = { [weak self] in
            self?.notch.flaecheNachfuehren()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { self?.notch.klappeZuWennRuhig() }
            }
        }
        // Etwas Sehenswertes ohne Frage (Aufgabe fertig, Session braucht dich im
        // Terminal): kurz aufklappen und von allein wieder zugehen. Wer die Insel
        // gerade offen hat, wird nicht auf eine andere Seite geschubst.
        AgentDienst.shared.kurzZeigen = { [weak self] sekunden in
            guard let self, !self.notch.zustand.istOffen else { return }
            self.notch.zeigeFreigabe()
            DispatchQueue.main.asyncAfter(deadline: .now() + sekunden) {
                MainActor.assumeIsolated { self.notch.klappeZuWennRuhig() }
            }
        }
        AgentDienst.shared.hinweis = { [weak self] symbol, text, sekunden in
            self?.notch.zeigeHud(HudAnzeige(symbol: symbol, text: text), sekunden: sekunden)
        }
        // `POST /panel` des lokalen Servers: von einem Skript aus auf- oder zuklappen.
        AgentDienst.shared.panel = { [weak self] auf, anheften in
            guard let self else { return }
            if auf {
                self.notch.klappeAufErzwungen()
                if let anheften { self.notch.zustand.istAngeheftet = anheften }
                self.notch.flaecheNachfuehren()
            } else {
                self.notch.klappeSofortZu()
            }
        }
    }

    /// Auf- und Zuklappen von aussen, ueber verteilte Mitteilungen.
    ///
    /// Damit laesst sich die Insel aus einem Skript heraus bedienen — noetig fuer
    /// die Tastenkuerzel (Schritt 21) und praktisch beim Pruefen, weil ein
    /// Hintergrundprozess ohne Bedienungshilfen-Freigabe keine Mausbewegung
    /// erzeugen darf. Verteilte Mitteilungen brauchen keine Berechtigung:
    ///
    ///     osascript -e 'do shell script "..."'   # nicht noetig
    ///     /usr/bin/python3 -c "..."              # siehe doku/steuern.md
    private func steuerkanalOeffnen() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.luismarks.saphir.oeffnen"),
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notch.klappeAufErzwungen()
                self.notch.zustand.istAngeheftet = true
                self.notch.flaecheNachfuehren()
            }
        }
        center.addObserver(forName: .init("com.luismarks.saphir.schliessen"),
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch.klappeSofortZu() }
        }
        // Eine bestimmte Seite aufschlagen. Braucht spaeter jedes Tastenkuerzel
        // (Schritt 21), das direkt ins Regal oder zur Musik springt.
        center.addObserver(forName: .init("com.luismarks.saphir.seite"),
                           object: nil, queue: .main) { [weak self] hinweis in
            MainActor.assumeIsolated {
                guard let self,
                      let name = hinweis.object as? String,
                      let seite = WidgetSeite(rawValue: name) else { return }
                self.notch.zustand.seite = seite
                self.notch.klappeAufErzwungen()
                self.notch.zustand.istAngeheftet = true
                self.notch.flaecheNachfuehren()
            }
        }
        // Wach halten von aussen. Object ist die Dauer in Minuten, "0" heisst
        // ohne Ende, "aus" schaltet ab.
        center.addObserver(forName: .init("com.luismarks.saphir.wach"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                let wunsch = hinweis.object as? String ?? "0"
                if wunsch == "aus" {
                    WachDienst.shared.aus()
                } else {
                    let minuten = Double(wunsch) ?? 0
                    WachDienst.shared.an(dauer: minuten > 0 ? minuten * 60 : nil)
                }
            }
        }
        // Deckel zu von aussen. Object ist die Dauer in Minuten oder "aus".
        // Gleicher Weg wie die Kachel; anders liesse sich der Motor nicht
        // pruefen, denn ein Hintergrundprozess darf keinen Mausklick erzeugen.
        center.addObserver(forName: .init("com.luismarks.saphir.deckel"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                let wunsch = hinweis.object as? String ?? "60"
                if wunsch == "aus" {
                    DeckelDienst.shared.aus()
                } else if let minuten = Double(wunsch), minuten > 0 {
                    DeckelDienst.shared.an(dauer: minuten * 60)
                }
            }
        }
        // Die Brillen-Erinnerung sofort zeigen, ohne auf die Viertelstunde zu
        // warten.
        center.addObserver(forName: .init("com.luismarks.saphir.brille"),
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BrilleDienst.shared.zeige() }
        }
        // Nachtmodus von aussen: an, aus, oder das Angebot zeigen.
        center.addObserver(forName: .init("com.luismarks.saphir.nacht"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                switch hinweis.object as? String ?? "an" {
                case "aus": NachtDienst.shared.aus()
                case "angebot":
                    NachtDienst.shared.biete?(HudAnzeige(symbol: "moon.stars.fill", text: "",
                                                         farbe: .orange, angebot: true))
                default: NachtDienst.shared.an()
                }
            }
        }
        // Augenpause sofort starten.
        center.addObserver(forName: .init("com.luismarks.saphir.auge"),
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AugenDienst.shared.beginnePause() }
        }
        // Eine Funktion von aussen schalten: "name" oder "name aus".
        center.addObserver(forName: .init("com.luismarks.saphir.funktion"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                let teile = (hinweis.object as? String ?? "").split(separator: " ")
                guard let roh = teile.first,
                      let funktion = Funktion(rawValue: String(roh)) else { return }
                let an = teile.count < 2 || teile[1] != "aus"
                Einstellungen.shared.setze(funktion, an: an)
            }
        }
        // Eine anstehende Freigabe von aussen entscheiden: "erlauben", "ablehnen"
        // oder "immer". Ruft genau die Funktion, die auch der Knopf in der Insel
        // ruft — ohne das liesse sich der Weg gar nicht pruefen, denn ein
        // Hintergrundprozess darf keinen Mausklick erzeugen.
        center.addObserver(forName: .init("com.luismarks.saphir.freigabe"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                guard let session = AgentDienst.shared.offeneFreigabe else { return }
                let wahl: String
                switch hinweis.object as? String ?? "erlauben" {
                case "ablehnen": wahl = "deny"
                case "immer": wahl = "always"
                default: wahl = "allow"
                }
                AgentDienst.shared.entscheide(session, wahl)
            }
        }
        // Mit Claude Code verbinden oder trennen: "verbinden", "trennen" oder
        // "status". Dieselben Funktionen wie die Knoepfe in den Einstellungen.
        center.addObserver(forName: .init("com.luismarks.saphir.agenten"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                switch hinweis.object as? String ?? "status" {
                case "verbinden": AgentDienst.shared.verbinde()
                case "trennen": AgentDienst.shared.trenne()
                default: break
                }
                let d = AgentDienst.shared
                Protokoll.info("Agenten: laeuft=\(d.laeuft) port=\(d.port) hooks=\(d.hooksEingetragen) sessions=\(d.sessions.count)")
            }
        }
        // Das Plus am Musik-Widget von aussen druecken. Gleicher Weg wie der
        // Knopf; anders laesst sich der Spotify-Pfad nicht pruefen, denn ein
        // Hintergrundprozess darf keinen Mausklick erzeugen.
        center.addObserver(forName: .init("com.luismarks.saphir.bibliothek"),
                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let jetzt = MusikDienst.shared.jetzt else { return }
                SpotifyKonto.shared.umschalten(uri: jetzt.stueckId)
            }
        }
        center.addObserver(forName: .init("com.luismarks.saphir.einstellungen"),
                           object: nil, queue: .main) { hinweis in
            MainActor.assumeIsolated {
                let bereich = hinweis.object as? String
                EinstellungenFenster.shared.zeigen(bereich: bereich?.isEmpty == false ? bereich : nil)
            }
        }
    }

    /// Beenden raeumt zuerst eine laufende Deckel-zu-Sitzung ab. Das Beenden
    /// wird aufgeschoben, bis der Mac wieder im Normalzustand ist; ein zweites
    /// Beenden dazwischen wird abgelehnt, weil es mitten im Aufraeumen stoeren
    /// wuerde. Gelingt das Aufraeumen nicht, bleibt Saphir, damit der Motor es
    /// zu Ende bringt: wer jetzt ginge, liesse den Mac wach zurueck.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !beendetGerade else { return .terminateCancel }
        let dienst = DeckelDienst.shared
        guard dienst.istAn || dienst.wiederherstellungOffen else { return .terminateNow }
        beendetGerade = true
        Task { @MainActor in
            let darfGehen = await dienst.beendeFuerAbschied()
            if !darfGehen { self.beendetGerade = false }
            sender.reply(toApplicationShouldTerminate: darfGehen)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Die verbogene Farbwiedergabe haengt am Bildschirm, nicht an der App.
        // Bliebe sie stehen, saehe der ganze Mac rot aus.
        NachtDienst.shared.aufraeumen()
        // Der Server geht, damit Claude wie gewohnt im Terminal fragt.
        AgentDienst.shared.beende()
        Protokoll.info("Saphir endet")
    }
}
