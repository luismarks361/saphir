import Foundation
import XCTest
@testable import Saphir

/// Legt vor dem ersten Zugriff auf `Ablage` einen Testordner fest, damit kein
/// Test an `~/.saphir` oder an die echte `~/.claude/settings.json` kommt.
///
/// `Ablage.ordner` wird beim ersten Lesen festgeschrieben. Deshalb steht das
/// hier in einem `static let`, den jede Agenten-Testklasse in `setUp` anfasst.
enum AgentenTestUmgebung {
    static let ordner: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saphir-agenten-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("SAPHIR_HOME", url.path, 1)
        return url
    }()

    /// Ein frischer Ordner fuer die gefakte `settings.json` je Test.
    static func neueSettings(inhalt: String? = nil) throws -> URL {
        _ = ordner
        let verzeichnis = FileManager.default.temporaryDirectory
            .appendingPathComponent("saphir-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: verzeichnis, withIntermediateDirectories: true)
        let datei = verzeichnis.appendingPathComponent("settings.json")
        if let inhalt { try inhalt.write(to: datei, atomically: true, encoding: .utf8) }
        setenv("SAPHIR_CLAUDE_SETTINGS", datei.path, 1)
        return datei
    }

    /// Stellt sicher, dass wirklich der Testordner gilt. Schlaegt laut fehl, statt
    /// still in das echte Verzeichnis zu schreiben.
    static func pruefe(file: StaticString = #filePath, line: UInt = #line) {
        _ = ordner
        XCTAssertEqual(Ablage.ordner.path, ordner.path,
                       "Ablage zeigt nicht auf den Testordner, Abbruch vor echten Daten",
                       file: file, line: line)
    }
}
