import Foundation

extension UsageLedgerMerger {
    /// Projects the same accepted identity union into native dashboard buckets, excluding unknown prices.
    /// Narrower periods are filtered after deduplication, preserving deterministic copy attribution.
    public static func tokenSnapshot(
        report: CombinedUsageLedgerReport, historyDays: Int? = nil) throws -> CostUsageTokenSnapshot
    {
        guard let first = report.reports.compactMap(\.ledger).first else {
            throw UsageLedgerError.invalid("No native usage history is available.")
        }
        let days = historyDays ?? first.historyDays
        guard (1...first.historyDays).contains(days) else {
            throw UsageLedgerError.invalid("Requested history is outside the collected window.")
        }
        let accounting = try Self.accounting(
            reports: report.reports, provider: report.provider, historyDays: first.historyDays)
        let calendar = CostUsageBucketTimeZone.calendar(identifier: first.bucketTimeZone)
        let end = Date(timeIntervalSince1970: Double(first.windowEndUnixMs) / 1000)
        guard let start = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: end)) else {
            throw UsageLedgerError.invalid("Invalid dashboard reporting window.")
        }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let rows = accounting.rows.filter { $0.timestampUnixMs >= startMs }
        let todayMs = Int64(calendar.startOfDay(for: end).timeIntervalSince1970 * 1000)
        let today = rows.filter { $0.timestampUnixMs >= todayMs }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let buckets = Dictionary(grouping: rows) {
            formatter.string(from: Date(timeIntervalSince1970: Double($0.timestampUnixMs) / 1000))
        }
        let daily = try buckets.keys.sorted().map { key in
            let entries = buckets[key] ?? []
            let models = Dictionary(grouping: entries, by: \.model)
            let breakdowns = try models.keys.sorted().map { name in
                let values = models[name] ?? []
                return try CostUsageDailyReport.ModelBreakdown(
                    modelName: name,
                    costUSD: Self.pricedSubtotal(values),
                    totalTokens: UsageLedger.checkedSum(values.map(\.totalTokens)),
                    requestCount: values.count,
                    inputTokens: UsageLedger
                        .checkedSum(values.map { Self.uncachedInput($0, provider: report.provider) }),
                    outputTokens: UsageLedger.checkedSum(values.map(\.outputTokens)),
                    cacheReadTokens: UsageLedger.checkedSum(values.map(\.cacheReadTokens)),
                    cacheCreationTokens: UsageLedger.checkedSum(values.map(\.cacheWriteTokens)),
                    reasoningTokens: UsageLedger.checkedSum(values.compactMap(\.reasoningTokens)))
            }
            return try CostUsageDailyReport.Entry(
                date: key,
                inputTokens: UsageLedger.checkedSum(entries.map { Self.uncachedInput($0, provider: report.provider) }),
                outputTokens: UsageLedger.checkedSum(entries.map(\.outputTokens)),
                cacheReadTokens: UsageLedger.checkedSum(entries.map(\.cacheReadTokens)),
                cacheCreationTokens: UsageLedger.checkedSum(entries.map(\.cacheWriteTokens)),
                reasoningTokens: UsageLedger.checkedSum(entries.compactMap(\.reasoningTokens)),
                totalTokens: UsageLedger.checkedSum(entries.map(\.totalTokens)),
                requestCount: entries.count,
                costUSD: Self.pricedSubtotal(entries),
                modelsUsed: models.keys.sorted(),
                modelBreakdowns: breakdowns,
                unpricedRequestCount: entries.filter { $0.costUSD == nil }.count,
                unmeteredRequestCount: 0,
                estimatedRequestCount: entries.filter {
                    $0.costUSD != nil && $0.costProvenance == .listPriceEstimate
                }.count,
                pricedRequestCount: entries.filter {
                    $0.costUSD != nil && $0.costProvenance != .listPriceEstimate
                }.count)
        }
        let coverage = accounting.report.combined.coverageIsEstablished
        let partial = !coverage || rows.contains { $0.costUSD == nil }
        let provenances = Set(rows.filter { $0.costUSD != nil }.map(\.costProvenance))
        let provenance: CostProvenance = provenances.count == 1 ? (provenances.first ?? .unknown)
            : provenances.contains(.unknown) ? .unknown : provenances.isEmpty ? .unknown : .mixed
        return try CostUsageTokenSnapshot(
            sessionTokens: UsageLedger.checkedSum(today.map(\.totalTokens)),
            sessionCostUSD: Self.pricedSubtotal(today, knownEmpty: coverage),
            sessionRequests: today.count,
            last30DaysTokens: UsageLedger.checkedSum(rows.map(\.totalTokens)),
            last30DaysCostUSD: Self.pricedSubtotal(rows, knownEmpty: coverage),
            last30DaysRequests: rows.count,
            historyDays: days,
            historyCoverageIsEstablished: coverage,
            historyScanIsPartial: partial,
            historyLabel: "This Mac + SSH: recorded subtotal (\(days) days)",
            meteredCostUSD: Self.pricedSubtotal(rows.filter { $0.costProvenance == .vendorMetered }),
            costProvenance: provenance,
            daily: daily,
            updatedAt: end)
    }

    private static func uncachedInput(_ row: UsageLedgerRecord, provider: String) -> Int {
        // Provider-specific by design: Codex input includes cache reads; dashboard token mix separates them.
        provider == "codex" ? max(0, row.inputTokens - row.cacheReadTokens) : row.inputTokens
    }

    private static func pricedSubtotal(_ rows: [UsageLedgerRecord], knownEmpty: Bool = false) throws -> Double? {
        let values = rows.compactMap(\.costUSD)
        guard !values.isEmpty || (rows.isEmpty && knownEmpty) else { return nil }
        let subtotal = values.reduce(0, +)
        guard subtotal.isFinite else { throw UsageLedgerError.invalid("Usage cost total overflow.") }
        return subtotal
    }
}
