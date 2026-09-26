//
//  SmallMatterApp.swift
//  Small Matter
// swiftlint:disable trailing_comma
import AppKit
import SwiftUI

@main
struct SmallMatterApp: App {
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var keepAwake = KeepAwakeController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsManager)
                .environmentObject(keepAwake)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .environmentObject(settingsManager)
        }

        .commands {
            SmallMatterCommands(keepAwake: keepAwake)
        }
    }
}

extension Notification.Name {
    static let tunixNavigate = Notification.Name("com.tunix.navigate")
}

private enum SmallMatterNavigationDestination: String {
    case overview = "Overview"
    case performance = "Performance"
    case cooling = "Cooling"
    case battery = "Battery"
    case cleanup = "Cleanup"
    case systemHealth = "System Health"
}

private struct SmallMatterCommands: Commands {
    @ObservedObject var keepAwake: KeepAwakeController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(ProductIdentity.displayName)") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .applicationName: ProductIdentity.displayName,
                    .applicationVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "",
                    .credits: NSAttributedString(string: ProductIdentity.tagline),
                    .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                ])
            }
        }

        CommandMenu("Utilities") {
            Toggle("Keep Awake", isOn: keepAwake.binding)
                .toggleStyle(.checkbox)
        }

        CommandMenu("Navigate") {
            navigationButton("Overview", destination: .overview, shortcut: "1")
            navigationButton("Performance", destination: .performance, shortcut: "2")
            navigationButton("Cooling", destination: .cooling, shortcut: "3")
            navigationButton("Battery", destination: .battery, shortcut: "4")
            navigationButton("Cleanup", destination: .cleanup, shortcut: "5")
            navigationButton("System Health", destination: .systemHealth, shortcut: "6")
        }

        CommandGroup(after: .help) {
            Button("Open System Health") {
                navigate(to: .systemHealth)
            }
        }
    }

    private func navigationButton(
        _ title: String,
        destination: SmallMatterNavigationDestination,
        shortcut: KeyEquivalent
    ) -> some View {
        Button(title) {
            navigate(to: destination)
        }
        .keyboardShortcut(shortcut, modifiers: .command)
    }

    private func navigate(to destination: SmallMatterNavigationDestination) {
        NotificationCenter.default.post(name: .tunixNavigate, object: destination.rawValue)
    }
}

// swiftlint:enable trailing_comma
