import Darwin
import Foundation
import XCTest

/// Behavioural tests for Resources/deckel-backstop.sh (from Insomnia v0.1.0; the install and uninstall script tests were not ported).
///
/// Each test runs a private COPY of the production script against a
/// throwaway SAPHIR_DECKEL_HOME. The copy has its fixed tool-path constants
/// (sudo, pmset, ps, kill, sysctl, pgrep, pkill, osascript, launchctl) and
/// its app-bundle / sudoers paths rewritten to point inside the fixture, so
/// nothing privileged runs, no real process is signaled, and no real home,
/// LaunchAgent, sudoers file, or installed app is read or written. plutil,
/// lockf, and date are the real tools. The fakes record every call.
final class RecoveryScriptTests: XCTestCase {
    private var fx: ScriptFixture!

    override func setUpWithError() throws {
        fx = try ScriptFixture()
    }

    override func tearDown() {
        fx.destroy()
        fx = nil
    }

    // MARK: - backstop.sh

    func testPrivilegedCommandFailureExitsNonzeroAndKeepsJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false,"extra":"keep"}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "sudo -n \(fx.fakePmset) -b lowpowermode 0",
        ])
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true, "a failed pmset must stay journaled")
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertEqual(s["extra"] as? String, "keep")
        XCTAssertTrue(fx.exists(fx.session), "expired session is evidence while the journal is dirty")
        let log = fx.log()
        XCTAssertTrue(log.contains("journal kept dirty"), log)
        XCTAssertFalse(log.contains("journal cleared"), log)
    }

    func testCleanIdleRunsNoCommandsAndTouchesNothing() throws {
        let clean = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"someFutureKey":[1,2]}"#
        try fx.writeState(clean)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [], "an idle run must not touch pmset, sudo, or any process")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), clean, "journal must not be rewritten")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.logFile), "an idle minute must not spam the log")
    }

    func testMissingJournalAndNoSessionDoesNothing() throws {
        let r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.state), "must not seed a journal")
    }

    func testValidFutureSessionIsNoOpWithoutForce() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))
    }

    func testForceEndsValidSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop, ["--force"])

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
    }

    func testExpiredSessionRestoresEverythingAndClearsJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":true,"lowPowerSetByUs":true,"dockerFrozen":true,"keepMe":{"x":1},
         "frozenProcesses":[{"pid":4242,"startedAt":\(started),"startedAtMicros":17,"bootSession":"\(fx.bootUUID)"}]}
        """)
        try fx.psTable([(4242, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "sudo -n \(fx.fakePmset) -b lowpowermode 0",
            "ps -o lstart=,stat=,uid= -p 4242",
            "kill -CONT 4242",
        ])
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(s["dockerFrozen"] as? Bool, false)
        XCTAssertEqual((s["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertEqual((s["keepMe"] as? [String: Any])?["x"] as? Int, 1, "unknown keys survive the rewrite")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    func testFailedSigcontStaysJournaledWithIdentity() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":111,"startedAt":\(started),"startedAtMicros":1,"bootSession":"\(fx.bootUUID)"},
           {"pid":222,"startedAt":\(started),"startedAtMicros":2,"bootSession":"\(fx.bootUUID)","note":"custom"}]}
        """)
        try fx.psTable([(111, fx.lstart(started), "T", fx.uid), (222, fx.lstart(started), "T+", fx.uid)])
        fx.setMode("kill.fail", "222")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.calls().contains("kill -CONT 111"))
        XCTAssertTrue(fx.calls().contains("kill -CONT 222"))
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false, "an unrelated stuck pid must not hold sleep disabled")
        let frozen = try XCTUnwrap(s["frozenProcesses"] as? [[String: Any]])
        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen.first?["pid"] as? Int, 222)
        XCTAssertEqual(frozen.first?["startedAt"] as? Int, started, "identity must survive for the next attempt")
        XCTAssertEqual(frozen.first?["startedAtMicros"] as? Int, 2)
        XCTAssertEqual(frozen.first?["bootSession"] as? String, fx.bootUUID)
        XCTAssertEqual(frozen.first?["note"] as? String, "custom")
        XCTAssertEqual(s["dockerFrozen"] as? Bool, true, "dockerFrozen clears only once no frozen process remains")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("222"), fx.log())
    }

    func testLegacyAndIdentitylessPidsAreNeverSignaledAndStayDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":false,"frozenPids":[333],"frozenProcesses":[{"pid":444}]}"#)
        // Both look stopped right now; that still proves nothing about ownership.
        try fx.psTable([(333, fx.lstart(1_700_000_000), "T", fx.uid), (444, fx.lstart(1_700_000_000), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "no ps lookup, no signal for unverifiable pids")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["frozenPids"] as? [Int], [333])
        XCTAssertEqual((s["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 444)
        XCTAssertTrue(fx.log().contains("333"), fx.log())
        XCTAssertTrue(fx.log().contains("444"), fx.log())
    }

    func testGoneRunningOrMismatchedProcessesClearWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":301,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"},
           {"pid":302,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"},
           {"pid":303,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"},
           {"pid":304,"startedAt":\(started),"startedAtMicros":0,"bootSession":"other-boot"},
           {"pid":305,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
        """)
        try fx.psTable([
            // 301 is gone (not in the table).
            (302, fx.lstart(started), "S+", fx.uid),          // running again
            (303, fx.lstart(started + 1), "T", fx.uid),       // reused pid, different start second
            (304, fx.lstart(started), "T", fx.uid),           // stopped, but journaled in another boot
            (305, fx.lstart(started), "T", "0"),              // stopped, but not our uid
        ])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains("ps -o lstart=,stat=,uid= -p 304"), "another boot needs no lookup")
        let s = try fx.stateJSON()
        XCTAssertEqual((s["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertEqual(s["dockerFrozen"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
    }

    func testSavedAudioIsPreservedAndReportedAsUnresolved() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":0.5,"savedMuted":true}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, "audio needs the app; the run is not complete")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false, "sleep is still restored")
        XCTAssertEqual(s["savedOutputVolume"] as? Double, 0.5)
        XCTAssertEqual(s["savedMuted"] as? Bool, true)
        XCTAssertTrue(fx.log().contains("Open Saphir"), fx.log())
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    /// Display brightness and keyboard backlight saved on lid close are
    /// restored only by the app; the backstop keeps both keys, still undoes
    /// the rest, and says so.
    func testSavedDisplayAndKeyboardArePreservedAndReportedAsUnresolved() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.75,"savedKeyboardBrightness":0.25}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, "display and keyboard need the app; the run is not complete")
        XCTAssertEqual(fx.calls().count, 1, "sleep is still restored; nothing else runs")
        XCTAssertTrue(fx.calls().first?.hasSuffix("pmset -a disablesleep 0") ?? false, fx.calls().description)
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["savedDisplayBrightness"] as? Double, 0.75)
        XCTAssertEqual(s["savedKeyboardBrightness"] as? Double, 0.25)
        XCTAssertTrue(fx.log().contains("Open Saphir"), fx.log())
        XCTAssertTrue(fx.log().contains("display brightness"), fx.log())
        XCTAssertTrue(fx.log().contains("keyboard backlight"), fx.log())
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    /// The write the app owes after its Low Power Mode is not the
    /// backstop's to make or to judge: the key is kept through the run and
    /// does not keep the journal dirty on its own. The app drops it on
    /// relaunch when it finds the mode cleared.
    func testDisplayRestoredUnderLowPowerIsIgnoredAndPreserved() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false,"displayRestoredUnderLowPower":0.75}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(s["displayRestoredUnderLowPower"] as? Double, 0.75)
    }

    /// A journal whose only entry is a saved display brightness is dirty:
    /// the backstop must not report it clean and must keep retrying.
    func testSavedDisplayBrightnessAloneKeepsTheJournalDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedKeyboardBrightness":0.5}"#
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try fx.stateJSON()["savedKeyboardBrightness"] as? Double, 0.5)
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    func testMalformedJournalBlocksWithoutCommandsAndKeepsEvidence() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let broken = #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":"#
        try fx.writeState(broken)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "no privileged command without a readable journal")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), broken, "never seed a clean journal over evidence")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("malformed"), fx.log())
    }

    func testExpiredSessionWithMissingJournalRunsNothingPrivileged() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [], "nothing journaled means nothing to undo")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.state))
    }

    func testMalformedSessionWithCleanJournalIsReportedAndKept() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session), "unreadable evidence is kept")
    }

    func testLockContentionFailsClosed() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let holder = try fx.holdLock()
        defer { holder.terminate(); holder.waitUntilExit() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 75, "lockf EX_TEMPFAIL must propagate: \(r.stderr)")
        XCTAssertEqual(fx.calls(), [], "no unlocked fallback")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("lock"), fx.log())
        XCTAssertTrue(fx.exists(fx.lock), "lock file inode is retained")
    }

    func testSecondRunAfterSuccessIsIdle() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        XCTAssertEqual(try fx.run(fx.backstop).status, 0)
        fx.clearCalls()

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "the lock file must not make later runs think something is journaled")
    }


    // MARK: - Process observation failures

    func testPsCommandFailureKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":777,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
        """)
        fx.setMode("ps", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
        let s = try fx.stateJSON()
        XCTAssertEqual((s["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 777, "unobservable is not gone")
        XCTAssertEqual(s["dockerFrozen"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("could not be observed"), fx.log())
    }

    func testPsUnparseableOutputKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[{"pid":778,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
        """)
        fx.setMode("ps", "garbage")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 778)
        XCTAssertTrue(fx.log().contains("could not be observed"), fx.log())
    }

    func testSysctlFailureKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[{"pid":779,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
        """)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("boot.uuid"))
        try fx.psTable([(779, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "no ps lookup and no signal without a boot session to compare")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 779)
    }

}

// MARK: - Fixture

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// A throwaway tree:
///   root/home              SAPHIR_DECKEL_HOME (session.json, state.json, Logs/, LaunchAgents/)
///   root/bin               recording fakes
///   root/repo/scripts      patched copies of backstop.sh and uninstall.sh
///   root/Applications      fake Insomnia.app bundle
///   root/download          prebuilt bundles for install.sh --app
///   root/etc/sudoers.d     fake sudoers rule
/// The child gets no HOME at all: every $HOME-derived constant is patched in
/// the copy, and a stray $HOME would fail under `set -u` instead of reaching
/// the real home directory.
private final class ScriptFixture {
    let root: URL
    let home: URL
    let bin: URL
    let repoScripts: URL
    let appsDir: URL
    let app: URL
    let sudoers: URL
    let callsLog: URL
    let bootUUID = "0F0F0F0F-1111-2222-3333-444444444444"
    let uid = String(getuid())

    var backstop: URL { repoScripts.appendingPathComponent("backstop.sh") }
    var uninstall: URL { repoScripts.appendingPathComponent("uninstall.sh") }
    var install: URL { repoScripts.appendingPathComponent("install.sh") }
    var installRedirected: URL { repoScripts.appendingPathComponent("install.redirected.sh") }
    var session: URL { home.appendingPathComponent("session.json") }
    var state: URL { home.appendingPathComponent("state.json") }
    var config: URL { home.appendingPathComponent("config.json") }
    var lock: URL { home.appendingPathComponent(".recovery.lock") }
    var installedBackstop: URL { home.appendingPathComponent("backstop.sh") }
    var logFile: URL { home.appendingPathComponent("Logs/deckel.log") }
    var plist: URL { home.appendingPathComponent("LaunchAgents/com.luismarks.saphir.deckel.backstop.plist") }
    var fakePmset: String { bin.appendingPathComponent("pmset").path }

    private let fm = FileManager.default

    init() throws {
        // Below $TMPDIR when the test run sets an absolute one, so a run can
        // keep every fixture file in a folder it owns.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? fm.temporaryDirectory
        root = tmp.appendingPathComponent("saphir-script-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        repoScripts = root.appendingPathComponent("repo/scripts", isDirectory: true)
        appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        app = appsDir.appendingPathComponent("Insomnia.app", isDirectory: true)
        sudoers = root.appendingPathComponent("etc/sudoers.d/insomnia")
        callsLog = root.appendingPathComponent("calls.log")
        for dir in [home, bin, repoScripts, appsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try writeFakes()
        try writeScriptCopies()
        try bootUUID.write(to: root.appendingPathComponent("boot.uuid"), atomically: true, encoding: .utf8)
    }

    func destroy() {
        releaseCommand()
        try? fm.removeItem(at: root)
    }

    /// Lets a fake command in mode "ignore-term" / "closes-fd9" finish.
    func releaseCommand() {
        fm.createFile(atPath: root.appendingPathComponent("release").path, contents: nil)
    }

    /// nil while a release-controlled fake command is still running;
    /// "released" or "watchdog" once it has ended, saying what ended it.
    func commandEnded() -> String? {
        (try? String(contentsOf: root.appendingPathComponent("command.ended"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polls until the recovery lock is free; false after `seconds`.
    func waitUntilLockIsFree(_ seconds: Double = 15) throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if try lockIsFree() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return try lockIsFree()
    }

    /// What install.sh's build and bundle steps need from the "repo":
    /// Resources/Info.plist, Resources/AppIcon.icns and a binary at the fake
    /// swift's bin path.
    func prepareInstall() throws {
        let resources = repoScripts.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.kgarg.insomnia</string></dict></plist>
        """.write(to: resources.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try "icns".write(to: resources.appendingPathComponent("AppIcon.icns"), atomically: true, encoding: .utf8)
        let binroot = root.appendingPathComponent("binroot", isDirectory: true)
        try fm.createDirectory(at: binroot, withIntermediateDirectories: true)
        let binary = binroot.appendingPathComponent("Insomnia")
        try "#!/bin/bash\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// A complete prebuilt bundle, the shape of the one in the 0.1.0 release
    /// zip, at root/download/<name>. Its bytes differ from everything
    /// prepareInstall writes, so a test can tell which one was installed.
    /// `parent` puts it somewhere else, such as inside the installed app.
    @discardableResult
    func preparePrebuilt(_ name: String = "Insomnia.app", in parent: URL? = nil) throws -> URL {
        let bundle = (parent ?? root.appendingPathComponent("download", isDirectory: true)).appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        for dir in ["MacOS", "Resources", "_CodeSignature"] {
            try fm.createDirectory(at: contents.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.kgarg.insomnia</string><key>CFBundleShortVersionString</key><string>0.1.0</string></dict></plist>
        """.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let binary = contents.appendingPathComponent("MacOS/Insomnia")
        try "#!/bin/bash\n# prebuilt binary\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try "prebuilt icns".write(to: contents.appendingPathComponent("Resources/AppIcon.icns"), atomically: true, encoding: .utf8)
        try "prebuilt seal".write(to: contents.appendingPathComponent("_CodeSignature/CodeResources"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// Relative path and bytes of every regular file below `dir`, with its
    /// permission bits.
    func files(under dir: URL) throws -> [String: (data: Data, mode: Int)] {
        var out: [String: (data: Data, mode: Int)] = [:]
        guard let walker = fm.enumerator(atPath: dir.path) else { throw FixtureError("cannot list \(dir.path)") }
        for case let rel as String in walker {
            let path = dir.appendingPathComponent(rel).path
            let attrs = try fm.attributesOfItem(atPath: path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            out[rel] = (try Data(contentsOf: URL(fileURLWithPath: path)), mode)
        }
        return out
    }

    /// Every entry below `dir`, folders and symlinks included, with its type,
    /// mode and bytes (or link target), so a test can tell that nothing was
    /// added, removed or rewritten there.
    func tree(under dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for rel in try fm.subpathsOfDirectory(atPath: dir.path) {
            let path = dir.appendingPathComponent(rel).path
            let attrs = try fm.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            switch attrs[.type] as? FileAttributeType {
            case .typeRegular?:
                out[rel] = "file \(mode) " + (try Data(contentsOf: URL(fileURLWithPath: path))).base64EncodedString()
            case .typeDirectory?:
                out[rel] = "dir \(mode)"
            case .typeSymbolicLink?:
                out[rel] = "link " + (try fm.destinationOfSymbolicLink(atPath: path))
            default:
                out[rel] = "other"
            }
        }
        return out
    }

    /// The path with every symlink resolved, the way `pwd -P` reports it
    /// (temporary directories live below /var, a link to /private/var).
    func physicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func contents(of dir: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: Scripts

    private static var productionScripts: URL {
        // .../Tests/SaphirTests/RecoveryScriptTests.swift -> .../Resources
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private func writeScriptCopies() throws {
        let src = Self.productionScripts
        let backstopText = try String(contentsOf: src.appendingPathComponent("deckel-backstop.sh"), encoding: .utf8)
        try Self.patch(backstopText, [
            "PMSET": fakePmset,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "PS": bin.appendingPathComponent("ps").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "SYSCTL": bin.appendingPathComponent("sysctl").path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "COMMAND_TIMEOUT_SECONDS": "1",
            "KILL_GRACE_SECONDS": "1",
        ]).write(to: backstop, atomically: true, encoding: .utf8)
    }

    /// Rewrites `NAME=...` constant lines. Every name must match exactly one
    /// line, so a renamed constant in the script fails loudly here instead of
    /// letting a test run the real tool.
    static func patch(_ text: String, _ constants: [String: String]) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for (name, value) in constants {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            guard hits.count == 1 else {
                throw FixtureError("expected exactly one '\(name)=' line, found \(hits.count)")
            }
            guard !value.contains("'") else { throw FixtureError("fixture path contains a quote: \(value)") }
            lines[hits[0]] = "\(name)='\(value)'"
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces one exact line; fails loudly if the script no longer has it.
    static func replaceOnce(_ text: String, _ exact: String, with replacement: String) throws -> String {
        guard text.components(separatedBy: exact).count == 2 else {
            throw FixtureError("expected exactly one occurrence of '\(exact)'")
        }
        return text.replacingOccurrences(of: exact, with: replacement)
    }

    // MARK: Fakes

    private func writeFake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeFakes() throws {
        let calls = callsLog.path
        let r = root.path
        // sudo: `-n <cmd>` is the pmset path and succeeds or fails by mode
        // without running anything. `rm`/`test` run unprivileged, and only
        // on a path inside the fixture.
        // Mode "hang" behaves like a pmset that never returns.
        // Mode "auth-fail": every form that would prompt (visudo, install)
        // fails like a wrong password, and `-n` forms fail as unpermitted.
        // Mode "rule-not-effective": authentication passes and the rule is
        // installed, but `sudo -n -l <pmset ...>` still says no.
        // visudo checks the candidate file exists, is non-empty and grants
        // pmset, so an installer that validated the wrong path or an empty
        // heredoc cannot pass here.
        try writeFake("sudo", """
        printf 'sudo %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/sudo.mode" 2>/dev/null || echo ok)"
        # "ignore-term" and "closes-fd9" behave like a pmset that ignores
        # SIGTERM: they live until the test creates the release file (or the
        # fixture is destroyed, or a 60 s wall-clock watchdog), so a test decides when
        # the command ends instead of racing a wall-clock sleep. On exit they
        # write command.ended = released | watchdog, so a test can tell a
        # command that is still alive (no file) from one that ended, and why.
        case "${1:-}" in
          -n) if [[ "${2:-}" == -l ]]; then
                case "$mode" in auth-fail|rule-not-effective) exit 1 ;; *) exit 0 ;; esac
              fi
              case "$mode" in
                ok) exit 0 ;;
                hang) exec /bin/sleep 60 ;;
                ignore-term) trap '' TERM; deadline=$(( $(date +%s) + 60 ))
                  while [[ ! -e "\(r)/release" && -d "\(r)" && $(date +%s) -lt $deadline ]]; do /bin/sleep 0.1; done
                  if [[ -e "\(r)/release" ]]; then echo released > "\(r)/command.ended"
                  elif [[ -d "\(r)" ]]; then echo watchdog > "\(r)/command.ended"; fi
                  exit 0 ;;
                closes-fd9) exec 9<&-; trap '' TERM; deadline=$(( $(date +%s) + 60 ))
                  while [[ ! -e "\(r)/release" && -d "\(r)" && $(date +%s) -lt $deadline ]]; do /bin/sleep 0.1; done
                  if [[ -e "\(r)/release" ]]; then echo released > "\(r)/command.ended"
                  elif [[ -d "\(r)" ]]; then echo watchdog > "\(r)/command.ended"; fi
                  exit 0 ;;
                *) exit 1 ;;
              esac ;;
          visudo)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            f=""; for a in "$@"; do f="$a"; done
            [[ -s "$f" ]] && grep -q 'NOPASSWD: /usr/bin/pmset' "$f" || { printf 'sudo VISUDO-REJECTED %s\\n' "$*" >> "\(calls)"; exit 1; }
            exit 0 ;;
          install)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            src=""; dst=""
            for a in "$@"; do src="$dst"; dst="$a"; done
            case "$dst" in "\(r)"/*) mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; exit 0 ;; esac
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          rm|test)
            for a in "$@"; do
              case "$a" in "\(r)"/*) exec "$@" ;; esac
            done
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          *) exit 1 ;;
        esac
        """)
        try writeFake("pmset", """
        printf 'pmset DIRECT %s\\n' "$*" >> "\(calls)"
        exit 99
        """)
        // swift / codesign: install.sh's build and signing steps, redirected
        // to a fake binary inside the fixture.
        try writeFake("swift", """
        printf 'swift %s\\n' "$*" >> "\(calls)"
        for a in "$@"; do [[ "$a" == --show-bin-path ]] && { echo "\(r)/binroot"; exit 0; }; done
        exit 0
        """)
        // codesign modes: "verify-fails" fails every --verify, like a
        // damaged download; "copy-verify-fails" fails --verify only for a
        // bundle inside the fixture's Applications folder (the installed copy).
        try writeFake("codesign", """
        printf 'codesign %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/codesign.mode" 2>/dev/null || echo ok)"
        if [[ "${1:-}" == --verify ]]; then
          target=""; for a in "$@"; do target="$a"; done
          case "$mode" in
            verify-fails) echo "$target: invalid signature (code or signature have been modified)" >&2; exit 1 ;;
            copy-verify-fails)
              case "$target" in "\(appsDir.path)"/*) echo "$target: invalid signature (code or signature have been modified)" >&2; exit 1 ;; esac ;;
          esac
        fi
        exit 0
        """)
        // ps: answers from ps.table. Modes: "fail" (exit 2 with an error
        // line, like a broken ps) and "garbage" (exit 0 with nonsense).
        try writeFake("ps", """
        printf 'ps %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/ps.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == fail ]]; then echo "ps: cannot read process table" >&2; exit 2; fi
        if [[ "$mode" == garbage ]]; then echo "not a process line"; exit 0; fi
        pid=""; for a in "$@"; do pid="$a"; done
        [[ -f "\(r)/ps.table" ]] || exit 1
        while IFS='|' read -r p lstart stat uid; do
          if [[ "$p" == "$pid" ]]; then printf '%s %s %s\\n' "$lstart" "$stat" "$uid"; exit 0; fi
        done < "\(r)/ps.table"
        exit 1
        """)
        try writeFake("kill", """
        printf 'kill %s\\n' "$*" >> "\(calls)"
        fail="$(cat "\(r)/kill.fail.mode" 2>/dev/null || true)"
        for f in $fail; do [[ "$f" == "${2:-}" ]] && exit 1; done
        exit 0
        """)
        // sysctl: install.sh --app asks hw.optional.arm64 (arm64.mode, default
        // 1; "unknown" fails like an Intel Mac without that name); every
        // other query gets the boot session UUID.
        try writeFake("sysctl", """
        for a in "$@"; do
          if [[ "$a" == hw.optional.arm64 ]]; then
            mode="$(cat "\(r)/arm64.mode" 2>/dev/null || echo 1)"
            if [[ "$mode" == unknown ]]; then echo "sysctl: unknown oid 'hw.optional.arm64'" >&2; exit 1; fi
            echo "$mode"; exit 0
          fi
        done
        cat "\(r)/boot.uuid"
        """)
        // pgrep: pgrep.mode holds one exit status per line, consumed in
        // order; the last line repeats. Default 1 (not running).
        try writeFake("pgrep", """
        printf 'pgrep %s\\n' "$*" >> "\(calls)"
        f="\(r)/pgrep.mode"
        [[ -f "$f" ]] || exit 1
        first="$(head -n 1 "$f")"
        if (( $(wc -l < "$f") > 1 )); then tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"; fi
        exit "${first:-1}"
        """)
        for tool in ["pkill", "osascript"] {
            try writeFake(tool, """
            printf '\(tool) %s\\n' "$*" >> "\(calls)"
            exit 0
            """)
        }
        // launchctl: bootout/bootstrap succeed and `print` reports "not
        // loaded" (113) by default. "loaded": print reports the job loaded.
        // Whatever the mode, a path argument is only accepted when it ends
        // in `.plist` and exists (real launchctl fails with EIO otherwise,
        // for bootstrap and bootout alike); bootout also takes a service
        // target `gui/<uid>/<label>` with no path.
        // "loaded-bootstrap-fails-once": as "loaded", but the first bootstrap
        // fails. "bootout-fails-still-loaded": bootout exits 5 and the job
        // stays listed. "ambiguous": bootout and print fail with errors.
        // Every bootstrap also records whether the recovery lock was held at
        // that moment (LOCK-HELD / LOCK-FREE), to prove the installer keeps
        // its transaction open across the agent replacement.
        // "loaded-then-lost": print says loaded once, then not loaded;
        // bootstrap always fails. "no-then-error": print says not loaded
        // once, then fails with an error; bootstrap fails.
        // "loaded-bootstrap-always-fails": print always says loaded (a job
        // already exists) and every bootstrap fails, reload included.
        try writeFake("launchctl", """
        printf 'launchctl %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/launchctl.mode" 2>/dev/null || echo ok)"
        if [[ "${1:-}" == bootstrap ]]; then
          [[ "${3:-}" == *.plist && -f "${3:-}" ]] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
        elif [[ "${1:-}" == bootout && $# -ge 3 ]]; then
          [[ "${3:-}" == *.plist && -f "${3:-}" ]] || { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
        elif [[ "${1:-}" == bootout ]]; then
          [[ "${2:-}" == gui/\(uid)/com.luismarks.saphir.deckel.backstop ]] || { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
        fi
        if [[ "${1:-}" == bootstrap ]]; then
          if /usr/bin/lockf -k -s -t 0 "\(r)/home/.recovery.lock" /usr/bin/true 2>/dev/null; then
            echo 'launchctl LOCK-FREE during bootstrap' >> "\(calls)"
          else
            echo 'launchctl LOCK-HELD during bootstrap' >> "\(calls)"
          fi
        fi
        prints=0
        if [[ "${1:-}" == print ]]; then
          prints=$(( $(cat "\(r)/print.count" 2>/dev/null || echo 0) + 1 )); echo "$prints" > "\(r)/print.count"
        fi
        case "${1:-}:$mode" in
          bootout:ok|bootout:loaded|bootout:loaded-bootstrap-fails-once|bootout:loaded-then-lost|bootout:no-then-error|bootout:loaded-bootstrap-always-fails) exit 0 ;;
          bootstrap:ok|bootstrap:loaded) exit 0 ;;
          bootstrap:loaded-then-lost|bootstrap:no-then-error) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
          bootstrap:loaded-bootstrap-always-fails) echo "Bootstrap failed: 37: Operation already in progress" >&2; exit 37 ;;
          print:loaded-then-lost) if (( prints == 1 )); then exit 0; fi; exit 113 ;;
          print:no-then-error) if (( prints == 1 )); then exit 113; fi; echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          print:loaded-bootstrap-always-fails) exit 0 ;;
          bootstrap:loaded-bootstrap-fails-once)
            if [[ -e "\(r)/bootstrap.failed" ]]; then exit 0; fi
            : > "\(r)/bootstrap.failed"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
          print:ok) exit 113 ;;
          print:loaded|print:loaded-bootstrap-fails-once) exit 0 ;;
          bootout:ambiguous) echo "Boot-out failed: 1: Operation not permitted" >&2; exit 1 ;;
          print:ambiguous) echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          bootout:*) exit 5 ;;
          print:*) exit 0 ;;
          *) exit 1 ;;
        esac
        """)
    }

    /// True when nobody holds the recovery lock right now.
    func lockIsFree() throws -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    func setMode(_ name: String, _ value: String) {
        try? value.write(to: root.appendingPathComponent("\(name).mode"), atomically: true, encoding: .utf8)
    }

    func psTable(_ rows: [(pid: Int, lstart: String, stat: String, uid: String)]) throws {
        let text = rows.map { "\($0.pid)|\($0.lstart)|\($0.stat)|\($0.uid)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("ps.table"), atomically: true, encoding: .utf8)
    }

    /// What `TZ=UTC LC_ALL=C ps -o lstart=` prints for a start second.
    func lstart(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: State

    func writeState(_ json: String) throws {
        try json.write(to: state, atomically: true, encoding: .utf8)
    }

    func writeSession(endsAt: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let json = #"{"startedAt":"\#(f.string(from: endsAt.addingTimeInterval(-3600)))","endsAt":"\#(f.string(from: endsAt))"}"#
        try json.write(to: session, atomically: true, encoding: .utf8)
    }

    func stateJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: state)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError("state.json is not a JSON object")
        }
        return obj
    }

    /// Everything uninstall.sh would remove on success.
    func installMachinery() throws {
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "binary".write(to: app.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: sudoers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "rule".write(to: sudoers, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plist".write(to: plist, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "log\n".write(to: logFile, atomically: true, encoding: .utf8)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        try fm.copyItem(at: backstop, to: installedBackstop)
    }

    // MARK: Running

    func calls() -> [String] {
        guard let text = try? String(contentsOf: callsLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func clearCalls() {
        try? fm.removeItem(at: callsLog)
    }

    func log() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    /// Environment for the child: no inheritance, so neither the real HOME
    /// nor a TempHome's SAPHIR_DECKEL_HOME can leak in. HOME is deliberately
    /// unset (see the class comment). TMPDIR is the fixture, for tools that
    /// honor it.
    private var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SAPHIR_DECKEL_HOME": home.path,
            "TMPDIR": root.path,
        ]
    }

    /// Inode of a file, to prove the lock file was retained rather than replaced.
    func inode(_ url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// Runs a script copy. `fd9` opens that file on descriptor 9 of the child
    /// first, the way uninstall.sh hands its lock handle to the backstop.
    /// `extraEnvironment` is for install.sh's refusal test only.
    func run(_ script: URL, _ args: [String] = [], fd9: URL? = nil, extraEnvironment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        if let fd9 {
            p.arguments = ["-c", #"exec 9<>"$0" && exec /bin/bash "$@""#, fd9.path, script.path] + args
        } else {
            p.arguments = [script.path] + args
        }
        p.environment = childEnvironment.merging(extraEnvironment) { $1 }
        p.currentDirectoryURL = root
        // Capture to files rather than pipes: nothing to drain, nothing to deadlock.
        let outURL = root.appendingPathComponent("stdout.\(UUID().uuidString)")
        let errURL = root.appendingPathComponent("stderr.\(UUID().uuidString)")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// Holds the recovery lock from another process, the way a running app
    /// or a concurrent backstop would, until terminated.
    func holdLock() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        // The holder waits (not -t 0): a probe below may briefly own the lock
        // at the same instant, and the holder must outlast that, not give up.
        p.arguments = ["-k", "-t", "10", lock.path, "/bin/sleep", "30"]
        let diagURL = root.appendingPathComponent("lock-holder.log")
        fm.createFile(atPath: diagURL.path, contents: nil)
        let diag = try FileHandle(forWritingTo: diagURL)
        defer { try? diag.close() }
        p.standardOutput = diag
        p.standardError = diag
        try p.run()
        // Wait until the holder really owns the lock.
        var probes: [Int32] = []
        for _ in 0..<50 {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
            probe.standardOutput = diag
            probe.standardError = diag
            try probe.run()
            probe.waitUntilExit()
            probes.append(probe.terminationStatus)
            if probe.terminationStatus == 75 { return p }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.terminate()
        let text = (try? String(contentsOf: diagURL, encoding: .utf8)) ?? ""
        throw FixtureError("could not take the recovery lock for the contention test; holder running=\(p.isRunning) probes=\(probes) output=\(text)")
    }
}
