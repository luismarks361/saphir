import SwiftUI

/// Wo alle Widgets beim Start ihre Kachel anmelden und ihren Dienst wecken.
///
/// Eine Zeile pro Widget — die einzige Stelle, die beim Hinzufuegen eines
/// neuen Widgets angefasst werden muss.
@MainActor
enum Widgets {
    static func anmelden() {
        // Steht vor der Musik: eine wartende Freigabe haelt eine Claude-Session
        // an, und das Kontingent entscheidet, ob heute noch etwas geht.
        WidgetRegister.shared.melde(WidgetKachel(
            id: "agenten", funktion: .agenten, titel: "Sessions",
            symbol: "sparkle", spalten: 2, reihenfolge: 0,
            inhalt: { AnyView(AgentWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "musik", funktion: .musik, titel: "Musik",
            symbol: "music.note", spalten: 2, reihenfolge: 0,
            inhalt: { AnyView(MusikWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "regal", funktion: .dateiRegal, titel: "Regal",
            symbol: "tray.full", spalten: 2, reihenfolge: 1,
            inhalt: { AnyView(RegalWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "wach", funktion: .caffeinate, titel: "Wach halten",
            symbol: "cup.and.saucer", spalten: 1, reihenfolge: 2,
            inhalt: { AnyView(WachWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "batterie", funktion: .batterie, titel: "Batterie",
            symbol: "battery.100", spalten: 2, reihenfolge: 4,
            inhalt: { AnyView(BatterieWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "wetter", funktion: .wetter, titel: "Wetter",
            symbol: "cloud.sun", spalten: 2, reihenfolge: 4,
            inhalt: { AnyView(WetterWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "nacht", funktion: .nachtmodus, titel: "Anti-Blaulicht",
            symbol: "moon.stars", spalten: 1, reihenfolge: 3,
            inhalt: { AnyView(NachtWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "kalender", funktion: .kalender, titel: "Kalender",
            symbol: "calendar", spalten: 2, reihenfolge: 6,
            inhalt: { AnyView(KalenderWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "zwischenablage", funktion: .zwischenablage, titel: "Zwischenablage",
            symbol: "doc.on.clipboard", spalten: 1, reihenfolge: 7,
            inhalt: { AnyView(ZwischenablageWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "notizen", funktion: .notizen, titel: "Notizen",
            symbol: "note.text", spalten: 1, reihenfolge: 8,
            inhalt: { AnyView(NotizWidget()) }
        ))
        WidgetRegister.shared.melde(WidgetKachel(
            id: "audio", funktion: .audioJeApp, titel: "Tonausgabe",
            symbol: "hifispeaker", spalten: 2, reihenfolge: 5,
            inhalt: { AnyView(AudioWidget()) }
        ))
        AgentDienst.shared.taktPruefen()
        MusikDienst.shared.taktPruefen()
        AudioDienst.shared.taktPruefen()
        ZwischenablageDienst.shared.taktPruefen()
        AugenDienst.shared.taktPruefen()
        KalenderDienst.shared.taktPruefen()
        WetterDienst.shared.taktPruefen()
        BatterieDienst.shared.taktPruefen()
    }
}
