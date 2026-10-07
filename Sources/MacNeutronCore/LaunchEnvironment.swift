import Foundation

public enum LaunchEnvironment {
    /// Wine's environment: Steam's (including the user's launch-option variables) plus ours.
    /// Anything the user set explicitly wins over our defaults.
    public static func build(base: [String: String], context: CompatContext, backend: GraphicsBackend,
                             logging: Bool) -> [String: String] {
        var env = base
        env["WINEPREFIX"] = context.prefix.path(percentEncoded: false)
        env["WINEDLLOVERRIDES"] = mergeOverrides(backend.dllOverrides, user: base["WINEDLLOVERRIDES"])
        if base["WINEDEBUG"] == nil {
            env["WINEDEBUG"] = logging ? "+err,+warn,+loaddll,+steamclient,+timestamp" : "-all"
        }
        // msync off means unset, whoever set it: Wine's client and server must agree on it.
        if base["MACNEUTRON_NO_MSYNC"] == "1" {
            env.removeValue(forKey: "WINEMSYNC")
        } else if base["WINEMSYNC"] == nil {
            env["WINEMSYNC"] = "1"
        }
        if ShaderPrecache.enabled(backend: backend, environment: base), base["DXMT_PIPELINE_RECORD"] == nil {
            env["DXMT_PIPELINE_RECORD"] = ShaderPrecache.folder(for: context).path(percentEncoded: false)
        }
        return env
    }

    /// Merges two `WINEDLLOVERRIDES` strings by DLL name, `user` winning. Wine looks entries up
    /// in a sorted list, so a repeated name would make the winner arbitrary.
    public static func mergeOverrides(_ ours: String, user: String?) -> String {
        var order: [String] = []
        var modes: [String: String] = [:]
        for spec in [ours, user ?? ""] {
            for entry in spec.split(separator: ";") {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let mode = parts.count == 2 ? String(parts[1]) : ""
                for name in parts[0].split(separator: ",") {
                    let key = name.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    if modes[key] == nil { order.append(key) }
                    modes[key] = mode
                }
            }
        }
        return order.map { "\($0)=\(modes[$0]!)" }.joined(separator: ";")
    }
}
