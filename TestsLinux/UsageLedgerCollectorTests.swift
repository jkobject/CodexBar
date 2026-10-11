import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerCollectorTests {
    actor StartedSources {
        var count = 0

        func arrive() { self.count += 1 }

        func awaitBoth() async throws {
            for _ in 0..<1000 {
                if self.count == 2 { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw UsageLedgerError.invalid("Both readers must start before either finishes.")
        }
    }

    @Test
    func `both sources start concurrently and copies are counted once`() async throws {
        let starts = StartedSources()
        let ledger = Self.ledger()
        let loader: UsageLedgerCollector.Loader = {
            await starts.arrive()
            try await starts.awaitBoth()
            return ledger
        }
        let result = try await UsageLedgerCollector.collect(
            provider: "codex", host: "fixture-ssh", historyDays: 1, local: loader, remote: loader)
        #expect(result.reports.map(\.host) == ["local", "fixture-ssh"])
        #expect(result.combined.totalTokens == 120)
        #expect(result.combined.duplicateCount == 1)
        #expect(result.combined.pricedCostUSD == 1)
    }

    @Test
    func `unavailable SSH preserves usable local history with partial coverage`() async throws {
        let ledger = Self.ledger()
        let result = try await UsageLedgerCollector.collect(
            provider: "codex", host: "fixture-ssh", historyDays: 1,
            local: { ledger }, remote: { throw UsageLedgerError.invalid("fixture unavailable") })
        #expect(result.combined.totalTokens == 120)
        #expect(result.combined.pricedCostUSD == 1)
        #expect(!result.combined.coverageIsEstablished)
        #expect(result.reports[1].ledger == nil)
    }

    @Test
    func `reader cancellation cancels collection instead of publishing an unavailable host`() async throws {
        await #expect(throws: CancellationError.self) {
            try await UsageLedgerCollector.collect(
                provider: "codex", host: "fixture-ssh", historyDays: 1,
                local: { throw CancellationError() }, remote: {
                    try await Task.sleep(for: .seconds(5))
                    return Self.ledger()
                })
        }
    }

    private static func ledger() -> UsageLedger {
        let now = Date(timeIntervalSince1970: 1_788_177_600)
        return .init(
            provider: "codex", updatedAt: now, historyDays: 1, bucketTimeZone: "America/New_York",
            coverageIsEstablished: true, records: [.init(
                id: UsageLedgerRecord.digest(["shared"]), identity: .request,
                timestampUnixMs: Int64(now.timeIntervalSince1970 * 1000), model: "fixture-model",
                inputTokens: 100, cacheReadTokens: 50, outputTokens: 20, totalTokens: 120,
                costUSD: 1, costProvenance: .listPriceEstimate)])
    }
}
