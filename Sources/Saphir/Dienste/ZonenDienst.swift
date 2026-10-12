import AppKit
import ApplicationServices

/// Ein Platz auf dem Bildschirm, in Anteilen der nutzbaren Flaeche.
/// Ursprung oben links, damit sich die Zonen lesen lassen wie man sie sieht.
struct Zone: Identifiable, Equatable {
    let id: String
    let symbol: String
    let x: CGFloat
    let y: CGFloat
    let breite: CGFloat
    let hoehe: CGFloat

    static let alle: [Zone] = [
        Zone(id: "links", symbol: "rectangle.lefthalf.filled", x: 0, y: 0, breite: 0.5, hoehe: 1),
        Zone(id: "rechts", symbol: "rectangle.righthalf.filled", x: 0.5, y: 0, breite: 0.5, hoehe: 1),
        Zone(id: "oben", symbol: "rectangle.tophalf.filled", x: 0, y: 0, breite: 1, hoehe: 0.5),
        Zone(id: "unten", symbol: "rectangle.bottomhalf.filled", x: 0, y: 0.5, breite: 1, hoehe: 0.5),
        Zone(id: "drittelLinks", symbol: "rectangle.leadingthird.inset.filled",
             x: 0, y: 0, breite: 1.0 / 3, hoehe: 1),
        Zone(id: "drittelRechts", symbol: "rectangle.trailingthird.inset.filled",
             x: 2.0 / 3, y: 0, breite: 1.0 / 3, hoehe: 1),
        Zone(id: "mitte", symbol: "rectangle.center.inset.filled",
             x: 0.15, y: 0.08, breite: 0.7, hoehe: 0.84),
        Zone(id: "ganz", symbol: "rectangle.fill", x: 0, y: 0, breite: 1, hoehe: 1)
    ]
}

/// Fenster andocken.
///
/// Ueber die Bedienungshilfen-Schnittstelle, den einzigen Weg, fremde Fenster
/// zu bewegen. Ohne die Freigabe passiert nichts — die Knoepfe stehen dann
/// blass da, und die Freigaben-Seite sagt warum.
@MainActor
enum ZonenDienst {

    static var darfSchieben: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func docke(_ zone: Zone) -> Bool {
        guard darfSchieben,
              let app = vordersteApp(),
              let fenster = hauptfenster(von: app),
              let bildschirm = bildschirmUnterMaus() else { return false }

        let flaeche = bildschirm.visibleFrame
        let ziel = CGRect(x: flaeche.origin.x + flaeche.width * zone.x,
                          y: flaeche.origin.y + flaeche.height * (1 - zone.y - zone.hoehe),
                          width: flaeche.width * zone.breite,
                          height: flaeche.height * zone.hoehe)

        // Die Bedienungshilfen rechnen von oben, NSScreen von unten. Bezug ist
        // dabei immer der Hauptbildschirm, nicht der eigene.
        let obenKante = (NSScreen.screens.first?.frame.maxY) ?? bildschirm.frame.maxY
        var punkt = CGPoint(x: ziel.minX, y: obenKante - ziel.maxY)
        var groesse = ziel.size

        guard let groessenWert = AXValueCreate(.cgSize, &groesse),
              let ortsWert = AXValueCreate(.cgPoint, &punkt) else { return false }
        // Groesse, Ort, Groesse: manche Fenster begrenzen ihre Groesse, und
        // nach dem Verschieben passt sie dann wieder.
        AXUIElementSetAttributeValue(fenster, kAXSizeAttribute as CFString, groessenWert)
        AXUIElementSetAttributeValue(fenster, kAXPositionAttribute as CFString, ortsWert)
        AXUIElementSetAttributeValue(fenster, kAXSizeAttribute as CFString, groessenWert)
        return true
    }

    private static func vordersteApp() -> NSRunningApplication? {
        let eigene = Bundle.main.bundleIdentifier
        if let vorne = NSWorkspace.shared.frontmostApplication,
           vorne.bundleIdentifier != eigene {
            return vorne
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.isActive && $0.bundleIdentifier != eigene
        }
    }

    private static func hauptfenster(von app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for merkmal in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var wert: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, merkmal as CFString, &wert) == .success,
               let fenster = wert, CFGetTypeID(fenster) == AXUIElementGetTypeID() {
                return (fenster as! AXUIElement)
            }
        }
        var liste: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &liste) == .success,
           let fenster = liste as? [AXUIElement] {
            return fenster.first
        }
        return nil
    }

    private static func bildschirmUnterMaus() -> NSScreen? {
        let maus = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(maus) } ?? NSScreen.main
    }
}
