import Foundation

public struct UsageLedgerHostReport: Codable, Sendable {
    public var host: String
    public var ledger: UsageLedger?
    public var error: String?

    public init(host: String, ledger: UsageLedger?, error: String? = nil) {
        self.host = host
        self.ledger = ledger
        self.error = error
    }
}

public struct UsageLedgerCombinedTotals: Codable, Sendable {
    public var totalTokens: Int
    /// Unavailable if any accepted record has unknown or conflicting pricing.
    public var costUSD: Double?
    /// Known priced subtotal; unknown prices remain explicitly excluded.
    public var pricedCostUSD: Double?
    public var duplicateCount: Int
    public var conflictCount: Int
    public var unidentifiedCount: Int
    /// Legacy observations withheld before accounting; copies are counted separately because their identities are weak.
    public var legacyIdentityCount: Int
    public var unpricedCount: Int
    public var coverageIsEstablished: Bool
}

public struct CombinedUsageLedgerReport: Codable, Sendable {
    public var provider: String
    public var reports: [UsageLedgerHostReport]
    public var combined: UsageLedgerCombinedTotals
}

extension UsageLedger {
    public static let maximumRecords = 100_000
    public static let maximumOutputBytes = 32 * 1024 * 1024

    /// Reject incompatible windows, overflows and malformed remote data before accounting.
    public func validate(provider: String, historyDays: Int) throws {
        let dateLimit: Int64 = 253_402_300_799_000
        // Provider-specific by design: Schema one defines native Codex and Claude token accounting only.
        guard self.schemaVersion == 1, ["codex", "claude"].contains(provider), self.provider == provider,
              (1...365).contains(historyDays), self.historyDays == historyDays,
              TimeZone(identifier: self.bucketTimeZone) != nil,
              self.updatedAt.timeIntervalSince1970.isFinite,
              (0...Double(dateLimit) / 1000).contains(self.updatedAt.timeIntervalSince1970),
              self.windowStartUnixMs >= 0, self.windowEndUnixMs >= self.windowStartUnixMs,
              self.windowEndUnixMs <= dateLimit, self.records.count <= Self.maximumRecords,
              self.incompleteRequestCount >= 0,
              (self.conflictingRecordIDs?.count ?? 0) <= Self.maximumRecords,
              (self.conflictingRecordIDs ?? []).allSatisfy(Self.isDigest),
              Set(self.conflictingRecordIDs ?? []).count == (self.conflictingRecordIDs?.count ?? 0),
              self.warnings.count <= 20,
              self.warnings.allSatisfy({ $0.utf8.count <= 512 })
        else { throw UsageLedgerError.invalid("Invalid or unsupported usage ledger.") }
        for row in self.records {
            // Provider-specific by design: Codex cache reads are a subset of its inclusive input token count.
            guard Self.isDigest(row.id), row.sessionID.map(Self.isDigest) ?? true,
                  (self.windowStartUnixMs...self.windowEndUnixMs).contains(row.timestampUnixMs),
                  Self.isIdentifier(row.model), row.pricingModel.map(Self.isIdentifier) ?? true,
                  row.pricingMode.map(Self.isIdentifier) ?? true,
                  [
                      row.inputTokens,
                      row.cacheReadTokens,
                      row.cacheWriteTokens,
                      row.cacheWrite1hTokens,
                      row.outputTokens,
                      row.totalTokens,
                  ].allSatisfy({ $0 >= 0 }),
                  row.reasoningTokens.map({ $0 >= 0 }) ?? true,
                  row.cacheWrite1hTokens <= row.cacheWriteTokens,
                  provider != "codex" || row.cacheReadTokens <= row.inputTokens,
                  row.costUSD.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  row.identity != .legacyEvent || row.sessionID != nil
            else { throw UsageLedgerError.invalid("Invalid usage ledger record.") }
            // Provider-specific by design: Codex input includes cached tokens; Claude counts cache categories
            // separately.
            let components = provider == "codex"
                ? [row.inputTokens, row.outputTokens]
                : [row.inputTokens, row.outputTokens, row.cacheReadTokens, row.cacheWriteTokens]
            guard try Self.checkedSum(components) == row.totalTokens else {
                throw UsageLedgerError.invalid("Invalid native token total.")
            }
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func checkedSum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { sum, value in
            let next = sum.addingReportingOverflow(value)
            guard !next.overflow else { throw UsageLedgerError.invalid("Usage token total overflow.") }
            return next.partialValue
        }
    }
}

public enum UsageLedgerMerger {
    /// Union provider request identities before summing. Contradictions and weaker identities remain withheld.
    public static func merge(
        reports: [UsageLedgerHostReport], provider: String, historyDays: Int) throws -> CombinedUsageLedgerReport
    {
        try self.accounting(reports: reports, provider: provider, historyDays: historyDays).report
    }

    /// Shares the accepted identity union with dashboard projection so totals cannot diverge.
    static func accounting(
        reports: [UsageLedgerHostReport], provider: String, historyDays: Int)
        throws -> (report: CombinedUsageLedgerReport, rows: [UsageLedgerRecord])
    {
        // Provider-specific by design: Only Codex and Claude native exports satisfy this merger token contract.
        guard ["codex", "claude"].contains(provider), (1...365).contains(historyDays) else {
            throw UsageLedgerError.invalid("Invalid usage ledger request.")
        }
        let ledgers = reports.compactMap(\.ledger)
        for ledger in ledgers {
            try ledger.validate(provider: provider, historyDays: historyDays)
        }
        if let first = ledgers.first {
            guard ledgers.allSatisfy({
                $0.windowStartUnixMs == first.windowStartUnixMs && $0.windowEndUnixMs == first.windowEndUnixMs
                    && $0.bucketTimeZone == first.bucketTimeZone
            }) else { throw UsageLedgerError.invalid("Usage ledgers have different reporting windows.") }
        }
        var conflicts = Set(ledgers.flatMap { $0.conflictingRecordIDs ?? [] })
        var unique: [String: UsageLedgerRecord] = [:]
        var priceConflicts = Set<String>()
        var duplicates = 0
        var unidentified = 0
        var legacy = 0
        for ledger in ledgers {
            for row in ledger.records {
                // Event indices and fallback identities can change between copies; only request IDs establish a union.
                guard row.identity == .request else {
                    if row.identity == .legacyEvent {
                        legacy += 1
                    } else {
                        unidentified += 1
                    }
                    continue
                }
                if conflicts.contains(row.id) { continue }
                guard var existing = unique[row.id] else {
                    unique[row.id] = row
                    continue
                }
                guard Self.sameUsage(existing, row) else {
                    unique.removeValue(forKey: row.id)
                    conflicts.insert(row.id)
                    continue
                }
                duplicates += 1
                if existing.costUSD != row.costUSD || existing.costProvenance != row.costProvenance
                    || existing.pricingModel != row.pricingModel || existing.pricingMode != row.pricingMode
                {
                    priceConflicts.insert(row.id)
                }
                // Response snapshots may carry different observation times. Identity and usage
                // establish the copy; use the earliest observation for deterministic attribution.
                existing.timestampUnixMs = min(existing.timestampUnixMs, row.timestampUnixMs)
                unique[row.id] = existing
            }
        }
        let rows = unique.values.sorted { $0.id < $1.id }.map { value in
            var row = value
            if priceConflicts.contains(row.id) {
                row.costUSD = nil
                row.costProvenance = .unknown
            }
            return row
        }
        let unpriced = rows.filter { $0.costUSD == nil }.count
        let tokens = try UsageLedger.checkedSum(rows.map(\.totalTokens))
        let complete = !reports.isEmpty && reports.allSatisfy { $0.ledger != nil && $0.error == nil }
            && ledgers.allSatisfy { $0.coverageIsEstablished && $0.incompleteRequestCount == 0 }
            && conflicts.isEmpty && unidentified == 0 && legacy == 0
        let cost = unpriced == 0 && (!rows.isEmpty || complete)
            ? rows.reduce(0.0) { $0 + ($1.costUSD ?? 0) } : nil
        let pricedRows = rows.compactMap(\.costUSD)
        let subtotal = !pricedRows.isEmpty || (rows.isEmpty && complete) ? pricedRows.reduce(0, +) : nil
        guard cost.map(\.isFinite) ?? true, subtotal.map(\.isFinite) ?? true else {
            throw UsageLedgerError.invalid("Usage cost total overflow.")
        }
        let report = CombinedUsageLedgerReport(
            provider: provider,
            reports: reports,
            combined: .init(
                totalTokens: tokens,
                costUSD: cost,
                pricedCostUSD: subtotal,
                duplicateCount: duplicates,
                conflictCount: conflicts.count,
                unidentifiedCount: unidentified,
                legacyIdentityCount: legacy,
                unpricedCount: unpriced,
                coverageIsEstablished: complete))
        return (report, rows)
    }

    private static func sameUsage(_ lhs: UsageLedgerRecord, _ rhs: UsageLedgerRecord) -> Bool {
        lhs.model == rhs.model
            && lhs.inputTokens == rhs.inputTokens && lhs.cacheReadTokens == rhs.cacheReadTokens
            && lhs.cacheWriteTokens == rhs.cacheWriteTokens && lhs.cacheWrite1hTokens == rhs.cacheWrite1hTokens
            && lhs.outputTokens == rhs.outputTokens && lhs.reasoningTokens == rhs.reasoningTokens
            && lhs.totalTokens == rhs.totalTokens
    }
}
