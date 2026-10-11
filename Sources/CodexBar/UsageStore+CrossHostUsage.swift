import CodexBarCore
import Foundation

struct CrossHostUsageScope: Equatable, Sendable {
    let host: String
    let timeZone: String
    let settingsRevision: UInt64
}

extension SpendDashboardSource {
    /// Provider-specific by design: Native per-account Codex source IDs retain their existing dashboard display names.
    static func codexDisplayNamesByID(_ sources: [CodexSpendSourceDescriptor]) -> [String: String] {
        sources.reduce(into: [:]) { result, source in
            guard let separator = source.identity.lastIndex(of: "|") else { return }
            result["codex:\(source.identity[..<separator])"] = source.displayName
        }
    }
}

struct CrossHostUsageLoadResult: Sendable {
    let report: CombinedUsageLedgerReport
    let snapshot: CostUsageTokenSnapshot?
    let menuSnapshot: CostUsageTokenSnapshot?
}

@MainActor
extension UsageStore {
    var currentCrossHostUsageScope: CrossHostUsageScope {
        CrossHostUsageScope(
            host: self.settings.crossHostUsageHost,
            timeZone: self.settings.costUsageBucketCalendar.timeZone.identifier,
            settingsRevision: self.settings.costUsageSettingsRevision)
    }

    var crossHostUsageReports: [UsageProvider: CombinedUsageLedgerReport] {
        self.crossHostUsageScope == self.currentCrossHostUsageScope ? self.crossHostUsageReportStorage : [:]
    }

    var crossHostUsageErrors: [UsageProvider: String] {
        self.crossHostUsageScope == self.currentCrossHostUsageScope ? self.crossHostUsageErrorStorage : [:]
    }

    var crossHostUsageRefreshing: Set<UsageProvider> {
        self.crossHostUsageScope == self.currentCrossHostUsageScope ? Set(self.crossHostUsageRefreshTokens.keys) : []
    }

    var crossHostUsageStages: [UsageProvider: [String: String]] {
        self.crossHostUsageScope == self.currentCrossHostUsageScope ? self.crossHostUsageStageStorage : [:]
    }

    func usesCrossHostUsage(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: These native transcript exporters can deduplicate cross-host request identities.
        !self.settings.crossHostUsageHost.isEmpty && (provider == .codex || provider == .claude)
    }

    func crossHostUsageSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        guard self.usesCrossHostUsage(provider), self.crossHostUsageScope == self.currentCrossHostUsageScope else {
            return nil
        }
        return self.crossHostUsageSnapshots[provider]
    }

    func crossHostUsageMenuSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        guard self.crossHostUsageSnapshot(for: provider) != nil else { return nil }
        return self.crossHostUsageMenuSnapshots[provider]
    }

    func crossHostUsageSourceRevision(for provider: UsageProvider) -> String {
        "\(provider.rawValue):cross-host:\(self.crossHostUsagePublicationRevision)"
    }

    func crossHostUsageOwnershipFingerprint(for provider: UsageProvider) -> String {
        "\(provider.rawValue):" + UsageLedgerRecord.digest([
            "cross-host", self.settings.crossHostUsageHost, self.settings.costUsageBucketTimeZoneIdentifier,
        ])
    }

    func crossHostUsageDashboardInput(for provider: UsageProvider) -> SpendDashboardModel.ProviderInput? {
        guard let snapshot = self.crossHostUsageSnapshot(for: provider) else { return nil }
        return SpendDashboardModel.ProviderInput(
            provider: provider,
            displayName: L(
                "%@ · This Mac + %@",
                self.metadata(for: provider).displayName,
                self.settings.crossHostUsageHost),
            snapshot: snapshot,
            sourceKind: .localHistory)
    }

    func refreshCrossHostUsageForDashboard(
        providers: [UsageProvider], mode: SpendDashboardRequestBuildMode) async
    {
        guard mode != .captureOnly else { return }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers where self.usesCrossHostUsage(provider) {
                if mode == .refreshMissing,
                   self.crossHostUsageReports[provider] != nil || self.crossHostUsageErrors[provider] != nil
                {
                    continue
                }
                group.addTask { await self.refreshCrossHostUsage(for: provider, force: mode == .forceRefresh) }
            }
        }
    }

    /// Retire the prior generation before cancellation, including reports retained by a late SSH completion.
    func synchronizeCrossHostUsageConfiguration() {
        let scope = self.currentCrossHostUsageScope
        guard self.crossHostUsageScope != scope else { return }
        let hadConfiguredHost = self.crossHostUsageScope?.host.isEmpty == false
        self.crossHostUsageScope = scope
        for task in self.crossHostUsageTasks.values {
            task.cancel()
        }
        self.crossHostUsageTasks.removeAll()
        self.crossHostUsageRefreshTokens.removeAll()
        self.crossHostUsageReportStorage.removeAll()
        self.crossHostUsageSnapshots.removeAll()
        self.crossHostUsageMenuSnapshots.removeAll()
        self.crossHostUsageErrorStorage.removeAll()
        self.crossHostUsageStageStorage.removeAll()
        self.crossHostUsageLastFetch.removeAll()
        self.crossHostUsagePublicationRevision &+= 1
        if hadConfiguredHost || !scope.host.isEmpty {
            self.persistWidgetSnapshot(reason: "cross-host-scope-change")
        }
    }

    /// Refresh the configured host through the normal cost scheduler, without touching account-scoped caches.
    func refreshCrossHostUsage(for provider: UsageProvider, force: Bool) async {
        self.synchronizeCrossHostUsageConfiguration()
        guard self.usesCrossHostUsage(provider), self.isEnabled(provider),
              self.settings.isCostUsageEffectivelyEnabled(for: provider)
        else { return }
        if let task = self.crossHostUsageTasks[provider] {
            _ = try? await task.value
            return
        }
        let now = Date()
        if !force, self.crossHostUsageSnapshot(for: provider) != nil,
           let ttl = self.tokenFetchTTL, let last = self.crossHostUsageLastFetch[provider],
           now.timeIntervalSince(last) < ttl
        {
            return
        }
        let scope = self.currentCrossHostUsageScope
        let token = UUID()
        let calendar = self.settings.costUsageBucketCalendar
        let selectedDays = max(1, min(365, self.settings.costReportingPeriod.days(now: now, calendar: calendar)))
        let override = self._test_crossHostUsageCollector
        self.crossHostUsageRefreshTokens[provider] = token
        self.crossHostUsageStageStorage[provider] = ["local": "reading", scope.host: "reading"]
        self.crossHostUsageLastFetch[provider] = now
        let task = Task.detached(priority: .utility) { [weak self] in
            let report = if let override {
                try await override(provider, scope.host, 365, calendar, now)
            } else {
                try await UsageLedgerCollector.collect(
                    provider: provider,
                    host: scope.host,
                    historyDays: 365,
                    calendar: calendar,
                    now: now,
                    progress: { [weak self] source, stage in
                        Task { @MainActor [weak self] in
                            guard let self, self.currentCrossHostUsageScope == scope,
                                  self.crossHostUsageRefreshTokens[provider] == token else { return }
                            self.crossHostUsageStageStorage[provider, default: [:]][source] = stage
                        }
                    })
            }
            try Task.checkCancellation()
            let snapshot = report.reports.contains { $0.ledger != nil }
                ? try UsageLedgerMerger.tokenSnapshot(report: report) : nil
            let menuSnapshot = snapshot == nil ? nil
                : try UsageLedgerMerger.tokenSnapshot(report: report, historyDays: selectedDays)
            let result = CrossHostUsageLoadResult(report: report, snapshot: snapshot, menuSnapshot: menuSnapshot)
            await self?.publishCrossHostUsageResult(
                result, provider: provider, scope: scope, token: token, selectedDays: selectedDays)
            return result
        }
        self.crossHostUsageTasks[provider] = task
        defer {
            if self.crossHostUsageRefreshTokens[provider] == token {
                self.crossHostUsageRefreshTokens.removeValue(forKey: provider)
                self.crossHostUsageTasks.removeValue(forKey: provider)
            }
        }
        do {
            _ = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch {
            guard self.currentCrossHostUsageScope == scope, self.crossHostUsageRefreshTokens[provider] == token else {
                return
            }
            self.crossHostUsageLastFetch.removeValue(forKey: provider)
            if Task.isCancelled || error is CancellationError { return }
            self.crossHostUsageReportStorage.removeValue(forKey: provider)
            self.crossHostUsageSnapshots.removeValue(forKey: provider)
            self.crossHostUsageMenuSnapshots.removeValue(forKey: provider)
            self.crossHostUsageErrorStorage[provider] = L("Usage history unavailable")
            self.crossHostUsagePublicationRevision &+= 1
            self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
            self.persistWidgetSnapshot(reason: "cross-host-usage-unavailable")
        }
    }

    /// Publish inside the shared task so every joined refresh observes its result before returning.
    private func publishCrossHostUsageResult(
        _ result: CrossHostUsageLoadResult,
        provider: UsageProvider,
        scope: CrossHostUsageScope,
        token: UUID,
        selectedDays: Int)
    {
        guard !Task.isCancelled, self.currentCrossHostUsageScope == scope,
              self.crossHostUsageRefreshTokens[provider] == token,
              self.isEnabled(provider), self.settings.isCostUsageEffectivelyEnabled(for: provider)
        else { return }
        self.crossHostUsageReportStorage[provider] = result.report
        self.crossHostUsageSnapshots[provider] = result.snapshot
        var menuSnapshot = result.menuSnapshot
        menuSnapshot?.historyLabel = L("This Mac + %@ · Last %d days", scope.host, selectedDays)
        self.crossHostUsageMenuSnapshots[provider] = menuSnapshot
        self.crossHostUsageErrorStorage[provider] = result.snapshot == nil ? L("Usage history unavailable") : nil
        self.crossHostUsagePublicationRevision &+= 1
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
        self.persistWidgetSnapshot(reason: "cross-host-usage")
    }
}
