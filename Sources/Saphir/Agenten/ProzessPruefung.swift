import Darwin
import Foundation

/// Lebt der Prozess hinter einer Session noch?
///
/// `SessionEnd` kommt nur bei einem sauberen Ende. Stirbt die CLI hart (Absturz,
/// `kill -9`, ein Skript mit Zeitlimit), bleibt ihre Zeile in der Insel sonst fuer
/// immer stehen, meist auf "denkt nach".
enum ProzessPruefung {
    enum Befund: Equatable {
        case lebt
        case tot
        /// Der Kernel hat es nicht verraten (zum Beispiel keine Berechtigung).
        /// Unklar ist nicht tot: die Zeile bleibt.
        case unklar
    }

    /// `seit` ist der Moment, ab dem Saphir die Session kennt. Ein Prozess, der
    /// erst danach gestartet wurde, kann nicht die CLI dieser Session sein: ihre
    /// pid ist neu vergeben worden.
    static func befund(pid: Int, seit: Date) -> Befund {
        guard pid > 0, pid <= Int(Int32.max) else { return .tot }
        var info = proc_bsdinfo()
        let groesse = Int32(MemoryLayout<proc_bsdinfo>.size)
        let gelesen = proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, groesse)
        guard gelesen == groesse else {
            // Nur ESRCH heisst "gibt es nicht".
            return (gelesen == 0 && errno == ESRCH) ? .tot : .unklar
        }
        if info.pbi_status == UInt32(SZOMB) { return .tot }
        let gestartet = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        // Zwei Sekunden Luft: die Startzeit des Prozesses hat Sekundenaufloesung.
        return gestartet <= seit.addingTimeInterval(2) ? .lebt : .tot
    }
}
