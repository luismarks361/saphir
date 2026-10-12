import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Das Datei-Regal: hineinziehen, spaeter wieder herausziehen.
struct RegalWidget: View {
    @ObservedObject private var dienst = RegalDienst.shared
    @State private var zielt = false

    var body: some View {
        Group {
            if dienst.stuecke.isEmpty {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(zielt ? 0.6 : 0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(dienst.stuecke) { stueck in
                            RegalStueckAnsicht(stueck: stueck)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        // Leer braucht das Regal keine volle Hoehe — es soll einladen, nicht
        // die halbe Uebersicht besetzen.
        .frame(height: dienst.stuecke.isEmpty ? 62 : 96)
        .frame(maxWidth: .infinity)
        // Gestrichelter Rand wie im Original: hier ist eine Ablage, kein Bild.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                .foregroundStyle(.white.opacity(zielt ? 0.5 : 0.2))
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(zielt ? 0.07 : 0))
        )
        .animation(InselBewegung.blende, value: zielt)
        .animation(InselBewegung.seitenwechsel, value: dienst.stuecke)
        .onDrop(of: [.fileURL], isTargeted: $zielt) { anbieter in
            nimmAn(anbieter)
            return true
        }
    }

    private func nimmAn(_ anbieter: [NSItemProvider]) {
        for anbieterEinzeln in anbieter {
            anbieterEinzeln.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                                     options: nil) { gegenstand, _ in
                guard let daten = gegenstand as? Data,
                      let url = URL(dataRepresentation: daten, relativeTo: nil) else { return }
                Task { @MainActor in RegalDienst.shared.lege([url]) }
            }
        }
    }
}

private struct RegalStueckAnsicht: View {
    let stueck: RegalStueck
    @State private var ueberfahren = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: stueck.symbolbild)
                    .resizable()
                    .frame(width: 40, height: 40)

                if ueberfahren {
                    Button {
                        RegalDienst.shared.entferne(stueck)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -5)
                    .transition(.scale)
                }
            }
            .frame(width: 44, height: 44)

            Text(stueck.name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 72)
        .padding(.vertical, 6)
        .background(.white.opacity(ueberfahren ? 0.1 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { ueberfahren = $0 }
        .animation(InselBewegung.blende, value: ueberfahren)
        // Herausziehen gibt die Kopie heraus, die im Regal liegt.
        .onDrag { NSItemProvider(object: stueck.ablage as NSURL) }
        .onTapGesture { RegalDienst.shared.oeffne(stueck) }
        .contextMenu {
            Button("Im Finder zeigen") { RegalDienst.shared.zeigeImFinder(stueck) }
            Button("Aus dem Regal nehmen") { RegalDienst.shared.entferne(stueck) }
        }
    }
}
