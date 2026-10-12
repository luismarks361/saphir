import SwiftUI

/// Der Verlauf der Zwischenablage. Ein Druck legt den Eintrag wieder oben auf.
struct ZwischenablageWidget: View {
    @ObservedObject private var dienst = ZwischenablageDienst.shared

    var body: some View {
        if dienst.stuecke.isEmpty {
            LeereFlaeche(symbol: "doc.on.clipboard")
        } else {
            VStack(spacing: 6) {
                ForEach(dienst.stuecke.prefix(3)) { stueck in
                    Zeile(stueck: stueck)
                }
            }
        }
    }

    private struct Zeile: View {
        let stueck: Ablagestueck
        @State private var ueberfahren = false

        var body: some View {
            HStack(spacing: 8) {
                Text(stueck.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if ueberfahren {
                    Button {
                        ZwischenablageDienst.shared.entferne(stueck)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .glas(radius: 9, kraft: ueberfahren ? 1.4 : 0.7)
            .contentShape(Rectangle())
            .onHover { ueberfahren = $0 }
            .onTapGesture { ZwischenablageDienst.shared.setzeEin(stueck) }
        }
    }
}

/// Schnellnotizen: oben schreiben, darunter steht, was schon dasteht.
struct NotizWidget: View {
    @ObservedObject private var dienst = NotizDienst.shared
    @State private var entwurf = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $entwurf)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .glas(radius: 9, kraft: 0.7)
                    .onSubmit(schreibe)

                Button(action: schreibe) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glasKreis()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }

            if dienst.notizen.isEmpty {
                LeereFlaeche(symbol: "note.text")
            } else {
                VStack(spacing: 6) {
                    ForEach(dienst.notizen.prefix(3)) { notiz in
                        HStack(spacing: 8) {
                            Text(notiz.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Button {
                                dienst.entferne(notiz)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .glas(radius: 9, kraft: 0.7)
                    }
                }
            }
        }
    }

    private func schreibe() {
        dienst.schreibe(entwurf)
        entwurf = ""
    }
}
