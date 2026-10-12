import SwiftUI

/// Wohin der Ton geht, und wie laut. Ein Druck wechselt das Geraet.
struct AudioWidget: View {
    @ObservedObject private var dienst = AudioDienst.shared

    var body: some View {
        if dienst.geraete.isEmpty {
            LeereFlaeche(symbol: "hifispeaker")
        } else {
            VStack(spacing: 8) {
                ForEach(dienst.geraete) { geraet in
                    Button {
                        dienst.waehle(geraet)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: geraet.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 20)
                            Text(geraet.name)
                                .font(.system(size: 12, weight: geraet.istAktiv ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if geraet.istAktiv {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .glas(radius: 9, kraft: geraet.istAktiv ? 1.4 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(geraet.istAktiv ? 0.95 : 0.65))
                }
            }
        }
    }
}
