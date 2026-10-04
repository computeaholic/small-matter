import SwiftUI

enum TemperatureDisplayUnit: String, Codable, CaseIterable, Identifiable {
    case system
    case celsius
    case fahrenheit

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .celsius: return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }
}

enum TemperaturePresentation {
    static func string(
        celsius: Double?,
        unit: TemperatureDisplayUnit,
        locale: Locale = .current
    ) -> String {
        guard let celsius else { return "Unavailable" }
        return string(celsius: celsius, unit: unit, locale: locale)
    }

    static func string(
        celsius: Double,
        unit: TemperatureDisplayUnit,
        locale: Locale = .current
    ) -> String {
        let measurement: Measurement<UnitTemperature>
        switch unit {
        case .system:
            measurement = Measurement(value: celsius, unit: .celsius)
        case .celsius:
            measurement = Measurement(value: celsius, unit: .celsius)
        case .fahrenheit:
            measurement = Measurement(value: celsius, unit: .celsius).converted(to: .fahrenheit)
        }

        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = unit == .system ? .naturalScale : .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.numberFormatter.minimumFractionDigits = 1
        return formatter.string(from: measurement)
    }
}

struct AppSettings: Codable {
    var refreshInterval: Double = 3
    var safeCleanupMode: Bool = true
    var temperatureUnit: TemperatureDisplayUnit = .system

    private enum CodingKeys: String, CodingKey {
        case refreshInterval
        case safeCleanupMode
        case temperatureUnit
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 3
        safeCleanupMode = try container.decodeIfPresent(Bool.self, forKey: .safeCleanupMode) ?? true
        temperatureUnit = try container.decodeIfPresent(
            TemperatureDisplayUnit.self,
            forKey: .temperatureUnit
        ) ?? .system
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

            Section("Display") {
                Picker("Temperature units", selection: $settings.settings.temperatureUnit) {
                    ForEach(TemperatureDisplayUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("temperature-unit-picker")
                Text(
                    "System follows the measurement preferences for this Mac. "
                        + "Sensor and evidence values remain in Celsius."
                )
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
