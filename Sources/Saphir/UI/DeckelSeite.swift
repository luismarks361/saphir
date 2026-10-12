import AppKit
import SwiftUI

/// Die Einstellungsseite zu „Deckel zu". Jede Aenderung geht ueber
/// `manager.config` sofort in die config.json des Motors.
struct DeckelSeite: View {
    private let dienst = DeckelDienst.shared

    var body: some View {
        Ueberschrift("Deckel zu")
        Text("""
        Haelt den Mac auch bei zugeklapptem Deckel wach, etwa damit ein Coding-Agent \
        ueber Nacht weiterarbeitet. Jede Sitzung hat ein Ende. In der Kachel „Wach \
        halten" ist dieser Modus standardmaessig an. Der Laptop-Schalter neben den Zeiten \
        stellt auf das klassische Wach halten ohne Ende zurueck.
        """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        EinrichtungKarte()

        if let manager = dienst.manager {
            DeckelEinstellungen(manager: manager)
        } else {
            Text("Der Motor ist noch nicht gestartet.").foregroundStyle(.secondary)
        }
    }
}

/// Ob die sudoers-Regel steht, und wie sie sich anlegen laesst.
private struct EinrichtungKarte: View {
    private let dienst = DeckelDienst.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(dienst.eingerichtet ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(dienst.eingerichtet ? "Eingerichtet" : "Einmalige Einrichtung fehlt")
                    .font(.body.weight(.medium))
                Spacer()
                Button("Erneut pruefen") { dienst.pruefeEinrichtung() }
            }

            if !dienst.eingerichtet {
                Text("Ein Befehl im Terminal, er fragt einmal nach deinem Passwort:")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(DeckelDienst.einrichtungsBefehl)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DeckelDienst.einrichtungsBefehl, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Kopieren")
                    Button("Terminal oeffnen") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    }
                }
            }

            Text("""
            Die Regel erlaubt genau vier Befehle ohne Passwort: den Ruhezustand und den \
            Energiesparmodus ein- und ausschalten (`pmset`). Sie gilt fuer jedes Programm, \
            das unter deinem Benutzer laeuft, nicht nur fuer Saphir.
            """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }
}

private struct DeckelEinstellungen: View {
    let manager: SessionManager
    private let dienst = DeckelDienst.shared

    @State private var neuerEintrag: [String: String] = [:]
    @State private var neuesZiel = ""
    @State private var hotspotPasswort = ""
    @State private var hotspotGespeichert = false
    @State private var wuerdeEinfrieren: [String] = []
    @State private var geheimnisse: KeychainHotspotSecretStore?

    var body: some View {
        beimZuklappen
        akkuUndHitze
        netz
        stand
            .onAppear {
                let speicher = KeychainHotspotSecretStore(keychain: KeychainStore()) {
                    manager.config.hotspotSSID
                }
                geheimnisse = speicher
                hotspotPasswort = (try? speicher.load()) ?? ""
                hotspotGespeichert = !hotspotPasswort.isEmpty
                aktualisiereEinfrierVorschau()
            }
            .onChange(of: manager.config) { aktualisiereEinfrierVorschau() }
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in aktualisiereEinfrierVorschau() }
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in aktualisiereEinfrierVorschau() }
    }

    // MARK: Bindungen

    private func bind<T: Equatable>(_ pfad: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: pfad] },
            set: { wert in
                guard manager.config[keyPath: pfad] != wert else { return }
                manager.config[keyPath: pfad] = wert
                sichere()
            }
        )
    }

    private func aendere(_ aenderung: (inout Config) -> Void) {
        var c = manager.config
        aenderung(&c)
        guard c != manager.config else { return }
        manager.config = c
        sichere()
    }

    private func sichere() {
        do {
            try manager.store.saveConfig(manager.config)
        } catch {
            Protokoll.fehler("Deckel zu: Einstellungen nicht gespeichert: \(error.localizedDescription)")
        }
    }

    // MARK: Abschnitte

    private var beimZuklappen: some View {
        Abschnitt("Beim Zuklappen") {
            Toggle("Display und Tastaturlicht ausschalten", isOn: bind(\.darkenDisplayOnLidClose))
            Toggle("Ton stumm schalten", isOn: bind(\.muteOnLidClose))
            Toggle("Energiesparmodus einschalten", isOn: bind(\.lowPowerOnLidClose))
                // Ein Eingang der Grenzen: gilt sofort, auch bei schon zugeklapptem Deckel.
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
            Toggle("Docker Desktop pausieren, wenn kein Container laeuft", isOn: bind(\.dockerRule))
            Toggle("Alle anderen Apps einfrieren", isOn: bind(\.freezeAllApps))
            Text(wuerdeEinfrierText)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ListeBundles(
                titel: "Immer einfrieren",
                eintraege: manager.config.freezeList,
                neu: eintragBinding("freeze"),
                hinzu: { id in aendere { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                weg: { id in aendere { $0.freezeList.removeAll { $0 == id } } }
            )
            Divider()
            ListeBundles(
                titel: "Nie einfrieren und nie drosseln",
                eintraege: manager.config.agentList,
                neu: eintragBinding("agent"),
                hinzu: { id in aendere { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                weg: { id in aendere { $0.agentList.removeAll { $0 == id } } }
            )
        } fuss: {
            """
            Eingefroren wird mit SIGSTOP und beim Aufklappen wieder aufgetaut. Apple-Apps, \
            Saphir selbst, Editoren, KI-Apps, Terminals und die Browser der Agenten sind \
            geschuetzt. Helligkeit und Tastaturlicht werden vorher gemerkt und beim \
            Aufklappen zurueckgesetzt. Falls Saphir dann nicht laeuft: Helligkeitstaste \
            nach oben.
            """
        }
    }

    private var akkuUndHitze: some View {
        Abschnitt("Akku und Hitze") {
            Stepper(value: bind(\.lowPowerFloor), in: 0...100, step: 5) {
                LabeledContent("Energiesparmodus unter", value: "\(manager.config.lowPowerFloor) %")
            }
            Stepper(value: bind(\.endFloor), in: 0...100, step: 5) {
                LabeledContent("Sitzung beenden unter", value: "\(manager.config.endFloor) %")
            }
            Toggle("Hitze-Regeln (Energiesparmodus bei Hitze, Ende bei kritischer Hitze)",
                   isOn: bind(\.thermalRules))
        } fuss: {
            "0 bei „Sitzung beenden“ schaltet das Akku-Ende ab. Die Regeln wirken nur, solange Saphir laeuft."
        }
    }

    private var netz: some View {
        Abschnitt("Netz weg") {
            TextField("Name des iPhone-Hotspots", text: bind(\.hotspotSSID))
            HStack {
                SecureField("Passwort des Hotspots", text: $hotspotPasswort)
                    .onSubmit(speicherePasswort)
                Button(hotspotGespeichert ? "Gespeichert" : "Sichern", action: speicherePasswort)
                    .disabled(hotspotPasswort.isEmpty)
            }
            if let ort = manager.services?.locationPermission {
                HStack {
                    Text("Standort: \(ort.statusDescription)").foregroundStyle(.secondary)
                    Spacer()
                    if ort.isDenied {
                        Button("Ortungsdienste oeffnen") { ort.openLocationServicesSettings() }
                    }
                }
            }
            Stepper(value: tmuxSekunden, in: 10...900, step: 10) {
                LabeledContent("tmux anstupsen nach", value: "\(Int(manager.config.nudgeThreshold)) s ohne Netz")
            }
            ForEach(manager.config.tmuxTargets, id: \.self) { ziel in
                HStack {
                    Text(ziel).font(.system(.body, design: .monospaced))
                    Spacer()
                    Entfernen { aendere { $0.tmuxTargets.removeAll { $0 == ziel } } }
                }
            }
            HStack {
                TextField("tmux-Ziel (Sitzung:Fenster.Pane)", text: $neuesZiel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fuegeZielHinzu)
                Button("Hinzu", action: fuegeZielHinzu)
                    .disabled(neuesZiel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } fuss: {
            """
            Faellt das WLAN weg, tritt Saphir dem Hotspot bei. Das Passwort liegt im \
            Schluesselbund. Der Standort ist Voraussetzung, damit macOS WLAN-Namen \
            herausgibt. Nach der eingestellten Zeit ohne Netz tippt Saphir „continue" und \
            Enter in die hier genannten tmux-Panes. Trag nur Panes ein, in denen du nicht \
            selbst tippst.
            """
        }
    }

    private var stand: some View {
        Abschnitt("Stand") {
            LabeledContent("Sitzung") {
                if let bis = dienst.bisWann {
                    Text("laeuft bis \(bis.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("keine").foregroundStyle(.secondary)
                }
            }
            if dienst.wiederherstellungOffen {
                Label("Eine fruehere Sitzung ist nicht vollstaendig zurueckgesetzt. Siehe Protokoll.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let fehler = dienst.fehler {
                Text(fehler).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Protokoll") {
                Text(manager.paths.logFile.path)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } fuss: { "" }
    }

    // MARK: Hilfen

    private var wuerdeEinfrierText: String {
        guard manager.config.freezeAllApps else { return "" }
        return wuerdeEinfrieren.isEmpty
            ? "Wuerde jetzt einfrieren: nichts weiter"
            : "Wuerde jetzt einfrieren: \(wuerdeEinfrieren.joined(separator: ", "))"
    }

    private func aktualisiereEinfrierVorschau() {
        let ich = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wuerdeEinfrieren = FreezePlanner.automaticCandidates(
            config: manager.config, apps: Freezer.runningApps(), selfBundleId: ich).map(\.name)
    }

    private func eintragBinding(_ schluessel: String) -> Binding<String> {
        Binding(get: { neuerEintrag[schluessel] ?? "" }, set: { neuerEintrag[schluessel] = $0 })
    }

    private var tmuxSekunden: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { s in aendere { $0.nudgeThreshold = TimeInterval(s) } }
        )
    }

    private func fuegeZielHinzu() {
        let ziel = neuesZiel.trimmingCharacters(in: .whitespaces)
        guard !ziel.isEmpty else { return }
        aendere { if !$0.tmuxTargets.contains(ziel) { $0.tmuxTargets.append(ziel) } }
        neuesZiel = ""
    }

    private func speicherePasswort() {
        if !manager.config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manager.services?.locationPermission.requestWhenInUse()
        }
        do {
            if hotspotPasswort.isEmpty {
                try geheimnisse?.delete()
            } else {
                try geheimnisse?.save(hotspotPasswort)
            }
            hotspotGespeichert = !hotspotPasswort.isEmpty
        } catch {
            Protokoll.fehler("Deckel zu: Hotspot-Passwort nicht gesichert: \(error.localizedDescription)")
        }
    }
}

// MARK: - Bausteine

/// Ein Abschnitt in Saphirs Kartenoptik, wie auf der Funktionen-Seite.
private struct Abschnitt<Inhalt: View>: View {
    let titel: String
    @ViewBuilder let inhalt: () -> Inhalt
    let fuss: () -> String

    init(_ titel: String, @ViewBuilder inhalt: @escaping () -> Inhalt,
         fuss: @escaping () -> String = { "" }) {
        self.titel = titel
        self.inhalt = inhalt
        self.fuss = fuss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel).font(.headline)
            VStack(alignment: .leading, spacing: 10) { inhalt() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
            let text = fuss()
            if !text.isEmpty {
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Entfernen: View {
    let aktion: () -> Void
    var body: some View {
        Button(action: aktion) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Entfernen")
    }
}

/// Eine Liste von Bundle-IDs mit Eintragen per Hand oder aus den laufenden Apps.
private struct ListeBundles: View {
    let titel: String
    let eintraege: [String]
    @Binding var neu: String
    let hinzu: (String) -> Void
    let weg: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel).font(.body.weight(.medium))
            ForEach(eintraege, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LaufendeApps.name(fuer: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Entfernen { weg(id) }
                }
            }
            HStack {
                TextField("Bundle-ID", text: $neu)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(uebernehmen)
                Button("Hinzu", action: uebernehmen)
                    .disabled(neu.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Laufende App …") {
                    let apps = LaufendeApps.kandidaten(ohne: eintraege)
                    if apps.isEmpty { Text("Keine weitere App offen") }
                    ForEach(apps, id: \.bundleId) { app in
                        Button(app.name) { hinzu(app.bundleId) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func uebernehmen() {
        let wert = neu.trimmingCharacters(in: .whitespaces)
        guard !wert.isEmpty else { return }
        hinzu(wert)
        neu = ""
    }
}

/// Laufende Apps fuer „Laufende App …": alles mit Bundle-ID, was nicht von Apple
/// ist und nicht Saphir selbst.
@MainActor
private enum LaufendeApps {
    struct Eintrag: Hashable {
        let bundleId: String
        let name: String
    }

    static func kandidaten(ohne: [String]) -> [Eintrag] {
        let ich = Bundle.main.bundleIdentifier
        var gesehen = Set<String>()
        var aus: [Eintrag] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != ich,
                  app.activationPolicy != .prohibited,
                  !ohne.contains(id), !gesehen.contains(id) else { continue }
            gesehen.insert(id)
            aus.append(Eintrag(bundleId: id, name: app.localizedName ?? id))
        }
        return aus.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func name(fuer bundleId: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }
}
