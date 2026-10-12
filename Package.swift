// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Saphir",
    // 14.4 wegen des Prozess-Taps (Pegel der Musikbalken). Aeltere Systeme
    // koennen den Systemton nicht ohne Umweg ueber ein virtuelles Geraet lesen.
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Saphir",
            path: "Sources/Saphir",
            swiftSettings: [
                // Quer durch die App laufen AppKit- und CoreAudio-Rueckrufe.
                // v5-Modus mit ausdruecklichen @MainActor-Markierungen ist hier
                // der ehrlichere Weg als Strict Concurrency ueberall zu umgehen.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Die Tests des Deckel-zu-Motors aus Insomnia (ohne dessen Oberflaeche).
        .testTarget(
            name: "SaphirTests",
            dependencies: ["Saphir"],
            path: "Tests/SaphirTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
