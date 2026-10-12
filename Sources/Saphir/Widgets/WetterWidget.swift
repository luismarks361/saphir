import SwiftUI

/// Wetter: jetzt gross, danach die naechsten Stunden.
struct WetterWidget: View {
    @ObservedObject private var dienst = WetterDienst.shared

    var body: some View {
        if let w = dienst.jetzt {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: w.symbol)
                            .font(.system(size: 24))
                            .symbolRenderingMode(.multicolor)

                        Text("\(w.grad)°")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                    }

                    // Ort, Lage und Spanne sind Inhalt, keine Beschriftung.
                    Text(w.ort.isEmpty ? w.lage : "\(w.ort) · \(w.lage)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)

                    Text("\(w.tief)° / \(w.hoch)°")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    ForEach(w.stunden) { stunde in
                        VStack(spacing: 4) {
                            Text("\(stunde.stunde)")
                                .font(.system(size: 10, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.4))
                            Image(systemName: stunde.symbol)
                                .font(.system(size: 13))
                                .symbolRenderingMode(.multicolor)
                            Text("\(stunde.grad)°")
                                .font(.system(size: 11, weight: .medium, design: .rounded)
                                    .monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
        } else {
            LeereFlaeche(symbol: "cloud.sun")
        }
    }
}
