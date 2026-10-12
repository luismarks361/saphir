import AppKit
import SwiftUI

/// Die tragende Farbe eines Bildes — fuer den Schein um die Insel und die
/// Fortschrittsleiste.
enum Bildfarbe {
    /// Mittelt das Bild auf wenige Punkte herunter und nimmt den kraeftigsten.
    ///
    /// Bewusst nicht der Durchschnitt aller Punkte: der ist bei fast jedem
    /// Cover ein schlammiges Braungrau. Gesucht ist die Farbe, die man sieht,
    /// wenn man das Bild aus zehn Metern Entfernung ansieht.
    static func tragende(_ bild: NSImage) -> Color? {
        let kante = 12
        guard let cg = bild.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        var punkte = [UInt8](repeating: 0, count: kante * kante * 4)
        guard let raum = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &punkte, width: kante, height: kante,
                                  bitsPerComponent: 8, bytesPerRow: kante * 4,
                                  space: raum,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: kante, height: kante))

        var beste: (r: Double, g: Double, b: Double, punktzahl: Double)?
        for i in stride(from: 0, to: punkte.count, by: 4) {
            let r = Double(punkte[i]) / 255
            let g = Double(punkte[i + 1]) / 255
            let b = Double(punkte[i + 2]) / 255
            let hell = max(r, g, b)
            let dunkel = min(r, g, b)
            let saettigung = hell > 0 ? (hell - dunkel) / hell : 0
            // Sehr dunkle und ausgewaschene Punkte taugen nicht als Leuchtfarbe.
            guard hell > 0.25, saettigung > 0.2 else { continue }
            let punktzahl = saettigung * hell
            if punktzahl > (beste?.punktzahl ?? 0) {
                beste = (r, g, b, punktzahl)
            }
        }

        guard let beste else { return nil }
        // Auf eine verlaessliche Helligkeit ziehen: ein sehr dunkles Cover soll
        // trotzdem sichtbar leuchten, ein grelles nicht blenden.
        let farbe = NSColor(red: beste.r, green: beste.g, blue: beste.b, alpha: 1)
            .usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        farbe.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Color(hue: h, saturation: min(max(s, 0.5), 0.9), brightness: 0.85)
    }
}
