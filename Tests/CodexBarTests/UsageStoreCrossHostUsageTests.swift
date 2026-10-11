import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCrossHostUsageTests {
    @Test
    func `normal refresh publishes combined scopes without account cache writes`() async throws {
        let store = try Self.makeStore()
        store.settings.costUsageHistoryDays = 30
        var widgetSnapshot: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { widgetSnapshot = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store._test_crossHostUsageCollector = { provider, host, days, calendar, now in
            #expect(host == "rambo")
            #expect(days == 365)
            return try Self.report(provider: provider, host: host, calendar: calendar, now: now)
        }
        await store.refreshTokenUsage(.codex, force: true)
        await store.widgetSnapshotPersistTask?.value
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 100)
        #expect(store.crossHostUsageSnapshot(for: .codex)?.last30DaysTokens == 150)
        #expect(store.tokenSnapshotPublications.isEmpty)
        #expect(store.spendDashboardTokenPublications.isEmpty)
        let input = store.menuCardInput(for: .codex, context: .menu, now: Date())
        #expect(input.tokenSnapshot?.last30DaysTokens == 100)
        let request = await SpendDashboardSource.makeRequest(
            settings: store.settings, store: store, mode: .captureOnly)
        #expect(request.codexRequests.isEmpty)
        #expect(request.capturedInputs.count == 1)
        #expect(request.capturedInputs.first?.snapshot.last30DaysTokens == 150)
        #expect(store.crossHostUsageReports[.codex]?.combined.duplicateCount == 1)
        let widget = try #require(widgetSnapshot?.entries.first { $0.provider == .codex })
        #expect(widget.tokenUsage?.last30DaysTokens == 100)
        #expect(widget.tokenUsage?.last30DaysCostUSD == 1)
        #expect(widget.dailyUsage.compactMap(\.totalTokens).reduce(0, +) == 100)
    }

    @Test
    func `dashboard capture joining a normal refresh observes its publication before returning`() async throws {
        let store = try Self.makeStore()
        let gate = SpendDashboardPendingLoads<CombinedUsageLedgerReport>()
        defer { gate.close() }
        store._test_crossHostUsageCollector = { _, _, _, _, _ in try await gate.load() }
        let refresh = Task { await store.refreshTokenUsage(.codex, force: true) }
        try await gate.waitForPendingCount(1)
        let started = AsyncStream<Void>.makeStream()
        let dashboard = Task {
            started.continuation.yield(())
            started.continuation.finish()
            await store.refreshCrossHostUsage(for: .codex, force: true)
            return await SpendDashboardSource.makeRequest(
                settings: store.settings, store: store, mode: .captureOnly)
        }
        // The actor cannot resume this consumer until the joined refresh has suspended on the shared task.
        for await _ in started.stream {
            break
        }
        #expect(gate.pendingCount == 1)
        try gate.resume(returning: Self.report(
            provider: .codex, host: "rambo", calendar: store.settings.costUsageBucketCalendar, now: Date()))
        let request = await dashboard.value
        #expect(request.capturedInputs.count == 1)
        #expect(request.capturedInputs.first?.snapshot.last30DaysTokens == 150)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 100)
        await refresh.value
    }

    @Test
    func `changing a host retires pending work and never exposes its late result`() async throws {
        let store = try Self.makeStore()
        store._setSnapshotForTesting(UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), provider: .codex)
        var widgetSnapshot: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { widgetSnapshot = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store._test_crossHostUsageCollector = { provider, host, _, calendar, now in
            try Self.report(provider: provider, host: host, calendar: calendar, now: now)
        }
        await store.refreshTokenUsage(.codex, force: true)
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshot?.entries.first { $0.provider == .codex }?.tokenUsage?.last30DaysTokens == 100)
        store.installCachedTokenSnapshot(CostUsageTokenSnapshot(
            sessionTokens: 999,
            sessionCostUSD: 9,
            last30DaysTokens: 999,
            last30DaysCostUSD: 9,
            daily: [],
            updatedAt: Date()), for: .codex)
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysTokens == 999)
        let gate = SpendDashboardPendingLoads<CombinedUsageLedgerReport>()
        defer { gate.close() }
        store._test_crossHostUsageCollector = { _, _, _, _, _ in try await gate.load() }
        let task = Task { await store.refreshTokenUsage(.codex, force: true) }
        try await gate.waitForPendingCount(1)
        try store.settings.setCrossHostUsageHost("replacement")
        #expect(store.crossHostUsageReports.isEmpty)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        store.synchronizeCrossHostUsageConfiguration()
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshot?.entries.first { $0.provider == .codex }?.tokenUsage == nil)
        #expect(widgetSnapshot?.entries.first { $0.provider == .codex }?.dailyUsage.isEmpty == true)
        try gate.resume(returning: Self.report(
            provider: .codex, host: "rambo", calendar: store.settings.costUsageBucketCalendar, now: Date()))
        await task.value
        #expect(store.crossHostUsageReports.isEmpty)
        #expect(store.crossHostUsageRefreshing.isEmpty)
        store._test_crossHostUsageCollector = { provider, host, _, calendar, now in
            try Self.report(provider: provider, host: host, calendar: calendar, now: now)
        }
        await store.refreshTokenUsage(.codex, force: true)
        #expect(store.crossHostUsageReports[.codex]?.reports.last?.host == "replacement")
    }

    @Test
    func `cancelled refresh drains its child and does not publish or report a failure`() async throws {
        let store = try Self.makeStore()
        let gate = SpendDashboardPendingLoads<CombinedUsageLedgerReport>()
        defer { gate.close() }
        store._test_crossHostUsageCollector = { _, _, _, _, _ in try await gate.load() }
        let task = Task { await store.refreshTokenUsage(.codex, force: true) }
        try await gate.waitForPendingCount(1)
        task.cancel()
        try gate.resume(returning: Self.report(
            provider: .codex, host: "rambo", calendar: store.settings.costUsageBucketCalendar, now: Date()))
        await task.value
        #expect(store.crossHostUsageRefreshing.isEmpty)
        #expect(store.crossHostUsageReports.isEmpty)
        #expect(store.tokenError(for: .codex) == nil)
    }

    @Test
    func `remote failure publishes partial local usage and total source failure never becomes zero`() async throws {
        let store = try Self.makeStore()
        store._setSnapshotForTesting(UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), provider: .codex)
        var widgetSnapshot: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { widgetSnapshot = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store._test_crossHostUsageCollector = { provider, host, _, calendar, now in
            try Self.report(provider: provider, host: host, calendar: calendar, now: now, remoteAvailable: false)
        }
        await store.refreshTokenUsage(.codex, force: true)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 100)
        #expect(store.tokenSnapshot(for: .codex)?.historyScanIsPartial == true)
        #expect(store.crossHostUsageReports[.codex]?.combined.coverageIsEstablished == false)
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshot?.entries.first { $0.provider == .codex }?.tokenUsage?.last30DaysTokens == 100)
        store._test_crossHostUsageCollector = { _, _, _, _, _ in throw CocoaError(.fileReadUnknown) }
        await store.refreshTokenUsage(.codex, force: true)
        await store.widgetSnapshotPersistTask?.value
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(widgetSnapshot?.entries.first { $0.provider == .codex }?.tokenUsage == nil)
        store._test_crossHostUsageCollector = { _, host, _, _, _ in
            try UsageLedgerMerger.merge(
                reports: [
                    .init(host: "local", ledger: nil, error: "missing"),
                    .init(host: host, ledger: nil, error: "missing"),
                ],
                provider: "codex",
                historyDays: 365)
        }
        await store.refreshTokenUsage(.codex, force: true)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenError(for: .codex) != nil)
        store.settings.refreshFrequency = .manual
        store._test_crossHostUsageCollector = { _, _, _, _, _ in
            Issue.record("Capturing an existing unavailable source must not create a new SSH refresh loop")
            throw CancellationError()
        }
        await store.refreshCrossHostUsageForDashboard(providers: [.codex], mode: .refreshMissing)
        #expect(store.tokenError(for: .codex) != nil)
    }

    private static func makeStore() throws -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreCrossHostUsage",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(ProviderRegistry.shared.metadata[.codex]),
            enabled: true)
        try settings.setCrossHostUsageHost("rambo")
        let environment =
            ["CODEX_HOME": FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path]
        settings._test_codexReconciliationEnvironment = environment
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }

    /// One copied request plus an older independent request exercises deduplication and display-window projection.
    private nonisolated static func report(
        provider: UsageProvider,
        host: String,
        calendar: Calendar,
        now: Date,
        remoteAvailable: Bool = true) throws -> CombinedUsageLedgerReport
    {
        let now = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded() / 1000)
        let name = provider == .codex ? "codex" : "claude"
        let shared = UsageLedgerRecord(
            id: UsageLedgerRecord.digest(["shared"]),
            sessionID: UsageLedgerRecord.digest(["session"]),
            identity: .request,
            timestampUnixMs: Int64(now.timeIntervalSince1970 * 1000),
            model: "test-model",
            inputTokens: 100,
            cacheReadTokens: 0,
            outputTokens: 0,
            totalTokens: 100,
            costUSD: 1,
            costProvenance: .vendorMetered)
        var older = shared
        older.id = UsageLedgerRecord.digest(["older"])
        older.timestampUnixMs -= 40 * 86400 * 1000
        older.inputTokens = 50
        older.totalTokens = 50
        let local = UsageLedger(
            provider: name,
            updatedAt: now,
            historyDays: 365,
            bucketTimeZone: calendar.timeZone.identifier,
            coverageIsEstablished: true,
            records: [shared])
        var remote = local
        remote.records = [shared, older]
        return try UsageLedgerMerger.merge(
            reports: [
                .init(host: "local", ledger: local),
                .init(
                    host: host,
                    ledger: remoteAvailable ? remote : nil,
                    error: remoteAvailable ? nil : "offline"),
            ],
            provider: name,
            historyDays: 365)
    }
}
