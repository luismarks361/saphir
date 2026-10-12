import SwiftUI

/// Wach halten: ein Knopf, drei Zeiten. Mehr braucht es nicht.
///
/// Der Laptop-Schalter rechts neben den Zeiten stellt um auf „Deckel zu": dann
/// bleibt der Mac auch bei zugeklapptem Deckel wach (`DeckelDienst`), mit
/// anderen Zeiten und immer mit Ende. Ohne den Schalter ist alles wie zuvor.
struct WachWidget: View {
    @ObservedObject private var dienst = WachDienst.shared
    private let deckel = DeckelDienst.shared

    /// Deckel-Modus: eingestellt, oder weil gerade eine Sitzung laeuft.
    private var modus: Bool { deckel.modusAn || deckel.istAn }
    private var laeuft: Bool { modus ? deckel.istAn : dienst.istAn }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if modus {
                    if deckel.istAn { deckel.aus() } else { deckel.an(dauer: DeckelDienst.zeiten[1]) }
                } else if dienst.istAn {
                    dienst.aus()
                } else {
                    dienst.an(dauer: nil)
                }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(laeuft ? .black : .white.opacity(0.75))
                    .frame(width: 52, height: 52)
                    .background(
                        Circle().fill(laeuft
                                      ? AnyShapeStyle(LinearGradient(
                                          colors: [Color.orange, Color.orange.opacity(0.72)],
                                          startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Color.clear))
                    )
                    .glasKreis(kraft: laeuft ? 0 : 1)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                // Die verbleibende Zeit ist Inhalt, keine Beschriftung — sie
                // darf stehen bleiben.
                if modus && !deckel.eingerichtet && !deckel.istAn {
                    Text("Einrichten")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                        .frame(height: 24, alignment: .leading)
                } else {
                    Text(zeit)
                        .font(.system(size: 20, weight: .semibold, design: .rounded)
                            .monospacedDigit())
                        .foregroundStyle(laeuft ? .white : .white.opacity(0.3))
                }

                HStack(spacing: 6) {
                    if modus {
                        ForEach(DeckelDienst.zeiten, id: \.self) { zeit in
                            chip("\(Int(zeit / 3600))h") { deckel.an(dauer: zeit) }
                        }
                    } else {
                        ForEach(Array(WachDienst.zeiten.enumerated()), id: \.offset) { _, zeit in
                            chip(beschriftung(zeit)) { dienst.an(dauer: zeit) }
                        }
                    }
                    modusSchalter
                }
            }
            Spacer(minLength: 0)
        }
        .animation(InselBewegung.blende, value: laeuft)
        .animation(InselBewegung.blende, value: modus)
    }

    private var symbol: String {
        if modus { return "laptopcomputer" }
        return dienst.istAn ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    private var zeit: String {
        if modus { return deckel.istAn ? (deckel.restText ?? "–") : "–" }
        return dienst.istAn ? (dienst.restText ?? "∞") : "–"
    }

    private func chip(_ text: String, aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 36, height: 22)
                .glas(radius: 11, kraft: 0.9)
                .foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    /// Stellt zwischen „Wach halten" und „Deckel zu" um. Solange eine Sitzung
    /// laeuft, steht er fest: mitten drin den Modus zu wechseln liesse eine
    /// Sitzung ohne Knopf zurueck.
    private var modusSchalter: some View {
        Button {
            guard !deckel.istAn else { return }
            if !deckel.modusAn, dienst.istAn { dienst.aus() }
            deckel.modusAn.toggle()
        } label: {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 36, height: 22)
                .foregroundStyle(modus ? .black : .white.opacity(0.8))
                .background(
                    Capsule().fill(modus
                                   ? AnyShapeStyle(LinearGradient(
                                       colors: [Color.orange, Color.orange.opacity(0.72)],
                                       startPoint: .top, endPoint: .bottom))
                                   : AnyShapeStyle(Color.clear))
                )
                .glas(radius: 11, kraft: modus ? 0 : 0.9)
        }
        .buttonStyle(.plain)
        .help("Auch bei zugeklapptem Deckel wach bleiben")
    }

    private func beschriftung(_ zeit: TimeInterval?) -> String {
        guard let zeit else { return "∞" }
        return "\(Int(zeit / 60))m"
    }
}
