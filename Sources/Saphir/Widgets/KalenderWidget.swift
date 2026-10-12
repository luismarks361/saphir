import SwiftUI

/// Die naechsten Termine: Uhrzeit, Farbe des Kalenders, Titel.
struct KalenderWidget: View {
    @ObservedObject private var dienst = KalenderDienst.shared

    var body: some View {
        if dienst.termine.isEmpty {
            LeereFlaeche(symbol: "calendar")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(dienst.termine.prefix(4)) { termin in
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(termin.farbe)
                            .frame(width: 3, height: 22)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(termin.titel)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(termin.laeuft ? .white : .white.opacity(0.85))
                                .lineLimit(1)

                            // Bei ganztaegigen Terminen steht das Datum statt
                            // einer Uhrzeit — ein Wort wie „ganztaegig" waere
                            // Beschriftung, das Datum ist Inhalt.
                            Text(KalenderDienst.wann(termin))
                                .font(.system(size: 10, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.45))
                        }

                        Spacer(minLength: 0)

                        if termin.laeuft {
                            Circle().fill(termin.farbe).frame(width: 6, height: 6)
                        }
                    }
                }
            }
        }
    }
}
