import Foundation
import Testing
@testable import MacNeutronCore

private let context = try! CompatContext(environment: ["STEAM_COMPAT_DATA_PATH": "/c/42", "SteamAppId": "42"])

@Test func setsPrefixOverridesAndDefaults() {
    let env = LaunchEnvironment.build(base: ["PATH": "/usr/bin"], context: context, backend: .dxmt, logging: false)
    #expect(env["WINEPREFIX"] == "/c/42/pfx/")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=n,b;d3d9=b;d3d10=b")
    #expect(env["WINEDEBUG"] == "-all")
    #expect(env["ROSETTA_ADVERTISE_AVX"] == nil)
    #expect(env["WINEMSYNC"] == "1")
    #expect(env["PATH"] == "/usr/bin")
}

@Test func wined3dOverridesUseBuiltins() {
    let env = LaunchEnvironment.build(base: [:], context: context, backend: .wined3d, logging: false)
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=b;d3d9=b;d3d10=b;d3d10core=b;d3d11=b;d3d12=b")
}

@Test func loggingTurnsOnWineDebugChannels() {
    let env = LaunchEnvironment.build(base: [:], context: context, backend: .dxmt, logging: true)
    #expect(env["WINEDEBUG"] == "+err,+warn,+loaddll,+steamclient,+timestamp")
}

@Test func userSettingsWin() {
    let env = LaunchEnvironment.build(
        base: ["WINEDEBUG": "+seh", "WINEDLLOVERRIDES": "d3d11=b;xinput1_3=n"],
        context: context, backend: .dxmt, logging: true)
    #expect(env["WINEDEBUG"] == "+seh")
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=b;d3d12=n,b;d3d9=b;d3d10=b;xinput1_3=n")
}

@Test func optOutsDropDefaults() {
    let env = LaunchEnvironment.build(base: ["MACNEUTRON_NO_MSYNC": "1"], context: context, backend: .dxmt, logging: false)
    #expect(env["WINEMSYNC"] == nil)
    // Off means unset, even when a launch option also set it: client and server must agree.
    let set = LaunchEnvironment.build(base: ["MACNEUTRON_NO_MSYNC": "1", "WINEMSYNC": "1"], context: context,
                                      backend: .dxmt, logging: false)
    #expect(set["WINEMSYNC"] == nil)
}

@Test func mergeKeepsDisabledEntries() {
    #expect(LaunchEnvironment.mergeOverrides("a=b", user: "c=") == "a=b;c=")
}

@Test func userOverridesWin() {
    let env = LaunchEnvironment.build(base: ["WINEDLLOVERRIDES": "d3d12=b"], context: context, backend: .dxmt, logging: false)
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=b;d3d9=b;d3d10=b")
}

@Test func recordsPipelinesForDXMTOnly() {
    func record(_ base: [String: String], _ backend: GraphicsBackend) -> String? {
        LaunchEnvironment.build(base: base, context: context, backend: backend, logging: false)["DXMT_PIPELINE_RECORD"]
    }
    #expect(record([:], .dxmt) == "/c/42/dxmt-pipelines")
    #expect(record([:], .wined3d) == nil)
    #expect(record(["MACNEUTRON_PRECACHE": "0"], .dxmt) == nil)
    #expect(record(["DXMT_PIPELINE_RECORD": "/mine"], .dxmt) == "/mine")
}
