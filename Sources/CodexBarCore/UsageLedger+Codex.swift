import Foundation

extension UsageLedgerLoader {
    /// Explicit exports reuse a private native cursor cache and preserve cancellation and conflict evidence.
    public static func loadCodex(
        historyDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current) async throws -> UsageLedger
    {
        let now = Self.canonicalDate(now)
        var options = CostUsageScanner.Options(
            calendar: calendar,
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.cacheRoot = CodexLedgerCache.defaultRoot(options: options)
        return try await self.loadCodex(
            historyDays: historyDays,
            now: now,
            options: options)
    }

    static func loadCodex(
        historyDays: Int,
        now: Date,
        options: CostUsageScanner.Options,
        pricingCacheRoot: URL? = nil) async throws -> UsageLedger
    {
        let now = Self.canonicalDate(now)
        guard (1...365).contains(historyDays) else {
            throw UsageLedgerError.invalid("History must be between 1 and 365 days.")
        }
        return try await CostUsageScanExecutor.run { checkCancellation in
            var options = options
            options.refreshMinIntervalSeconds = 0
            let cacheRoot = options.cacheRoot ?? CodexLedgerCache.defaultRoot(options: options)
            options.cacheRoot = cacheRoot
            let privateCache = try CodexLedgerCache(root: cacheRoot, checkCancellation: checkCancellation)
            defer { privateCache.release() }
            let roots = CostUsageScanner.codexSessionsRoots(options: options)
            guard roots.contains(where: { root in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue && FileManager.default.isReadableFile(atPath: root.path)
            }) else { throw UsageLedgerError.invalid("Native Codex usage history is unavailable.") }
            var inventory = try CodexLedgerCache.inventory(roots: roots, checkCancellation: checkCancellation)
            let previous = try privateCache.prepare(inventory: &inventory, checkCancellation: checkCancellation)
            options.forceRescan = options.forceRescan || previous == nil
            let since = CostReportingPeriod.rolling(days: historyDays)
                .bounds(now: now, calendar: options.calendar).lowerBound
            let observations = CodexLedgerRequestObserver(
                since: since,
                until: now,
                evidence: options.forceRescan ? [:] : previous?.evidence ?? [:])
            try privateCache.beginScan()
            // Provider-specific by design: This adapter reads owned native Codex rollouts before replay suppression.
            _ = try CostUsageScanner.$codexLedgerRequestObserver.withValue(observations) {
                try CostUsageScanner.loadDailyReportCancellable(
                    provider: .codex,
                    since: since,
                    until: now,
                    now: now,
                    options: options,
                    checkCancellation: checkCancellation)
            }
            try checkCancellation()
            let view = CostUsageStoreAccess.readView(
                cacheRoot: options.cacheRoot,
                calendar: options.calendar,
                purpose: .report).scoped(to: roots)
            // The private scan database must not replace the installed, read-only pricing catalog.
            var ledger = view.codexUsageLedger(
                range: .init(since: since, until: now, calendar: options.calendar),
                historyDays: historyDays,
                now: now,
                cacheRoot: pricingCacheRoot,
                rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: options))
            let conflicts = Array(Set((ledger.conflictingRecordIDs ?? []) + observations.conflictingRecordIDs)).sorted()
            if !conflicts.isEmpty {
                ledger.conflictingRecordIDs = conflicts
                ledger.coverageIsEstablished = false
                ledger.warnings
                    .append("Conflicting native Codex request observations were withheld from combined usage.")
            }
            try checkCancellation()
            // Commit the pre-scan inventory: a concurrent append remains visible at the next refresh.
            try privateCache.commit(
                inventory: inventory,
                evidence: observations.evidence,
                checkCancellation: checkCancellation)
            return ledger
        }
    }

    /// Identity excludes mutable token/model payloads so conflicting observations remain detectable.
    static func codexLedger(
        cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        historyDays: Int,
        now: Date,
        source: (cacheRoot: URL?, coverageIsEstablished: Bool)) -> UsageLedger
    {
        let cacheRoot = source.cacheRoot
        let catalog = ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
            ?? ModelsDevCatalog(providers: [:])
        let pricingResolver = CostUsagePricing.CodexResolver(catalog: catalog)
        let customPricing = CostUsageCustomPricing.load()
        let priorityTurns = CostUsageScanner.validatedPriorityTurns(cache: cache, calendar: range.calendar)
        var records: [UsageLedgerRecord] = []
        var warnings: [String] = []
        var coverage = source.coverageIsEstablished
        var missingTimestamp = false
        var redactedModel = false
        var invalidRecordIDs = Set<String>()
        let windowStartUnixMs = CostUsageLocalDay.date(fromKey: range.sinceKey, calendar: range.calendar)
            .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        let windowEndUnixMs = Int64(now.timeIntervalSince1970 * 1000)
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            guard usage.hasCurrentCodexParser else {
                coverage = false
                continue
            }
            for row in usage.codexRows ?? [] {
                guard row.day >= range.sinceKey, row.day <= range.untilKey,
                      OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: row.model)
                else { continue }
                if let timestamp = row.timestampUnixMs,
                   !(windowStartUnixMs...windowEndUnixMs).contains(timestamp)
                {
                    continue
                }
                let identity: UsageLedgerIdentity
                let components: [String]
                // Provider-specific by design: Codex request and legacy identities retain rollout-session provenance.
                if let session = usage.sessionId, let response = row.responseID {
                    identity = .request
                    components = ["codex", "request", session, response]
                } else if let session = usage.sessionId, let timestamp = row.timestampUnixMs,
                          row.turnID != nil || row.eventIndex != nil
                {
                    identity = .legacyEvent
                    components = [
                        "codex", "legacy", session, String(timestamp), row.turnID ?? "",
                        row.eventIndex.map(String.init) ?? "",
                    ]
                } else {
                    identity = .unidentified
                    components = [
                        "codex", "unidentified", path, row.eventIndex.map(String.init) ?? "",
                        row.timestampUnixMs.map(String.init) ?? "",
                    ]
                }
                let id = UsageLedgerRecord.digest(components)
                let total = row.input.addingReportingOverflow(row.output)
                guard !total.overflow, row.input >= 0, row.cached >= 0, row.cached <= row.input, row.output >= 0 else {
                    coverage = false
                    invalidRecordIDs.insert(id)
                    continue
                }
                // Missing timestamps retain the native day bucket without inventing request identity.
                let timestamp = row.timestampUnixMs
                    ?? CostUsageLocalDay.date(fromKey: row.day, calendar: range.calendar)
                    .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                missingTimestamp = missingTimestamp || row.timestampUnixMs == nil
                let cost = (row.unpricedTokens ?? 0) == 0 ? CostUsageScanner.codexResolvedCostUSD(
                    for: row,
                    priorityTurns: priorityTurns,
                    modelsDevCatalog: catalog,
                    modelsDevCacheRoot: cacheRoot,
                    customPricing: customPricing,
                    pricingResolver: pricingResolver) : nil
                let priority = row.turnID.flatMap { priorityTurns[$0] }
                let pricingModel = priority.map {
                    CostUsageScanner.codexPriorityPricingModel(for: row, priorityMetadata: $0)
                } ?? row.pricingModel ?? row.model
                let exportedModel = Self.codexLedgerModel(row.model)
                let exportedPricingModel = Self.codexLedgerModel(pricingModel)
                redactedModel = redactedModel || exportedModel != row.model || exportedPricingModel != pricingModel
                // Provider-specific by design: Codex session digests must not collide with Claude transcript
                // namespaces.
                records.append(UsageLedgerRecord(
                    id: id,
                    sessionID: usage.sessionId.map { UsageLedgerRecord.digest(["codex", "session", $0]) },
                    identity: identity,
                    timestampUnixMs: timestamp,
                    model: exportedModel,
                    inputTokens: row.input,
                    cacheReadTokens: row.cached,
                    outputTokens: row.output,
                    totalTokens: total.partialValue,
                    costUSD: cost,
                    reasoningTokens: row.reasoning,
                    costProvenance: cost == nil ? .unknown
                        : row.knownCostNanos == nil ? .listPriceEstimate : .vendorMetered,
                    pricingModel: exportedPricingModel,
                    pricingMode: priority != nil || row.pricingMode == "priority" ? "priority" : "standard"))
            }
        }
        if !invalidRecordIDs.isEmpty {
            warnings.append("Invalid native token counts were excluded and their identities were withheld.")
        }
        if records.contains(where: { $0.identity == .legacyEvent }) {
            warnings.append("Legacy Codex events lack provider request IDs; matching relies on rollout provenance.")
        }
        if records.contains(where: { $0.identity == .unidentified }) {
            warnings.append("Some Codex records lack stable identity and cannot be deduplicated across hosts.")
        }
        if missingTimestamp {
            coverage = false
            warnings.append("Some Codex records have only a day bucket; their timestamp is the native day's start.")
        }
        if redactedModel {
            warnings.append("Non-identifier model metadata was redacted from the numeric export.")
        }
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: catalog,
            modelsDevCacheRoot: cacheRoot,
            priorityTurns: priorityTurns)
        let exportedTokens = CheckedSum.integers(records.map(\.totalTokens))
        let nativeTokens = CheckedSum.integers(report.data.compactMap(\.totalTokens))
        if exportedTokens == nil || nativeTokens == nil || exportedTokens != nativeTokens {
            coverage = false
            warnings.append("Exported Codex records do not reconcile with native totals; coverage is partial.")
        }
        let unresolved = CheckedSum.integers(
            Array(CostUsageScanner.unresolvedForkUnmeteredCounts(cache: cache, range: range).values)) ?? 0
        if unresolved > 0 {
            coverage = false
            warnings.append("Fork usage with an unavailable parent baseline remains unmetered.")
        }
        if !coverage {
            warnings.append("Native Codex history coverage is incomplete; exported usage is partial.")
        }
        // Provider-specific by design: This adapter exports the native Codex rollout schema only.
        var ledger = UsageLedger(
            provider: "codex",
            updatedAt: Date(),
            historyDays: historyDays,
            bucketTimeZone: range.calendar.timeZone.identifier,
            coverageIsEstablished: coverage,
            records: records,
            incompleteRequestCount: CheckedSum.integers([unresolved, invalidRecordIDs.count]) ?? Int.max,
            warnings: Array(Set(warnings)).sorted())
        if !invalidRecordIDs.isEmpty {
            ledger.conflictingRecordIDs = invalidRecordIDs.sorted()
        }
        ledger.windowStartUnixMs = windowStartUnixMs
        ledger.windowEndUnixMs = windowEndUnixMs
        return ledger
    }

    /// Rollout-controlled strings must be model identifiers, never arbitrary paths or text.
    private static func codexLedgerModel(_ raw: String) -> String {
        let model = CostUsagePricing.normalizeCodexModel(raw)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !model.isEmpty, model.utf8.count <= 128,
              model.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return CostUsagePricing.codexUnattributedModel }
        return model
    }
}
