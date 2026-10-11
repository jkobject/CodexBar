import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerSnapshotTests {
    private static let now = Date(timeIntervalSince1970: 1_791_640_800)
    private static let nowMs = Int64(Self.now.timeIntervalSince1970 * 1000)
    private static let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
    private static let todayMs = Int64(Self.calendar.startOfDay(for: Self.now).timeIntervalSince1970 * 1000)

    @Test
    func `dashboard and merger use one accepted identity union with exclusive price coverage`() throws {
        let estimate = Self.record("estimate")
        var metered = Self.record("metered")
        metered.costUSD = 0.5
        metered.costProvenance = .vendorMetered
        var unknown = Self.record("unknown")
        unknown.costUSD = nil
        unknown.costProvenance = .unknown
        var withheld = Self.record("anonymous")
        withheld.identity = .unidentified
        var legacy = Self.record("legacy")
        legacy.identity = .legacyEvent
        let report = try Self.report([
            Self.ledger([estimate, metered, unknown, withheld, legacy]), Self.ledger([estimate]),
        ])
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report)
        let daily = try #require(snapshot.daily.first)
        #expect(report.combined.totalTokens == 330)
        #expect(report.combined.duplicateCount == 1)
        #expect(report.combined.unidentifiedCount == 1)
        #expect(report.combined.legacyIdentityCount == 1)
        #expect(report.combined.costUSD == nil)
        #expect(report.combined.pricedCostUSD == 0.75)
        #expect(snapshot.last30DaysTokens == report.combined.totalTokens)
        #expect(snapshot.last30DaysCostUSD == report.combined.pricedCostUSD)
        #expect(snapshot.last30DaysRequests == 3)
        #expect(snapshot.costProvenance == .mixed)
        #expect(snapshot.meteredCostUSD == 0.5)
        #expect(snapshot.historyScanIsPartial)
        #expect(daily.coverageCounts == CostUsageCoverageCounts(priced: 1, unpriced: 1, estimated: 1))
        #expect(daily.incompleteRequestCount == 0)
        #expect(daily.requestCount == 3)
        #expect(daily.inputTokens == 240)
        #expect(daily.cacheReadTokens == 60)
        #expect(daily.outputTokens == 30)
        #expect(daily.reasoningTokens == 12)
    }

    @Test(arguments: [UsageLedgerIdentity.legacyEvent, .unidentified])
    func `weak identities cannot become dashboard tokens costs or measured empty usage`(
        identity: UsageLedgerIdentity) throws
    {
        var weak = Self.record("withheld-identity")
        weak.identity = identity
        let report = try Self.report([Self.ledger([weak])])
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.last30DaysRequests == 0)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.meteredCostUSD == nil)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.historyScanIsPartial)
        #expect(!snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `narrow summaries retain mixed provenance without fabricating a metered invoice total`() throws {
        let estimate = Self.record("estimate")
        var metered = Self.record("metered")
        metered.costUSD = 0.5
        metered.costProvenance = .vendorMetered
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: Self.report([Self.ledger([estimate, metered])]))
        let narrow = snapshot.summary(forLastDays: 1, calendar: Self.calendar)
        #expect(narrow.totalCostUSD == 0.75)
        #expect(narrow.provenance == .mixed)
        #expect(narrow.meteredCostUSD == nil)
        #expect(narrow.coverage == CostUsageCoverageCounts(priced: 1, estimated: 1))
        let wide = snapshot.summary(forLastDays: 2, calendar: Self.calendar)
        #expect(wide.provenance == .mixed)
        #expect(wide.meteredCostUSD == 0.5)
    }

    @Test
    func `all unknown prices retain known tokens without turning the subtotal into zero`() throws {
        var row = Self.record("unpriced")
        row.costUSD = nil
        row.costProvenance = .unknown
        let report = try Self.report([Self.ledger([row])])
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report)
        #expect(report.combined.coverageIsEstablished)
        #expect(report.combined.costUSD == nil)
        #expect(report.combined.pricedCostUSD == nil)
        #expect(snapshot.last30DaysTokens == 110)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.costProvenance == .unknown)
        #expect(snapshot.historyScanIsPartial)
        #expect(snapshot.daily.first?.coverageCounts == CostUsageCoverageCounts(unpriced: 1))
    }

    @Test
    func `known zero priced requests remain distinguishable from unknown pricing`() throws {
        var zero = Self.record("known-free")
        zero.costUSD = 0
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: Self.report([Self.ledger([zero])]))
        #expect(snapshot.last30DaysCostUSD == 0)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.historyIsFullyScanned)
        #expect(snapshot.daily.first?.coverageCounts == CostUsageCoverageCounts(estimated: 1))
    }

    @Test
    func `narrow windows deduplicate before filtering and attribute boundary copies deterministically`() throws {
        var earlierCopy = Self.record("copied")
        earlierCopy.timestampUnixMs = Self.todayMs - 1
        var laterCopy = earlierCopy
        laterCopy.timestampUnixMs = Self.todayMs
        var boundary = Self.record("boundary")
        boundary.timestampUnixMs = Self.todayMs
        var end = Self.record("inclusive-end")
        end.timestampUnixMs = Self.nowMs
        let ledgers = [Self.ledger([laterCopy, boundary, end]), Self.ledger([earlierCopy])]
        let report = try Self.report(ledgers)
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report, historyDays: 1)
        let reversed = try UsageLedgerMerger.tokenSnapshot(
            report: Self.report(Array(ledgers.reversed())),
            historyDays: 1)
        #expect(report.combined.totalTokens == 330)
        #expect(snapshot.last30DaysTokens == 220)
        #expect(snapshot.sessionTokens == 220)
        #expect(snapshot.last30DaysCostUSD == 0.5)
        #expect(snapshot.historyDays == 1)
        #expect(snapshot.daily.count == 1)
        #expect(snapshot == reversed)
    }

    @Test
    func `contradictory copies and native quarantines never reappear in a dashboard projection`() throws {
        let original = Self.record("conflicting")
        var contradictory = original
        contradictory.inputTokens += 100
        contradictory.totalTokens += 100
        let clean = Self.record("clean")
        let seeded = Self.record("native-conflict")
        var local = Self.ledger([original, clean])
        local.conflictingRecordIDs = [seeded.id]
        let report = try Self.report([local, Self.ledger([contradictory, seeded])])
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report)
        #expect(report.combined.conflictCount == 2)
        #expect(snapshot.last30DaysTokens == 110)
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysCostUSD == 0.25)
        #expect(snapshot.historyScanIsPartial)
    }

    @Test
    func `pricing disagreement preserves deduplicated tokens and excludes disputed dollars`() throws {
        let first = Self.record("price-conflict")
        var copy = first
        copy.costUSD = 0.5
        let report = try Self.report([Self.ledger([first]), Self.ledger([copy])])
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report)
        #expect(snapshot.last30DaysTokens == 110)
        #expect(snapshot.last30DaysRequests == 1)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.costProvenance == .unknown)
        #expect(snapshot.historyScanIsPartial)
    }

    @Test(arguments: [true, false])
    func `empty scans show zero dollars only when every source is known complete`(complete: Bool) throws {
        let local = Self.ledger([])
        let hosts: [UsageLedgerHostReport] = [
            .init(host: "local", ledger: local),
            .init(
                host: "ssh",
                ledger: complete ? Self.ledger([]) : nil,
                error: complete ? nil : "Fixture source unavailable."),
        ]
        let report = try UsageLedgerMerger.merge(
            reports: hosts,
            provider: "codex",
            historyDays: 2)
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: report)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.last30DaysCostUSD == (complete ? 0 : nil))
        #expect(snapshot.sessionCostUSD == (complete ? 0 : nil))
        #expect(snapshot.historyIsFullyScanned == complete)
        #expect(snapshot.daily.isEmpty)
    }

    @Test
    func `Claude cache categories remain disjoint and are included exactly once`() throws {
        var row = Self.record("claude-cache")
        row.cacheWriteTokens = 30
        row.cacheWrite1hTokens = 5
        row.totalTokens = 160
        let snapshot = try UsageLedgerMerger.tokenSnapshot(report: Self.report(
            [Self.ledger([row], provider: "claude")], provider: "claude"))
        let daily = try #require(snapshot.daily.first)
        #expect(daily.inputTokens == 100)
        #expect(daily.cacheReadTokens == 20)
        #expect(daily.cacheCreationTokens == 30)
        #expect(daily.outputTokens == 10)
        #expect(daily.totalTokens == 160)
    }

    @Test
    func `dashboard rejects unavailable sources invalid narrow periods and malformed future records`() throws {
        let report = try Self.report([Self.ledger([Self.record("valid")])])
        for days in [0, 3] {
            #expect(throws: UsageLedgerError.self) {
                try UsageLedgerMerger.tokenSnapshot(report: report, historyDays: days)
            }
        }
        let unavailable = try UsageLedgerMerger.merge(
            reports: [.init(host: "ssh", ledger: nil, error: "Fixture source unavailable.")],
            provider: "codex",
            historyDays: 2)
        #expect(throws: UsageLedgerError.self) { try UsageLedgerMerger.tokenSnapshot(report: unavailable) }
        var tampered = report
        tampered.reports[0].ledger?.records[0].timestampUnixMs = Self.nowMs + 1
        #expect(throws: UsageLedgerError.self) { try UsageLedgerMerger.tokenSnapshot(report: tampered) }
    }

    private static func record(_ name: String) -> UsageLedgerRecord {
        UsageLedgerRecord(
            id: UsageLedgerRecord.digest([name]),
            sessionID: UsageLedgerRecord.digest(["fixture-session"]),
            identity: .request,
            timestampUnixMs: self.nowMs - 1000,
            model: "fixture-model",
            inputTokens: 100,
            cacheReadTokens: 20,
            outputTokens: 10,
            totalTokens: 110,
            costUSD: 0.25,
            reasoningTokens: 4,
            costProvenance: .listPriceEstimate)
    }

    private static func ledger(_ records: [UsageLedgerRecord], provider: String = "codex") -> UsageLedger {
        UsageLedger(
            provider: provider,
            updatedAt: self.now,
            historyDays: 2,
            bucketTimeZone: "UTC",
            coverageIsEstablished: true,
            records: records)
    }

    private static func report(
        _ ledgers: [UsageLedger],
        provider: String = "codex") throws -> CombinedUsageLedgerReport
    {
        try UsageLedgerMerger.merge(
            reports: ledgers.enumerated().map { .init(host: "fixture-\($0.offset)", ledger: $0.element) },
            provider: provider,
            historyDays: 2)
    }
}
