import AppKit

// Reiner AppKit-Einstieg statt SwiftUIs `App`: die gesamte Oberflaeche lebt in
// einem randlosen Panel ueber der Notch. Es gibt also keine Szene, und die
// Aktivierungsrichtlinie muss stehen, bevor irgendetwas sichtbar wird.
//
// Code auf oberster Ebene laeuft zwar auf dem Hauptthread, ist aber statisch
// nicht main-actor-isoliert — daher die ausdrueckliche Annahme.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // Muss die Prozesslaufzeit ueberleben; NSApplication haelt nur schwach.
    objc_setAssociatedObject(app, "saphir.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // kein Dock-Symbol, kein App-Menue
    app.run()
}
