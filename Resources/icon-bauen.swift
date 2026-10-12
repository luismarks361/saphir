// Baut das App-Symbol. Aufruf: swift Resources/icon-bauen.swift
//
// Gezeichnet statt gemalt, damit es sich jederzeit in jeder Groesse neu
// erzeugen laesst und keine Bilddatei im Repo verwaltet werden muss.
import AppKit

let ordner = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)

/// Ein Saphir: tiefes Blau, oben heller, mit einer Raute darin.
func zeichne(_ kante: CGFloat) -> NSImage {
    let bild = NSImage(size: NSSize(width: kante, height: kante))
    bild.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { bild.unlockFocus(); return bild }

    // Apples Symbole sitzen mit Luft im Quadrat, sonst wirken sie im Dock zu gross.
    let luft = kante * 0.085
    let feld = CGRect(x: luft, y: luft, width: kante - luft * 2, height: kante - luft * 2)
    let form = CGPath(roundedRect: feld,
                      cornerWidth: feld.width * 0.2237, cornerHeight: feld.height * 0.2237,
                      transform: nil)

    ctx.saveGState()
    ctx.addPath(form)
    ctx.clip()
    let verlauf = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [NSColor(srgbRed: 0.24, green: 0.47, blue: 0.93, alpha: 1).cgColor,
                                      NSColor(srgbRed: 0.06, green: 0.16, blue: 0.45, alpha: 1).cgColor] as CFArray,
                             locations: [0, 1])!
    ctx.drawLinearGradient(verlauf,
                           start: CGPoint(x: 0, y: feld.maxY),
                           end: CGPoint(x: 0, y: feld.minY), options: [])

    // Ein Lichtschimmer oben, wie auf geschliffenem Stein.
    let schimmer = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 1, alpha: 0.28).cgColor,
                                       NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(schimmer,
                           start: CGPoint(x: 0, y: feld.maxY),
                           end: CGPoint(x: 0, y: feld.midY), options: [])
    ctx.restoreGState()

    // Die Raute — dasselbe Zeichen wie in der Menueleiste.
    let r = kante * 0.23
    let m = CGPoint(x: feld.midX, y: feld.midY)
    let raute = CGMutablePath()
    raute.move(to: CGPoint(x: m.x, y: m.y + r))
    raute.addLine(to: CGPoint(x: m.x + r * 0.78, y: m.y))
    raute.addLine(to: CGPoint(x: m.x, y: m.y - r))
    raute.addLine(to: CGPoint(x: m.x - r * 0.78, y: m.y))
    raute.closeSubpath()
    ctx.addPath(raute)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.93).cgColor)
    ctx.fillPath()

    bild.unlockFocus()
    return bild
}

for (kante, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                      (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                      (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                      (1024, "icon_512x512@2x")] {
    let bild = zeichne(CGFloat(kante))
    guard let tiff = bild.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: ordner.appendingPathComponent("\(name).png"))
}
print("Iconset unter \(ordner.path)")
