import SwiftUI

/// Anti-Blaulicht: ein Knopf. An heisst Night Shift ganz auf, Bildschirm
/// dunkel, Farbwiedergabe auf Rot.
struct NachtWidget: View {
    @ObservedObject private var dienst = NachtDienst.shared

    var body: some View {
        HStack(spacing: 14) {
            Button {
                dienst.schalte()
            } label: {
                Image(systemName: dienst.istAn ? "moon.stars.fill" : "moon.stars")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(dienst.istAn ? .black : .white.opacity(0.75))
                    .frame(width: 52, height: 52)
                    .background(
                        Circle().fill(dienst.istAn
                                      ? AnyShapeStyle(LinearGradient(
                                          colors: [Color.orange, Color.orange.opacity(0.7)],
                                          startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Color.clear))
                    )
                    .glasKreis(kraft: dienst.istAn ? 0 : 1)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .animation(InselBewegung.blende, value: dienst.istAn)
    }
}
