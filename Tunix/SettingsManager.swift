import SwiftUI

struct AppSettings: Codable {
    var refreshInterval: Double = 3
    var safeCleanupMode: Bool = true

    private enum CodingKeys: String, CodingKey {
        case refreshInterval
        case safeCleanupMode
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 3
        safeCleanupMode = try container.decodeIfPresent(Bool.self, forKey: .safeCleanupMode) ?? true
    }
}

final class SettingsManager: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard !isLoading else { return }
            save()
        }
    }

    private let settingsURL: URL
    private var isLoading = false

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent(
            ProductIdentity.stableApplicationSupportDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settingsURL = folder.appendingPathComponent("settings.plist")
        settings = AppSettings()
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? PropertyListDecoder().decode(AppSettings.self, from: data)
        else { return }
        isLoading = true
        settings = decoded
        isLoading = false
    }

    private func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Form {
            Section("Monitoring") {
                Picker("Refresh interval", selection: $settings.settings.refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                .pickerStyle(.segmented)
                Text("Current readings refresh in the foreground; history remains bounded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Toggle("Safe Cleanup Mode", isOn: $settings.settings.safeCleanupMode)
                Text("When enabled, cleanup is limited to cache/log targets with quarantine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .padding(16)
    }
}
