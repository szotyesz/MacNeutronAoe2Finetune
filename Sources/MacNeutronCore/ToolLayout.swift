import Foundation

/// Where everything lives inside the `macneutron` compatibility tool folder.
public struct ToolLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<root>/bin/macneutron` → `<root>`.
    public init(executable: URL) {
        root = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Application Support/MacNeutron/compatibilitytools.d/macneutron",
            directoryHint: .isDirectory)
    }

    /// The runtime: an arm64 Wine with DXMT, FEX and lsteamclient inside, installed from MacNeutron.app.
    public var wineApp: URL { root.appending(path: "wine.app", directoryHint: .isDirectory) }
    private var resources: URL { wineApp.appending(path: "Contents/Resources", directoryHint: .isDirectory) }
    public var wine: URL { wineApp.appending(path: "Contents/MacOS/wine") }
    public var wineserver: URL { resources.appending(path: "bin/wineserver") }
    public var dxmt: URL { resources.appending(path: "DXMT/aarch64-windows", directoryHint: .isDirectory) }
    /// The DLLs every prefix gets in `system32`.
    public static let dxmtDLLs = ["d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"]
    public var dxmtVersionFile: URL { resources.appending(path: "DXMT/version") }
    public var dxmtVersion: String? {
        (try? String(contentsOf: dxmtVersionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// DXMT's pipeline replayer (shader pre-caching), run by the launcher under Wine.
    public var dxmtReplay: URL { dxmt.appending(path: "dxmt-replay.exe") }
    /// DXVK's front ends, which a prefix whose game renders with DXVK gets in `system32` instead of DXMT's.
    public var dxvk: URL { resources.appending(path: "DXVK/aarch64-windows", directoryHint: .isDirectory) }
    public static let dxvkDLLs = ["d3d10core.dll", "d3d11.dll", "dxgi.dll"]
    public var dxvkVersionFile: URL { resources.appending(path: "DXVK/version") }
    /// KosmicKrisp's Vulkan driver manifest, which a DXVK launch names in `VK_DRIVER_FILES`.
    public var vulkanDriverManifest: URL { resources.appending(path: "vulkan/icd.d/kosmickrisp_icd.json") }
    /// The Steam client bridge (Proton's lsteamclient), both halves.
    public var lsteamclient: URL { resources.appending(path: "lib/wine/aarch64-windows/lsteamclient.dll") }
    public var lsteamclientUnix: URL { resources.appending(path: "lib/wine/aarch64-unix/lsteamclient.so") }

    public var launcherBinary: URL { root.appending(path: "bin/macneutron") }
    /// MacNeutron's `steam.exe`, installed next to the launcher.
    public var steamHelper: URL { root.appending(path: "bin/steam.exe") }

    /// `steam.exe` and both halves of the bridge are present.
    public var steamBridgeInstalled: Bool {
        [steamHelper, lsteamclientUnix, lsteamclient]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Written by a launch that finds `wine.app` missing or unreadable; the app then reinstalls it.
    public var runtimeDamagedMarker: URL { root.appending(path: "runtime-damaged") }

    /// `wine.app`'s `CFBundleShortVersionString`, read from disk each time (`Bundle` caches per path, and an
    /// install swaps the bundle under the same path).
    public var runtimeVersion: String? {
        guard let data = try? Data(contentsOf: wineApp.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// `wine.app`'s CDHash, or nil when it is missing or unsigned.
    public var identity: String? { CodeIdentity.of(wineApp) }

    /// `<version> (<identity, 12 hex digits>)`, for launcher.log and the menu.
    public static func runtimeLabel(version: String?, identity: String?) -> String {
        "\(version ?? "unknown") (\(identity.map { String($0.prefix(12)) } ?? "unsigned"))"
    }

    /// What the Rosetta-era runtime left in the tool folder; the install removes them.
    public static let rosettaEraEntries = ["Libraries", "gptk", "gptk.json", "gptk.staging", "lib", "dxmt-version",
                                           "runtime-version", "runtime.staging"]
}
