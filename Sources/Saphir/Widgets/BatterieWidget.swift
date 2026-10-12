import SwiftUI

/// Ladestand: der Mac oben, darunter jedes verbundene Geraet mit seinem
/// eigenen Symbol. AirPods zeigen links, rechts und Etui einzeln.
struct BatterieWidget: View {
    @ObservedObject private var dienst = BatterieDienst.shared

    var body: some View {
        if dienst.mac == nil && dienst.geraete.isEmpty {
            LeereFlaeche(symbol: "battery.100")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let mac = dienst.mac { MacZeile(akku: mac) }
                ForEach(dienst.geraete) { geraet in
                    GeraetZeile(akku: geraet)
                }
            }
        }
    }
}

private struct MacZeile: View {
    let akku: Akku

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: akku.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)

            Text("\(akku.niedrigster)%")
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BatterieDienst.farbe(akku.niedrigster))

            if akku.laedt {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            if let rest = akku.restMinuten {
                Text(String(format: "%d:%02d", rest / 60, rest % 60))
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

private struct GeraetZeile: View {
    let akku: Akku

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: akku.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)

            Text(akku.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: 6)

            HStack(spacing: 10) {
                ForEach(akku.staende) { stand in
                    HStack(spacing: 3) {
                        if let symbol = stand.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Text("\(stand.prozent)%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)
                                .monospacedDigit())
                            .foregroundStyle(BatterieDienst.farbe(stand.prozent))
                    }
                }
            }
        }
    }
}
