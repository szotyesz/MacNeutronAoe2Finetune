import Darwin
import Foundation

public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case lockFailed(String)
    case winebootFailed(Int32)
    case emulatorSetupFailed(Int32)
    case dllCopyFailed(String)
    case steamBridgeCopyFailed(String)

    public var description: String {
        switch self {
        case .lockFailed(let reason): "could not lock the prefix: \(reason)"
        case .winebootFailed(let status): "prefix setup failed (wineboot exit \(status)); the next launch retries"
        case .emulatorSetupFailed(let status):
            "prefix setup failed (registering FEX exited \(status)); the next launch retries"
        case .dllCopyFailed(let detail): "could not install graphics DLLs: \(detail)"
        case .steamBridgeCopyFailed(let detail): "could not install the Steam bridge: \(detail)"
        }
    }
}

/// Creates, upgrades and equips a game's Wine prefix at `compatdata/<appid>/pfx`. Its stamp,
/// `compatdata/<appid>/version`, names the `wine.app` that prepared it and the msync mode its wineserver runs in.
public struct PrefixManager: Sendable {
    public let context: CompatContext
    public let layout: ToolLayout
    public let identity: String
    public let runner: any ProcessRunner
    public let log: LauncherLog

    public init(context: CompatContext, layout: ToolLayout, identity: String, runner: any ProcessRunner, log: LauncherLog) {
        self.context = context
        self.layout = layout
        self.identity = identity
        self.runner = runner
        self.log = log
    }

    public static func stamp(identity: String, msync: Bool) -> String { "wine.app \(identity) msync=\(msync ? 1 : 0)" }
    /// Written before wineboot, so a failed or stopped preparation is retried in place, never renamed.
    static let preparingStamp = "wine.app preparing"

    /// Prepares the prefix when it is missing or another `wine.app` prepared it; stops a wineserver left in the other
    /// msync mode; then, when asked, installs the Steam bridge. Holds the prefix lock only for this, never while the
    /// game runs. Nothing under `drive_c` is ever deleted: a Rosetta-era prefix is renamed.
    public func prepare(environment: [String: String], steamBridge: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: context.dataPath, withIntermediateDirectories: true)
        try withFileLock(at: context.lockFile) {
            // Wine reads WINEMSYNC with atoi; launch options may set it to anything.
            let want = Self.stamp(identity: identity, msync: atoi(environment["WINEMSYNC"] ?? "") != 0)
            let recorded = (try? String(contentsOf: context.versionFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let exists = fm.fileExists(atPath: context.prefix.path(percentEncoded: false))
            if exists, recorded == want {
                // Up to date.
            } else if exists, let recorded, recorded.hasPrefix("wine.app \(identity) msync=") {
                // A client and a server in different msync modes can't talk: stop the last launch's server.
                var old = environment
                old["WINEMSYNC"] = recorded.hasSuffix(" msync=1") ? "1" : nil
                _ = try runner.run(layout.wineserver, ["-k"], environment: old, output: nil)
                log.append("note: msync changed, stopped the prefix's wineserver")
                try want.write(to: context.versionFile, atomically: true, encoding: .utf8)
            } else {
                // An arm64 Wine doesn't adopt an x86_64 Wine's prefix.
                if exists, recorded?.hasPrefix("wine.app ") != true { try renameRosettaPrefix() }
                try Self.preparingStamp.write(to: context.versionFile, atomically: true, encoding: .utf8)
                try prepareNew(environment: environment)
                try want.write(to: context.versionFile, atomically: true, encoding: .utf8)
            }
            // The backend's Direct3D DLLs, every launch: a game switched between DXMT and DXVK gets the other's back
            // (install copies only what differs). wined3d's overrides take Wine's own.
            switch GraphicsBackend(rawValue: environment["MACNEUTRON_GRAPHICS"] ?? "") ?? .dxmt {
            case .dxmt: try installDLLs(ToolLayout.dxmtDLLs, from: layout.dxmt)
            case .dxvk: try installDLLs(ToolLayout.dxvkDLLs, from: layout.dxvk)
            case .wined3d: break
            }
            if steamBridge { try deploySteamBridge() }
        }
    }

    private func prepareNew(environment: [String: String]) throws {
        var boot = environment
        // No Mono or Gecko prompt.
        boot["WINEDLLOVERRIDES"] = LaunchEnvironment.mergeOverrides(environment["WINEDLLOVERRIDES"] ?? "",
                                                                    user: "mscoree,mshtml=")
        let status = try runner.run(layout.wine, ["wineboot", "-u"], environment: boot, output: nil)
        guard status == 0 else { throw PrefixError.winebootFailed(status) }
        // x64 code runs on FEX; without this entry, on Wine's stub xtajit64, and every x64 game fails.
        let fex = try runner.run(layout.wine, ["reg", "add", #"HKLM\Software\Microsoft\Wow64\amd64"#, "/ve",
                                               "/d", "libarm64ecfex.dll", "/f"], environment: environment, output: nil)
        guard fex == 0 else { throw PrefixError.emulatorSetupFailed(fex) }
        // A crashing game must exit, not wait behind Wine's crash window while Steam shows it running.
        // ponytail: best effort; if reg fails, crashes still work, they just show the dialog.
        _ = try runner.run(layout.wine, ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog",
                                         "/t", "REG_DWORD", "/d", "0", "/f"], environment: environment, output: nil)
        // Whatever the game's graphics setting: wined3d's overrides ignore them, and a prefix first prepared for
        // wined3d already holds DXMT's. prepare() puts the launch's backend's in place after this.
        try installDLLs(ToolLayout.dxmtDLLs, from: layout.dxmt)
        _ = try runner.run(layout.wineserver, ["-w"], environment: environment, output: nil)
    }

    /// `names` from the runtime's `folder` into the prefix's `system32`.
    private func installDLLs(_ names: [String], from folder: URL) throws {
        for name in names {
            let source = folder.appending(path: name), destination = "drive_c/windows/system32/\(name)"
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw PrefixError.dllCopyFailed("\(destination): missing from the runtime (\(source.path(percentEncoded: false)))")
            }
            do { try install(source, at: destination) } catch {
                throw PrefixError.dllCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }

    /// `pfx` → the first free `pfx.rosetta`, `pfx.rosetta-2`, … (the saves inside stay where the player can find them).
    private func renameRosettaPrefix() throws {
        var name = "pfx.rosetta"
        var number = 1
        while FileManager.default.fileExists(atPath: context.dataPath.appending(path: name).path(percentEncoded: false)) {
            number += 1
            name = "pfx.rosetta-\(number)"
        }
        try FileManager.default.moveItem(at: context.prefix, to: context.dataPath.appending(path: name))
        log.append("note: renamed a Rosetta-era prefix to \(name)")
    }

    /// Every launch: prefixes made before the bridge existed get it too, and a runtime update replaces it.
    func deploySteamBridge() throws {
        for (source, destination) in SteamBridge.prefixFiles(layout: layout) {
            do { try install(source, at: destination) } catch {
                throw PrefixError.steamBridgeCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }

    /// For a game started without the bridge (launch option, or a runtime without it): its steam_api
    /// loads the client DLL an earlier launch left (its registry values persist), and the bridge can
    /// then abort the game. Without these files the game just finds no Steam.
    public func removeSteamBridge() throws {
        try withFileLock(at: context.lockFile) {
            for name in ["steam.exe", "steamclient64.dll", "steamclient.dll"] {
                try? FileManager.default.removeItem(at: context.prefix.appending(path: "\(SteamBridge.prefixFolder)/\(name)"))
            }
        }
    }

    /// Copies `source` into the prefix unless the copy there has its size and modification time (lsteamclient.dll
    /// is 57 MB); the copy gets the source's times. `stat`/`utimensat` keep nanoseconds, which
    /// `FileManager.setAttributes` truncates to microseconds (the copy would then never match).
    private func install(_ source: URL, at destination: String) throws {
        let fm = FileManager.default
        let target = context.prefix.appending(path: destination)
        let from = source.path(percentEncoded: false), to = target.path(percentEncoded: false)
        var src = stat(), dst = stat()
        guard stat(from, &src) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if stat(to, &dst) == 0, dst.st_size == src.st_size, dst.st_mtimespec.tv_sec == src.st_mtimespec.tv_sec,
           dst.st_mtimespec.tv_nsec == src.st_mtimespec.tv_nsec {
            return
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: to) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
        var times = [src.st_atimespec, src.st_mtimespec]
        guard utimensat(AT_FDCWD, to, &times, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Exclusive `flock(2)` on `url` for the duration of `body`. Separate `open`s conflict even
/// within one process, so this also serialises threads.
func withFileLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
    let fd = open(url.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw PrefixError.lockFailed(String(cString: strerror(errno))) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw PrefixError.lockFailed(String(cString: strerror(errno))) }
    defer { flock(fd, LOCK_UN) }
    return try body()
}
