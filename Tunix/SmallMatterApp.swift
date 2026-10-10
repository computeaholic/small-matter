//
//  SmallMatterApp.swift
//  Small Matter
import AppKit
import SwiftUI

final class SmallMatterAppDelegate: NSObject, NSApplicationDelegate {
    typealias JournalBootstrap = @Sendable () async -> any EvidenceJournal

    let evidenceRuntime: EvidenceRuntime
    let contextHistory: IncidentContextHistory
    lazy var incidentCapture: IncidentCaptureCoordinator = .init(
        journal: evidenceRuntime.journal,
        processRunID: evidenceRuntime.processRunID,
        correlationService: IncidentCorrelationService(journal: evidenceRuntime.journal),
        contextHistory: contextHistory
    )
    private let deferredJournal: DeferredEvidenceJournal?
    private let journalBootstrap: JournalBootstrap?
    private var bootstrapTask: Task<Void, Never>?

    override init() {
        contextHistory = IncidentContextHistory()
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-UITesting")
        #if HORIZON2_MEASUREMENT
            let measurementConfiguration = Horizon2MeasurementConfiguration(arguments: ProcessInfo.processInfo
                .arguments)
            let measurementJournal = measurementConfiguration
                .flatMap { try? SQLiteEvidenceJournal(databaseURL: $0.journalURL) }
            let measurementEnabled = !(measurementConfiguration?.disableEvidenceRuntime ?? false)
        #else
            let measurementJournal: (any EvidenceJournal)? = nil
            let measurementEnabled = true
        #endif
        if isUITesting {
            deferredJournal = nil
            journalBootstrap = nil
            evidenceRuntime = EvidenceRuntime(
                journal: RecentChangesFixture.journal(arguments: ProcessInfo.processInfo.arguments),
                enabled: false
            )
        } else if let measurementJournal {
            deferredJournal = nil
            journalBootstrap = nil
            #if HORIZON2_MEASUREMENT
                let measurementAdapterFactory: EvidenceRuntime.AdapterFactory?
                if measurementConfiguration?.idle == false {
                    measurementAdapterFactory = { _ in [] as [any Horizon2EvidenceAdapter] }
                } else {
                    measurementAdapterFactory = nil
                }
                let measurementIngressCapacity = measurementConfiguration?
                    .ingressCapacity ?? Horizon2EvidenceConfiguration.collectorQueueCapacity
            #else
                let measurementAdapterFactory: EvidenceRuntime.AdapterFactory? = nil
                let measurementIngressCapacity = Horizon2EvidenceConfiguration.collectorQueueCapacity
            #endif
            evidenceRuntime = EvidenceRuntime(
                journal: measurementJournal,
                adapterFactory: measurementAdapterFactory,
                enabled: measurementEnabled,
                ingressCapacity: measurementIngressCapacity
            )
        } else {
            let deferred = DeferredEvidenceJournal()
            deferredJournal = deferred
            journalBootstrap = { await Horizon2JournalFactory.makeProductionOffMainActor() }
            evidenceRuntime = EvidenceRuntime(journal: deferred)
        }
        super.init()
    }

    init(evidenceRuntime: EvidenceRuntime) {
        contextHistory = IncidentContextHistory()
        self.evidenceRuntime = evidenceRuntime
        deferredJournal = nil
        journalBootstrap = nil
        super.init()
    }

    init(
        evidenceRuntime: EvidenceRuntime,
        deferredJournal: DeferredEvidenceJournal,
        journalBootstrap: @escaping JournalBootstrap
    ) {
        contextHistory = IncidentContextHistory()
        self.evidenceRuntime = evidenceRuntime
        self.deferredJournal = deferredJournal
        self.journalBootstrap = journalBootstrap
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard let deferredJournal, let journalBootstrap else {
            evidenceRuntime.start()
            #if HORIZON2_MEASUREMENT
                runMeasurementIfRequested()
            #endif
            seedUITestingIncidentFixtureIfNeeded()
            return
        }
        bootstrapTask = Task { [weak self] in
            let journal = await journalBootstrap()
            guard !Task.isCancelled else { return }
            await deferredJournal.resolve(journal)
            NotificationCenter.default.post(name: .horizon2JournalDidResolve, object: nil)
            guard !Task.isCancelled else { return }
            self?.evidenceRuntime.start()
        }
    }

    #if HORIZON2_MEASUREMENT
        private func runMeasurementIfRequested() {
            guard let configuration = Horizon2MeasurementConfiguration(arguments: ProcessInfo.processInfo.arguments),
                  !configuration.disableEvidenceRuntime,
                  !configuration.idle
            else { return }
            Task { [weak self] in
                guard let self else { return }
                await Horizon2MeasurementDriver().run(
                    configuration: configuration,
                    runtime: evidenceRuntime,
                    journal: evidenceRuntime.journal
                )
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    #endif

    private func seedUITestingIncidentFixtureIfNeeded() {
        #if DEBUG
            guard let mode = RecentChangesFixture.incidentMode(arguments: ProcessInfo.processInfo.arguments),
                  mode != "idle",
                  mode != "unavailable",
                  mode != "capacity"
            else { return }
            Task { [weak self] in
                guard let self else { return }
                await RecentChangesFixture.seedIncidentFixture(
                    mode: mode,
                    journal: evidenceRuntime.journal,
                    processRunID: evidenceRuntime.processRunID
                )
                await MainActor.run {
                    self.incidentCapture.refreshHistory()
                    NotificationCenter.default.post(name: .horizon2JournalDidResolve, object: nil)
                }
            }
        #endif
    }

    func applicationWillTerminate(_: Notification) {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        evidenceRuntime.stop()
    }
}

@main
struct SmallMatterApp: App {
    @NSApplicationDelegateAdaptor(SmallMatterAppDelegate.self) private var appDelegate
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var keepAwake = KeepAwakeController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsManager)
                .environmentObject(keepAwake)
                .environmentObject(appDelegate.evidenceRuntime)
                .environmentObject(appDelegate.incidentCapture)
                .environmentObject(appDelegate.contextHistory)
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
    case recentChanges = "Recent Changes"
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
                    .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                ])
            }
        }

        CommandMenu("Utilities") {
            Toggle("Keep Awake", isOn: keepAwake.binding)
                .toggleStyle(.checkbox)
        }

        CommandMenu("Navigate") {
            navigationButton("Overview", destination: .overview, shortcut: "1")
            navigationButton("Recent Changes", destination: .recentChanges, shortcut: "7")
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
