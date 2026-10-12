import SwiftUI

/// Der gemeinsame Griff fuer alles, was in der Insel eine Flaeche traegt.
///
/// Apples Insel ist nicht flach: jede Flaeche darauf hat oben einen Hauch mehr
/// Licht als unten und eine haarfeine helle Kante, die oben deutlicher ist als
/// unten. Genau das macht den glaesernen Eindruck — nicht Transparenz, denn
/// dahinter ist ohnehin nur Schwarz.
extension View {
    func glas(radius: CGFloat = 14, kraft: CGFloat = 1) -> some View {
        modifier(Glas(radius: radius, kraft: kraft))
    }
}

struct Glas: ViewModifier {
    var radius: CGFloat = 14
    /// 1 ist der Normalfall. Kleiner heisst zurueckhaltender, groesser
    /// betonter — fuer den Knopf, der gerade an ist.
    var kraft: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.10 * kraft), .white.opacity(0.045 * kraft)],
                        startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.16 * kraft), .white.opacity(0.03 * kraft)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            )
    }
}

/// Dieselbe Lichtfuehrung fuer runde Flaechen.
struct GlasKreis: ViewModifier {
    var kraft: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                Circle().fill(LinearGradient(
                    colors: [.white.opacity(0.12 * kraft), .white.opacity(0.05 * kraft)],
                    startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                Circle().strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.18 * kraft), .white.opacity(0.03 * kraft)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            )
    }
}

extension View {
    func glasKreis(kraft: CGFloat = 1) -> some View {
        modifier(GlasKreis(kraft: kraft))
    }
}
