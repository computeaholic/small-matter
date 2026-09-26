import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case performance = "Performance"
    case fan = "Cooling"
    case battery = "Battery"
    case cleanup = "Cleanup"
    case security = "System Health"

    var id: String {
        rawValue
    }

    var systemImage: String {
        switch self {
        case .overview: return "sparkles"
        case .fan: return "fanblades.fill"
        case .battery: return "battery.100percent"
        case .cleanup: return "sparkles.rectangle.stack"
        case .performance: return "speedometer"
        case .security: return "heart.text.square"
        }
    }
}

@MainActor
struct AppShellView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @AppStorage("tunix.selectedSection") private var selectedSection = AppSection.overview.rawValue
    @State private var uiTestingSelectedSection = AppSection.overview.rawValue
    @StateObject private var settingsManager: SettingsManager
    @StateObject private var thermalManager = ThermalManager()
    @StateObject private var systemStats: SystemStatsModel
    @StateObject private var batteryManager: BatteryManager
    @StateObject private var diskTool: DiskTool
    @StateObject private var cooling: CoolingService
    @StateObject private var systemOperator: SystemOperator

    init(settingsManager: SettingsManager) {
        let settings = settingsManager
        let thermalManager = ThermalManager()
        let stats = SystemStatsModel(refreshInterval: settings.settings.refreshInterval, thermalManager: thermalManager)
        let battery = BatteryManager()
        let systemOperator = SystemOperator(thermalManager: thermalManager, statsModel: stats, batteryManager: battery)

        _settingsManager = StateObject(wrappedValue: settings)
        _thermalManager = StateObject(wrappedValue: thermalManager)
        _systemStats = StateObject(wrappedValue: stats)
        _batteryManager = StateObject(wrappedValue: battery)
        _diskTool = StateObject(wrappedValue: DiskTool())
        _cooling = StateObject(wrappedValue: CoolingService())
        _systemOperator = StateObject(wrappedValue: systemOperator)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: selectionBinding, openSettings: { openSettings() })
        } detail: {
            DetailView(selection: currentSelection)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 650)
        .accessibilityIdentifier("small-matter-main-view")
        .environmentObject(settingsManager)
        .environmentObject(thermalManager)
        .environmentObject(systemStats)
        .environmentObject(batteryManager)
        .environmentObject(diskTool)
        .environmentObject(cooling)
        .environmentObject(systemOperator)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: keepAwake.binding) {
                    Label(
                        "Keep Awake",
                        systemImage: keepAwake.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer"
                    )
                }
                .toggleStyle(.button)
                .tint(keepAwake.isEnabled ? TunixBrand.accent : .secondary)
                .accessibilityIdentifier("keep-awake-toggle")
                .accessibilityValue(keepAwake.isEnabled ? "On" : "Off")
                .help(
                    keepAwake.isEnabled
                        ? "Turn off Keep Awake"
                        : "Prevent idle system sleep while \(ProductIdentity.displayName) is running"
                )
            }
        }
        .onChange(of: settingsManager.settings.refreshInterval) { _, newValue in
            systemStats.setRefreshInterval(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tunixNavigate)) { notification in
            guard let rawValue = notification.object as? String,
                  AppSection(rawValue: rawValue) != nil
            else { return }
            if isUITesting {
                uiTestingSelectedSection = rawValue
            } else {
                selectedSection = rawValue
            }
        }
    }

    private var currentSelection: AppSection {
        let rawValue = isUITesting ? uiTestingSelectedSection : selectedSection
        return AppSection(rawValue: rawValue) ?? .overview
    }

    private var selectionBinding: Binding<AppSection?> {
        Binding(
            get: { currentSelection },
            set: {
                let rawValue = ($0 ?? .overview).rawValue
                if isUITesting {
                    uiTestingSelectedSection = rawValue
                } else {
                    selectedSection = rawValue
                }
            }
        )
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITesting")
    }
}

struct Sidebar: View {
    @Binding var selection: AppSection?
    let openSettings: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Core") {
                ForEach([AppSection.overview, .performance, .fan, .battery]) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("navigation-\(section.rawValue)")
                }
            }

            Section("Utility") {
                ForEach([AppSection.cleanup, .security]) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("navigation-\(section.rawValue)")
                }
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigation-Settings")
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(ProductIdentity.displayName)
        .frame(minWidth: 190, idealWidth: 210)
    }
}

struct DetailView: View {
    let selection: AppSection

    var body: some View {
        Group {
            switch selection {
            case .overview:
                OverviewView()
            case .fan:
                FanControlView()
            case .battery:
                BatteryView()
            case .cleanup:
                DiskToolView()
            case .performance:
                PerformanceView()
            case .security:
                SecurityView()
            }
        }
        .frame(maxWidth: contentWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentWidth: CGFloat {
        switch selection {
        case .overview: return 1180
        case .performance: return 1240
        case .fan: return 980
        case .battery: return 1020
        case .cleanup: return 980
        case .security: return 900
        }
    }
}
