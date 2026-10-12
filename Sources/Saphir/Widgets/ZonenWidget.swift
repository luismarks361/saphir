import SwiftUI

/// Fenster andocken: ein Druck, ein Platz. Ohne Beschriftung — die Form des
/// Symbols ist der Platz.
struct ZonenWidget: View {
    private let spalten = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: spalten, spacing: 8) {
            ForEach(Zone.alle) { zone in
                Button {
                    ZonenDienst.docke(zone)
                } label: {
                    Image(systemName: zone.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(height: 34)
                        .frame(maxWidth: .infinity)
                        .glas(radius: 10, kraft: 0.8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(ZonenDienst.darfSchieben ? 0.85 : 0.3))
            }
        }
    }
}
