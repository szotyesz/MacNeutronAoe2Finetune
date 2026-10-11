import Foundation
import Testing
@testable import MacNeutronCore

private func makeManager(_ runner: FakeRunner, backend: GraphicsBackend = .dxmt) throws -> (PrefixManager, [String: String]) {
    let layout = try makeToolLayout()
    let context = try CompatContext(environment: steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42")))
    let manager = PrefixManager(context: context, layout: layout, identity: "id1", runner: runner,
                                log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")))
    return (manager, wineEnvironment(manager, backend: backend))
}

/// The environment the launcher builds for this manager's game; `extra` stands for launch options.
private func wineEnvironment(_ manager: PrefixManager, backend: GraphicsBackend = .dxmt,
                             _ extra: [String: String] = [:]) -> [String: String] {
    let base = steamEnvironment(dataPath: manager.context.dataPath).merging(extra) { _, new in new }
    return LaunchEnvironment.build(base: base, context: manager.context, backend: backend, logging: false)
}

private func stamp(_ manager: PrefixManager) -> String? {
    try? String(contentsOf: manager.context.versionFile, encoding: .utf8)
}

private func launcherLog(_ manager: PrefixManager) -> String {
    (try? String(contentsOf: manager.log.launcherLog, encoding: .utf8)) ?? ""
}

private func winebootCount(_ runner: FakeRunner) -> Int { runner.calls.filter { $0.arguments.first == "wineboot" }.count }

/// x64 code runs on FEX; without this entry, on Wine's stub.
private let registerFEX = ["reg", "add", #"HKLM\Software\Microsoft\Wow64\amd64"#, "/ve", "/d", "libarm64ecfex.dll", "/f"]
/// A crashing game must exit, not wait forever behind Wine's crash window (Steam would show it running).
private let disableCrashDialog = ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog",
                                  "/t", "REG_DWORD", "/d", "0", "/f"]

@Test func freshPrefixRunsWinebootAndRecordsVersion() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(environment: env)
    #expect(runner.calls.map { [$0.tool] + $0.arguments } == [
        ["wine", "wineboot", "-u"], ["wine"] + registerFEX, ["wine"] + disableCrashDialog, ["wineserver", "-w"],
    ])
    #expect(runner.calls.allSatisfy { $0.environment["WINEPREFIX"] == manager.context.prefix.path(percentEncoded: false) })
    #expect(runner.calls[0].environment["WINEDLLOVERRIDES"]?.contains("mscoree=;mshtml=") == true)
    #expect(runner.calls[1].environment["WINEDLLOVERRIDES"] == env["WINEDLLOVERRIDES"])
    #expect(stamp(manager) == "wine.app id1 msync=1")
    #expect(PrefixManager.stamp(identity: "id1", msync: false) == "wine.app id1 msync=0")
}

@Test func failedWinebootSkipsTheRegistrySteps() throws {
    let runner = winebootCreatingPrefix(status: 3)
    let (manager, env) = try makeManager(runner)
    #expect(throws: PrefixError.winebootFailed(3)) { try manager.prepare(environment: env) }
    #expect(runner.calls.map(\.arguments) == [["wineboot", "-u"]])
    #expect(stamp(manager) == "wine.app preparing")
}

@Test func upToDatePrefixSkipsWineboot() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(environment: env)
    try manager.prepare(environment: env)
    #expect(winebootCount(runner) == 1)
    #expect(runner.calls.count == 4)
}

@Test func identityChangePreparesInPlace() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    let save = manager.context.prefix.appending(path: "drive_c/users/steamuser/save.dat")
    try write("progress", to: save)
    try write("wine.app id0 msync=1", to: manager.context.versionFile)
    try manager.prepare(environment: env)
    #expect(winebootCount(runner) == 1)
    #expect(try String(contentsOf: save, encoding: .utf8) == "progress")
    #expect(!FileManager.default.fileExists(atPath: manager.context.dataPath.appending(path: "pfx.rosetta").path(percentEncoded: false)))
    #expect(stamp(manager) == "wine.app id1 msync=1")
}

@Test func rosettaEraPrefixIsRenamedNeverDeleted() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try write("progress", to: manager.context.prefix.appending(path: "drive_c/users/steamuser/save.dat"))
    try write("runtime-v4.7.3", to: manager.context.versionFile)
    try manager.prepare(environment: env)
    let renamed = manager.context.dataPath.appending(path: "pfx.rosetta/drive_c/users/steamuser/save.dat")
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "progress")
    #expect(FileManager.default.fileExists(atPath: manager.context.prefix.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(
        atPath: manager.context.prefix.appending(path: "drive_c/users/steamuser/save.dat").path(percentEncoded: false)))
    #expect(launcherLog(manager).contains("note: renamed a Rosetta-era prefix to pfx.rosetta\n"))
    #expect(stamp(manager) == "wine.app id1 msync=1")
}

@Test func renameNumbersPastTakenNamesAndKeepsTheSaves() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    let data = manager.context.dataPath
    try write("first", to: data.appending(path: "pfx.rosetta/save.dat"))
    try write("second", to: data.appending(path: "pfx.rosetta-2/save.dat"))
    try write("third", to: manager.context.prefix.appending(path: "save.dat"))  // no stamp at all: Rosetta-era too
    try manager.prepare(environment: env)
    #expect(try String(contentsOf: data.appending(path: "pfx.rosetta/save.dat"), encoding: .utf8) == "first")
    #expect(try String(contentsOf: data.appending(path: "pfx.rosetta-2/save.dat"), encoding: .utf8) == "second")
    #expect(try String(contentsOf: data.appending(path: "pfx.rosetta-3/save.dat"), encoding: .utf8) == "third")
    #expect(launcherLog(manager).contains("note: renamed a Rosetta-era prefix to pfx.rosetta-3\n"))
}

@Test func preparingStampIsRetriedInPlace() throws {
    // A failed or stopped preparation of an arm64 prefix is retried, never renamed.
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    let save = manager.context.prefix.appending(path: "drive_c/users/steamuser/save.dat")
    try write("progress", to: save)
    try write("wine.app preparing", to: manager.context.versionFile)
    try manager.prepare(environment: env)
    #expect(winebootCount(runner) == 1)
    #expect(try String(contentsOf: save, encoding: .utf8) == "progress")
    #expect(!launcherLog(manager).contains("renamed"))
    #expect(stamp(manager) == "wine.app id1 msync=1")
}

@Test func failedFEXRegistrationFailsThePreparation() throws {
    let runner = FakeRunner { call in
        if call.arguments.first == "wineboot", let prefix = call.environment["WINEPREFIX"] {
            try? FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }
        return call.arguments == registerFEX ? 5 : 0
    }
    let (manager, env) = try makeManager(runner)
    #expect(throws: PrefixError.emulatorSetupFailed(5)) { try manager.prepare(environment: env) }
    #expect(!runner.calls.contains { $0.arguments == disableCrashDialog })
    #expect(stamp(manager) == "wine.app preparing")
}

@Test func msyncOnlyChangeKillsTheServerUnderTheOldMode() throws {
    let runner = winebootCreatingPrefix()
    let (manager, env) = try makeManager(runner)
    try manager.prepare(environment: env)
    let first = runner.calls.count
    try manager.prepare(environment: wineEnvironment(manager, ["MACNEUTRON_NO_MSYNC": "1"]))
    let killed = Array(runner.calls.dropFirst(first))
    #expect(killed.map { [$0.tool] + $0.arguments } == [["wineserver", "-k"]])
    #expect(killed.first?.environment["WINEMSYNC"] == "1")
    #expect(stamp(manager) == "wine.app id1 msync=0")
    #expect(launcherLog(manager).contains("note: msync changed, stopped the prefix's wineserver"))
    // And back: the server from the msync-off launch is stopped without WINEMSYNC.
    try manager.prepare(environment: env)
    #expect(runner.calls.last.map { [$0.tool] + $0.arguments } == ["wineserver", "-k"])
    #expect(runner.calls.last?.environment["WINEMSYNC"] == nil)
    #expect(winebootCount(runner) == 1)
    #expect(stamp(manager) == "wine.app id1 msync=1")
}

@Test func copiesDXMTIntoSystem32Only() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try manager.prepare(environment: env)
    let windows = manager.context.prefix.appending(path: "drive_c/windows", directoryHint: .isDirectory)
    for dll in ["d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"] {
        #expect(try String(contentsOf: windows.appending(path: "system32/\(dll)"), encoding: .utf8) == "dxmt \(dll)")
    }
    #expect(!FileManager.default.fileExists(atPath: windows.appending(path: "syswow64").path(percentEncoded: false)))
}

@Test func switchingBackToDXMTFindsItsDLLs() throws {
    // The stamp doesn't name the backend: a prefix first prepared for wined3d must already hold DXMT's DLLs.
    let runner = winebootCreatingPrefix()
    let (manager, wined3d) = try makeManager(runner, backend: .wined3d)
    try manager.prepare(environment: wined3d)
    try manager.prepare(environment: wineEnvironment(manager, backend: .dxmt))
    #expect(winebootCount(runner) == 1)
    let d3d11 = manager.context.prefix.appending(path: "drive_c/windows/system32/d3d11.dll")
    #expect(try String(contentsOf: d3d11, encoding: .utf8) == "dxmt d3d11.dll")
}

@Test func dxvkLaunchesGetDXVKsDLLsAndDXMTComesBack() throws {
    let runner = winebootCreatingPrefix()
    let (manager, dxvk) = try makeManager(runner, backend: .dxvk)
    let system32 = manager.context.prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
    func dll(_ name: String) throws -> String { try String(contentsOf: system32.appending(path: name), encoding: .utf8) }
    try manager.prepare(environment: dxvk)
    for name in ToolLayout.dxvkDLLs { #expect(try dll(name) == "dxvk \(name)") }
    #expect(try dll("d3d12.dll") == "dxmt d3d12.dll")  // left alone: DXVK's overrides take Wine's own
    try manager.prepare(environment: wineEnvironment(manager, backend: .dxmt))
    for name in ToolLayout.dxmtDLLs { #expect(try dll(name) == "dxmt \(name)") }
    try manager.prepare(environment: dxvk)
    #expect(try dll("d3d11.dll") == "dxvk d3d11.dll")
    #expect(winebootCount(runner) == 1)
}

@Test func missingDXVKDLLIsAnError() throws {
    let (manager, dxvk) = try makeManager(winebootCreatingPrefix(), backend: .dxvk)
    try FileManager.default.removeItem(at: manager.layout.dxvk.appending(path: "dxgi.dll"))
    #expect(throws: PrefixError.self) { try manager.prepare(environment: dxvk) }
}

@Test func missingRuntimeDLLIsAnError() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try FileManager.default.removeItem(at: manager.layout.dxmt.appending(path: "d3d11.dll"))
    #expect(throws: PrefixError.self) { try manager.prepare(environment: env) }
    #expect(stamp(manager) == "wine.app preparing")
}

@Test func concurrentLaunchesRunWinebootOnce() async throws {
    // Steam starts iscriptevaluator (`run`) and the game close together on first launch.
    let runner = winebootCreatingPrefix(delay: 0.3)
    let (manager, env) = try makeManager(runner)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<2 {
            group.addTask { try manager.prepare(environment: env) }
        }
        try await group.waitForAll()
    }
    #expect(winebootCount(runner) == 1)
}

@Test func systemRunnerReportsStatusAndCapturesOutput() throws {
    let log = try makeTempDir().appending(path: "out.log")
    let status = try SystemProcessRunner().run(URL(filePath: "/bin/sh"), ["-c", "echo \"$1\"; exit 3", "sh", "a b"],
                                               environment: [:], output: log)
    #expect(status == 3)
    #expect(try String(contentsOf: log, encoding: .utf8) == "a b\n")
}

private func steamFolder(_ manager: PrefixManager) -> URL {
    manager.context.prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
}

@Test func steamBridgeIsCopiedIntoTheSteamFolder() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(environment: env, steamBridge: true)
    let folder = steamFolder(manager)
    #expect(try String(contentsOf: folder.appending(path: "steam.exe"), encoding: .utf8) == "steam.exe")
    #expect(try String(contentsOf: folder.appending(path: "steamclient64.dll"), encoding: .utf8) == "lsteamclient aarch64")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "steamclient.dll").path(percentEncoded: false)))
}

private func inode(_ url: URL) throws -> UInt64? {
    try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.systemFileNumber] as? UInt64
}

@Test func unchangedBridgeFilesAreNotRecopied() throws {
    // lsteamclient.dll is 57 MB: a launch must not rewrite it when nothing changed.
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(environment: env, steamBridge: true)
    let client = steamFolder(manager).appending(path: "steamclient64.dll")
    let before = try inode(client)
    try manager.prepare(environment: env, steamBridge: true)
    #expect(before != nil)
    #expect(try inode(client) == before)
}

@Test func changedBridgeFileIsRecopied() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(environment: env, steamBridge: true)
    try write("lsteamclient v2", to: manager.layout.lsteamclient)
    try manager.prepare(environment: env, steamBridge: true)
    let client = steamFolder(manager).appending(path: "steamclient64.dll")
    #expect(try String(contentsOf: client, encoding: .utf8) == "lsteamclient v2")
    let modified = { (url: URL) throws -> Date? in
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }
    #expect(try modified(client) == modified(manager.layout.lsteamclient))
}

@Test func upToDatePrefixStillGetsTheSteamBridge() throws {
    // Prefixes prepared before the bridge existed (SMITE 2's on the maintainer's Mac) must get it too.
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try manager.prepare(environment: env)
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(environment: env, steamBridge: true)
    #expect(FileManager.default.fileExists(
        atPath: steamFolder(manager).appending(path: "steamclient64.dll").path(percentEncoded: false)))
}

@Test func prefixWithoutBridgeRequestGetsNoSteamFolder() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(environment: env)
    #expect(!FileManager.default.fileExists(atPath: steamFolder(manager).path(percentEncoded: false)))
}
