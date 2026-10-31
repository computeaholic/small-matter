import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var stats: SystemStatsModel
    @EnvironmentObject private var battery: BatteryManager
    @EnvironmentObject private var cooling: CoolingService
    @StateObject private var recentChanges: RecentChangesViewModel

    init(journal: any EvidenceJournal) {
        _recentChanges = StateObject(wrappedValue: RecentChangesViewModel(journal: journal))
    }

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                OverviewHeader(stats: stats)
                OverviewPerformanceHero(
                    stats: stats,
                    battery: battery,
                    layout: layout,
                    navigate: navigate
                )
                OverviewEvidencePanels(
                    stats: stats,
                    cooling: cooling,
                    recentChanges: recentChanges,
                    layout: layout,
                    navigate: navigate
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Overview")
        .task { await recentChanges.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .horizon2JournalDidResolve)) { _ in
            Task { await recentChanges.refresh() }
        }
    }

    private func navigate(to section: AppSection) {
        NotificationCenter.default.post(name: .tunixNavigate, object: section.rawValue)
    }
}
