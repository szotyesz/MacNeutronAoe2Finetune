import Foundation

/// How a game's Direct3D is rendered for one launch.
public enum GraphicsBackend: String, Sendable, CaseIterable {
    /// DXMT: Direct3D 10-12 on Metal, MacNeutron's default.
    case dxmt
    /// DXVK: Direct3D 10-11 on Vulkan, on KosmicKrisp (Mesa's Vulkan driver on Metal). The default of the games in
    /// `gameDefaults`.
    case dxvk
    /// Wine's built-in Direct3D 9-11 over OpenGL: an escape hatch for a Direct3D 11 game DXMT breaks.
    case wined3d

    /// The games whose default isn't DXMT, by Steam app ID. Age of Empires II: Definitive Edition draws its menu text
    /// wrong on DXMT and right on DXVK.
    public static let gameDefaults: [String: GraphicsBackend] = ["813780": .dxvk]

    /// What a game renders with when nothing asks for a backend.
    public static func defaultBackend(appID: String?) -> GraphicsBackend {
        appID.flatMap { gameDefaults[$0] } ?? .dxmt
    }

    /// Honors `MACNEUTRON_GRAPHICS` when valid; otherwise the game's default. `note` explains any fallback so the
    /// launcher can log it.
    public static func select(requested: String?, appID: String? = nil) -> (backend: GraphicsBackend, note: String?) {
        let fallback = defaultBackend(appID: appID)
        guard let raw = requested?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return (fallback, nil)
        }
        // Settings files written before 0.1 can still name it.
        if raw == "d3dmetal" {
            return (fallback, "'\(raw)' was removed in 0.1, using \(fallback.rawValue)")
        }
        guard let backend = GraphicsBackend(rawValue: raw) else {
            return (fallback, "unknown MACNEUTRON_GRAPHICS '\(raw)', using \(fallback.rawValue)")
        }
        return (backend, nil)
    }

    /// `WINEDLLOVERRIDES` for this backend. Every backend names every D3D DLL any backend
    /// manages, so DLLs a previous backend left in the prefix can never leak into this launch.
    public var dllOverrides: String {
        switch self {
        case .dxmt: "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b"
        case .dxvk: "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b"
        case .wined3d: "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b"
        }
    }

    /// How the app's games window names it.
    public var displayName: String {
        switch self {
        case .dxmt: "DXMT"
        case .dxvk: "DXVK (Vulkan)"
        case .wined3d: "wined3d (OpenGL)"
        }
    }
}
