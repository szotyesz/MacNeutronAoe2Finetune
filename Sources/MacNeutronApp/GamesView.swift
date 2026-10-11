import MacNeutronCore
import SwiftUI

struct GamesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: UInt32?

    private var rows: [GameRow] {
        search.isEmpty ? model.games : model.games.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Game") { row in
                    HStack {
                        Text(row.name)
                        if row.installed { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TableColumn("Runs as") { row in
                    if row.isDualPlatform {
                        Picker("", selection: Binding(
                            get: { row.settings.runAs ?? .mac },
                            set: { value in Task { await model.update(row.id) { $0.runAs = value == .mac ? nil : value } } })) {
                            Text("Mac version").tag(RunAs.mac)
                            Text("Windows version").tag(RunAs.windows)
                        }
                        .labelsHidden()
                    } else {
                        Text(row.app.oslist.contains("macos") ? "Mac version" : "Windows").foregroundStyle(.secondary)
                    }
                }
                TableColumn("Graphics") { row in
                    if row.runsWithMacNeutron {
                        Picker("", selection: Binding(
                            // A value from before 0.1 (d3dmetal) runs the default, so it shows as the default.
                            get: { row.settings.graphics.flatMap { GraphicsBackend(rawValue: $0)?.rawValue } ?? "" },
                            set: { value in Task { await model.update(row.id) { $0.graphics = value.isEmpty ? nil : value } } })) {
                            Text("Default (\(GraphicsBackend.defaultBackend(appID: String(row.id)).displayName))").tag("")
                            ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                                Text(backend.displayName).tag(backend.rawValue)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Text("Native").foregroundStyle(.secondary)
                    }
                }
            }
            if let row = rows.first(where: { $0.id == selection }), row.runsWithMacNeutron {
                HStack(spacing: 16) {
                    Text(row.name).bold()
                    Toggle("Log", isOn: binding(row, \.log, default: false))
                    Toggle("msync", isOn: binding(row, \.msync, default: true))
                    Toggle("MetalFX upscaling", isOn: binding(row, \.metalFX, default: true))
                        .help("Upscales with Apple's MetalFX when the game renders below its window or the display's pixel density.")
                    Spacer()
                }
                .padding(10)
            }
            if let error = model.errorMessage {
                HStack {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
                .padding(10)
            }
            if case .restartNeeded = model.status {
                HStack {
                    Text(model.status.menuTitle).foregroundStyle(.orange)
                    Spacer()
                    Button("Restart Steam") { Task { await model.restartSteam() } }
                }
                .padding(10)
            }
        }
        .searchable(text: $search)
        .frame(minWidth: 640, minHeight: 360)
        .overlay {
            if let error = model.appInfoError {
                ContentUnavailableView("Steam's app list couldn't be read", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
    }

    private func binding(_ row: GameRow, _ key: WritableKeyPath<GameSettings, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { row.settings[keyPath: key] ?? value },
                set: { newValue in Task { await model.update(row.id) { $0[keyPath: key] = newValue == value ? nil : newValue } } })
    }
}
