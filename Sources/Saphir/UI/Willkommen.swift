import AppKit
import SwiftUI

/// Der erste Start. Drei Seiten, dann ist Ruhe — und wer sie noch einmal sehen
/// will, findet sie im Menueleisten-Menue.
@MainActor
final class WillkommenFenster: NSObject {
    static let shared = WillkommenFenster()
    private var fenster: NSWindow?

    /// Beim allerersten Start von selbst zeigen, danach nie wieder ungefragt.
    func zeigeWennErsterStart() {
        let key = "willkommenGesehen"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        zeigen()
    }

    func zeigen() {
        if let fenster {
            fenster.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Ueber einen NSHostingController statt einer rohen NSHostingView:
        // die View allein bekommt als contentView keine Groesse und das Fenster
        // bleibt leer (geprueft 07.09.2026). Der Controller haengt die View
        // richtig ein und meldet ihre Wunschgroesse ans Fenster.
        // Die Groesse steht als .frame in der View selbst — nicht als
        // preferredContentSize am Controller. Der schiebt sie sonst laufend ans
        // Fenster zurueck und dreht sich auf einem Notch-Display mit der
        // Safe-Area-Pruefung von SwiftUI im Kreis, bis AppKit abbricht
        // ("more Update Constraints in Window passes than there are views",
        // Absturz beim ersten Layout, 07. und 08.09.2026). Ganz ohne Groesse
        // bleibt das Fenster dagegen leer — der .frame ist der Mittelweg.
        let controller = NSHostingController(rootView: WillkommenAnsicht(fertig: { [weak self] in
            self?.fenster?.close()
        }).frame(width: 560, height: 420))

        let neu = NSWindow(contentViewController: controller)
        neu.styleMask = [.titled, .closable]
        neu.title = "Willkommen"
        neu.setContentSize(NSSize(width: 560, height: 420))
        neu.center()
        neu.isReleasedWhenClosed = false
        fenster = neu

        neu.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct WillkommenAnsicht: View {
    let fertig: () -> Void
    @State private var seite = 0

    private let seiten: [(String, String, String)] = [
        ("diamond.fill", "Saphir",
         "Die Notch wird zur Bedienflaeche. Was gerade laeuft, steht links und rechts der Kamera. Faehrst du mit der Maus hin, klappt darunter die Widget-Flaeche auf."),
        ("square.grid.2x2", "Nur was du willst",
         "Jede Funktion laesst sich einzeln abschalten. Was aus ist, laeuft auch nicht im Hintergrund — kein Dienst, kein Zugriff, kein Stromverbrauch."),
        ("lock.shield", "Freigaben",
         "Ein paar Funktionen brauchen die Erlaubnis von macOS: Kalender, Kamera, Ort, Bluetooth, Bedienungshilfen. Du kannst sie jetzt erteilen oder spaeter in den Einstellungen. Ohne Freigabe bleibt die betroffene Funktion einfach aus.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: seiten[seite].0)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 60)

                Text(seiten[seite].1)
                    .font(.title).fontWeight(.semibold)

                Text(seiten[seite].2)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)

            HStack(spacing: 8) {
                ForEach(0..<seiten.count, id: \.self) { i in
                    Circle()
                        .fill(i == seite ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }

                Spacer()

                if seite == seiten.count - 1 {
                    Button("Freigaben oeffnen") {
                        EinstellungenFenster.shared.zeigen()
                        fertig()
                    }
                    Button("Fertig") { fertig() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Weiter") {
                        withAnimation(.easeOut(duration: 0.2)) { seite += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }
}
