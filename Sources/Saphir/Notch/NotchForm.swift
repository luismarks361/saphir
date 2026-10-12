import SwiftUI

/// Der schwarze Koerper der Insel.
///
/// Oben kantig am Bildschirmrand, unten gerundet, und dort wo die Form auf die
/// Bildschirmkante trifft eine enge nach innen gezogene Rundung. Diese Rundung
/// ist es, die den Eindruck macht, die Notch selbst sei gewachsen — statt dass
/// ein Rechteck darunter schwebt.
///
/// Uebernommen aus Agent Island.
struct NotchForm: Shape {
    var untenRadius: CGFloat
    /// Radius der nach innen gezogenen Ecke am Bildschirmrand. 6 trifft das
    /// Vorbild; alles Groessere liest sich als weicher Klecks statt als Notch.
    var kehle: CGFloat = 6

    init(untenRadius: CGFloat = 10, kehle: CGFloat = 6) {
        self.untenRadius = untenRadius
        self.kehle = kehle
    }

    /// Beide Radien animieren mit, damit das Wachsen von Pille zu Flaeche auch
    /// die Ecken mitnimmt.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(untenRadius, kehle) }
        set { untenRadius = newValue.first; kehle = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let r = max(0, min(untenRadius, min(h, w / 2)))
        let f = max(0, min(kehle, w / 2))

        // Quadratische Kurven statt `addArc`: in SwiftUIs y-nach-unten-Raum sind
        // die Bogenrichtungen leicht verdreht, und eine falsche laesst statt der
        // Rundung einen ganzen Kreis in der Ecke stehen.

        // Oben links: Kehle hinaus zur Bildschirmkante.
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))

        // Linke Kante in die gerundete Ecke unten links.
        p.addLine(to: CGPoint(x: f, y: h - r))
        p.addQuadCurve(to: CGPoint(x: f + r, y: h), control: CGPoint(x: f, y: h))

        // Untere Kante in die gerundete Ecke unten rechts.
        p.addLine(to: CGPoint(x: w - f - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - f, y: h - r), control: CGPoint(x: w - f, y: h))

        // Rechte Kante hinauf in die Kehle.
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))

        p.closeSubpath()
        return p
    }
}

extension View {
    /// Schatten in zwei Lagen: ein enger, der die Form an den Bildschirm setzt,
    /// und ein weiter weicher fuer Tiefe. Eine einzelne grosse Unschaerfe liest
    /// sich auf dunklem Schreibtisch als grauer Hof.
    func inselSchatten(staerke: CGFloat = 1) -> some View {
        self
            .shadow(color: .black.opacity(0.55 * staerke), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.22 * staerke), radius: 9, y: 6)
    }
}

/// Zeitverlauf wie im Vorbild: ein Auslaufen mit einem Hauch Ueberschwingen.
/// Die Bewegungen des Originals, Wert fuer Wert aus dessen
/// `NotchConfiguration` uebernommen — nicht nachempfunden.
enum InselBewegung {
    /// expandAnimation
    static let groesse: Animation = .spring(response: 0.4, dampingFraction: 0.55, blendDuration: 0)
    /// collapseAnimation
    static let zuklappen: Animation = .spring(response: 0.3, dampingFraction: 0.98, blendDuration: 0)
    /// hoverAnimation
    static let ueberfahren: Animation = .spring(response: 0.25, dampingFraction: 0.55, blendDuration: 0)
    /// widgetSwitchAnimation
    static let seitenwechsel: Animation = .spring(response: 0.4, dampingFraction: 0.95, blendDuration: 0)
    /// contentTransitionAnimation
    static let inhalt: Animation = .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    /// activityOpacityAnimation
    static let blende: Animation = .easeInOut(duration: 0.2)
}

/// Die Maße des Originals (`NotchConfiguration`), auf denselben Bezugs-
/// bildschirm gerechnet: 1728 x 1117 Punkte.
enum InselMasse {
    static let bezug = CGSize(width: 1728, height: 1117)

    static func hoehenfaktor(_ screen: NSScreen?) -> CGFloat {
        let h = (screen ?? NSScreen.main)?.frame.height ?? bezug.height
        return h / bezug.height
    }

    static func breitenfaktor(_ screen: NSScreen?) -> CGFloat {
        let b = (screen ?? NSScreen.main)?.frame.width ?? bezug.width
        return b / bezug.width
    }

    /// `cornerRadiusAdjustment` des Originals: der kleinere der beiden
    /// Bildschirmfaktoren, gedeckelt auf 0,85 bis 1,10.
    ///
    /// Radien werden dort bewusst anders skaliert als Groessen — ein Radius, der
    /// auf einem sehr grossen Bildschirm einfach mitwaechst, laesst die Form
    /// weich und billig aussehen. Saphir hat hier nur die Hoehe genommen und
    /// keinen Deckel gesetzt.
    static func radiusfaktor(_ screen: NSScreen?) -> CGFloat {
        min(max(min(breitenfaktor(screen), hoehenfaktor(screen)), 0.85), 1.10)
    }

    /// initialCornerRadius
    static func radiusEingeklappt(_ screen: NSScreen?) -> CGFloat { 10 * radiusfaktor(screen) }
    /// liveActivityBottomCornerRadius
    static func radiusHud(_ screen: NSScreen?) -> CGFloat { 18 * radiusfaktor(screen) }
    /// clickExpandedCornerRadius
    static let radiusOffen: CGFloat = 40
}
