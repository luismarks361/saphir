import SwiftUI

/// Malt die Bausteine eines Plugins in Saphirs eigener Schrift und Farbe.
struct PluginKachelAnsicht: View {
    let plugin: String
    @ObservedObject private var verwalter = PluginVerwalter.shared

    var body: some View {
        if let bausteine = verwalter.kacheln[plugin] {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bausteine.enumerated()), id: \.offset) { _, baustein in
                    // AnyView, weil ein Baustein wieder Bausteine enthalten kann
                    // und der Typ sich sonst selbst enthielte.
                    AnyView(BausteinAnsicht(baustein: baustein, plugin: plugin))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BausteinAnsicht: View {
    let baustein: PluginAntwort.Baustein
    let plugin: String

    var body: some View {
        switch baustein.art {
        case "text": text
        case "symbol": symbol
        case "balken": balken
        case "knopf": knopf
        case "zeile":
            HStack(spacing: 8) { kinder }
        case "spalte":
            VStack(alignment: .leading, spacing: 4) { kinder }
        default:
            EmptyView()
        }
    }

    private var kinder: some View {
        ForEach(Array((baustein.bausteine ?? []).enumerated()), id: \.offset) { _, kind in
            AnyView(BausteinAnsicht(baustein: kind, plugin: plugin))
        }
    }

    private var text: some View {
        let farbe = baustein.farbe
        return Text(baustein.text ?? "")
            .font(schrift)
            .foregroundStyle(PluginFarbe.farbe(farbe, standard: standardFarbe))
            .lineLimit(baustein.stil == "gross" ? 1 : 2)
    }

    private var schrift: Font {
        switch baustein.stil {
        case "gross": return .system(size: 26, weight: .semibold, design: .rounded)
        case "klein": return .system(size: 11, design: .rounded)
        default: return .system(size: 13, weight: .medium)
        }
    }

    private var standardFarbe: Color {
        baustein.stil == "klein" ? .white.opacity(0.55) : .white.opacity(0.9)
    }

    private var symbol: some View {
        Image(systemName: baustein.symbol ?? "questionmark")
            .font(.system(size: 18))
            .foregroundStyle(PluginFarbe.farbe(baustein.farbe))
    }

    private var balken: some View {
        let anteil = min(max(baustein.anteil ?? 0, 0), 1)
        return Capsule()
            .fill(.white.opacity(0.12))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(PluginFarbe.farbe(baustein.farbe))
                        .frame(width: g.size.width * anteil)
                }
            }
            .frame(height: 4)
    }

    private var knopf: some View {
        Button {
            if let aktion = baustein.aktion {
                PluginVerwalter.shared.fuehreAktionAus(plugin, aktion)
            }
        } label: {
            HStack(spacing: 5) {
                if let s = baustein.symbol { Image(systemName: s).font(.system(size: 11, weight: .semibold)) }
                if let t = baustein.text { Text(t).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glas(radius: 10)
        }
        .buttonStyle(.plain)
    }
}
