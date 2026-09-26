import SwiftUI

struct DiskToolView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var diskTool: DiskTool
    @State private var showingCleanupConfirmation = false

    private let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        TunixAdaptivePage { layout in
            VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                TunixPageHeader(
                    title: "Disk Cleanup",
                    subtitle: "Scan first, review what can be reclaimed, then stage it safely."
                )
                cleanupContent(for: layout)
            }
        }
        .navigationTitle("Cleanup")
        .confirmationDialog(
            "Stage cleanup?",
            isPresented: $showingCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stage Cleanup", role: .destructive) {
                diskTool.stageCleanup(safeMode: settings.settings.safeCleanupMode)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Selected items will be moved to Small Matter Quarantine. Nothing is permanently deleted, " +
                    "and the last action can be undone."
            )
        }
    }

    @ViewBuilder
    private func cleanupContent(for layout: TunixLayoutClass) -> some View {
        switch layout {
        case .compact, .standard:
            workflow
            scanControls
            targetList
            actionSummary
            safetyNote
        case .wide, .large:
            HStack(alignment: .top, spacing: TunixDesign.sectionSpacing) {
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    workflow
                    scanControls
                    targetList
                }
                VStack(alignment: .leading, spacing: TunixDesign.sectionSpacing) {
                    actionSummary
                    safetyNote
                }
                .frame(width: 300, alignment: .topLeading)
            }
        }
    }

    private var workflow: some View {
        HStack(spacing: 10) {
            workflowStep("1", "Scan")
            workflowDivider
            workflowStep("2", "Review")
            workflowDivider
            workflowStep("3", "Stage")
            workflowDivider
            workflowStep("4", "Undo")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cleanup workflow: scan, review, stage, undo")
    }

    private var scanControls: some View {
        HStack(spacing: 12) {
            Button(diskTool.isScanning ? "Scanning…" : "Scan") {
                diskTool.scan()
            }
            .buttonStyle(.borderedProminent)
            .disabled(diskTool.isScanning)

            Button(diskTool.isStaging ? "Staging…" : "Stage Cleanup…") {
                showingCleanupConfirmation = true
            }
            .buttonStyle(.bordered)
            .disabled(diskTool.lastScan == nil || diskTool.isScanning || diskTool.isStaging)

            Button("Undo Last Cleanup") {
                diskTool.undoLastAction()
            }
            .buttonStyle(.bordered)
            .disabled(diskTool.lastAction == nil || diskTool.isStaging)

            Spacer()
            if let lastScan = diskTool.lastScan {
                Text("Scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            TunixSectionHeader(title: "Reclaimable space", subtitle: "Choose categories after the scan completes")
            if diskTool.lastScan == nil {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Nothing scanned yet")
                        .font(.headline)
                    Text("Scan your user-scoped cleanup locations to see what can be reclaimed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach($diskTool.targets) { $target in
                    targetRow(target: $target)
                }
            }
        }
    }

    private func targetRow(target: Binding<DiskCleanupTarget>) -> some View {
        HStack(spacing: 14) {
            Toggle(isOn: target.isEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.wrappedValue.name)
                        .font(.body.weight(.semibold))
                    Text(explanation(for: target.wrappedValue.name))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Show location") {
                        Text(target.wrappedValue.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText(target.wrappedValue.sizeBytes))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(accessLabel(for: target.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(accessColor(for: target.wrappedValue))
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var actionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastAction = diskTool.lastAction {
                TunixSectionHeader(title: "Last cleanup")
                Text(
                    "\(lastAction.targets.joined(separator: ", ")) · " +
                        formatter.string(fromByteCount: Int64(lastAction.totalBytes))
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if let error = diskTool.lastError {
                TunixStatusBadge(title: "Needs attention", systemImage: "exclamationmark.triangle", tint: .orange)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            TunixSectionHeader(title: "Safe Cleanup")
            Text(
                settings.settings.safeCleanupMode
                    ? "Safe mode is on. Cleanup is limited to user cache and log locations, " +
                    "and items are staged in Small Matter Quarantine."
                    : "Advanced cleanup locations can be selected manually. " +
                    "Items are still staged in Small Matter Quarantine before removal."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func workflowStep(_ number: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.bold).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(TunixDesign.subtleFill, in: Circle())
            Text(title)
        }
    }

    private var workflowDivider: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func explanation(for name: String) -> String {
        switch name {
        case "User Caches": return "Temporary app data that can be regenerated."
        case "System Caches": return "Shared caches that may be restricted by macOS."
        case "User Logs": return "Local application logs retained by the user."
        case "System Logs": return "System log data subject to macOS permissions."
        case "Temporary": return "Temporary user-scoped files."
        default: return "System-scoped files; availability depends on macOS permissions."
        }
    }

    private func accessLabel(for target: DiskCleanupTarget) -> String {
        let path = (target.path as NSString).expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: path) ? "Available" : "Restricted"
    }

    private func accessColor(for target: DiskCleanupTarget) -> Color {
        accessLabel(for: target) == "Available" ? .secondary : .orange
    }

    private func sizeText(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
