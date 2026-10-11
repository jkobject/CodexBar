import CodexBarCore
import SwiftUI

/// Configures one saved host and explains the automatically refreshed, deduplicated usage totals.
@MainActor
struct CrossHostUsagePanel: View {
    let calendar: Calendar
    var host = ""
    var reports: [UsageProvider: CombinedUsageLedgerReport] = [:]
    var errors: [UsageProvider: String] = [:]
    var refreshing: Set<UsageProvider> = []
    var stages: [UsageProvider: [String: String]] = [:]
    var onSetHost: (String) throws -> Void = { _ in }
    @State private var draftHost = ""
    @State private var errorMessage: String?

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Cross-host usage — Experimental"), systemImage: "desktopcomputer")
                    .font(.headline)
                Text(L("Add one SSH host to include its native histories in normal usage refreshes. "
                        + "Conversation text stays on each machine."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                self.controls
                if !self.refreshing.isEmpty {
                    self.progress
                }
                if let errorMessage = self.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !self.host.isEmpty {
                    // Provider-specific by design: Automatic combined history exists for Codex and Claude only.
                    ForEach([UsageProvider.codex, .claude], id: \.self) { provider in
                        if let report = self.reports[provider] {
                            self.results(report)
                        } else if let error = self.errors[provider] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: ProviderDescriptorRegistry.descriptor(for: provider).metadata
                                    .displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("cross-host-usage-panel")
        .onChange(of: self.host) { _, _ in
            self.draftHost = ""
            self.errorMessage = nil
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.host.isEmpty {
                HStack {
                    TextField(L("SSH host alias"), text: self.$draftHost)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("cross-host-usage-host")
                        .onSubmit { self.saveHost(self.draftHost) }
                    Button(L("Add host")) { self.saveHost(self.draftHost) }
                        .fixedSize()
                        .disabled(self.draftHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("cross-host-usage-add")
                }
            } else {
                HStack {
                    Label(self.host, systemImage: "server.rack")
                        .textSelection(.enabled)
                    Spacer()
                    Button(L("Remove host")) { self.saveHost("") }
                        .accessibilityIdentifier("cross-host-usage-remove")
                }
                Text(L("Included automatically for Codex and Claude Code. Remove the host to return to local usage."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("SSH history is limited to the last 365 days."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progress: some View {
        HStack(alignment: .top) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(self.refreshing.sorted { $0.rawValue < $1.rawValue }, id: \.self) { provider in
                    let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
                    let sources = self.stages[provider] ?? [:]
                    ForEach(sources.keys.sorted(), id: \.self) { source in
                        let host = source == "local" ? L("This Mac") : source
                        Text("\(name) · \(host): \(self.stageText(sources[source] ?? "reading"))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func stageText(_ stage: String) -> String {
        switch stage {
        case "finished": L("Read complete")
        case "unavailable": L("Unavailable")
        default: L("Reading usage histories…")
        }
    }

    private func results(_ report: CombinedUsageLedgerReport) -> some View {
        let combined = report.combined
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            // Provider-specific by design: These are the only two wire provider names accepted by the ledger.
            Text(verbatim: report.provider == "codex" ? "Codex" : "Claude Code")
                .font(.subheadline.weight(.medium))
            if report.reports.contains(where: { $0.ledger != nil }) {
                if let days = report.reports.compactMap(\.ledger).first?.historyDays {
                    Text(L("Last %d days", days)).font(.caption).foregroundStyle(.secondary)
                }
                Text(combined.coverageIsEstablished
                    ? L("Deduplicated usage") : L("Recorded subtotal"))
                    .font(.subheadline.weight(.medium))
                Text(spendDashboardMetricText(
                    cost: combined.costUSD ?? combined.pricedCostUSD,
                    tokens: combined.totalTokens,
                    currencyCode: "USD",
                    costIsLowerBound: combined.costUSD == nil || !combined.coverageIsEstablished,
                    tokensAreLowerBound: !combined.coverageIsEstablished))
                    .font(.title3.monospacedDigit())
                Text(L("Recorded cost or API-price estimate — not a billing receipt."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Usage history unavailable"))
                    .font(.subheadline.weight(.medium))
            }
            Text(L("Duplicates removed: %d · Conflicts excluded: %d", combined.duplicateCount, combined.conflictCount))
                .font(.caption)
            Text(L(
                "Unidentified records excluded: %d · Legacy records excluded: %d",
                combined.unidentifiedCount,
                combined.legacyIdentityCount))
                .font(.caption)
            if !combined.coverageIsEstablished {
                Text(L("Coverage is incomplete. Missing histories or uncertain records "
                        + "can leave usage out of this subtotal."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if combined.legacyIdentityCount > 0 {
                Text(
                    L(
                        "Legacy records are excluded because their identities "
                            + "cannot reliably distinguish copied requests."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if combined.unpricedCount > 0 {
                Text(L("Cost includes only records with known prices."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("Missing or conflicting prices: %d", combined.unpricedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(report.reports.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: 2) {
                    if let ledger = source.ledger {
                        Text("\(source.host) · \(ledger.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        if ledger.incompleteRequestCount > 0 {
                            Text(L("Incomplete requests excluded: %d", ledger.incompleteRequestCount))
                        }
                        if !ledger.warnings.isEmpty {
                            DisclosureGroup(L("Source diagnostics")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(ledger.warnings.enumerated()), id: \.offset) { _, warning in
                                        Text(verbatim: warning)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    } else {
                        Text("\(source.host) · \(source.error ?? L("Usage history unavailable"))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func saveHost(_ value: String) {
        do {
            try self.onSetHost(value)
            self.draftHost = ""
            self.errorMessage = nil
        } catch {
            self.errorMessage = L("Enter a valid SSH host alias, without spaces or command options.")
        }
    }
}
