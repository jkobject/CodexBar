import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerPricingTests {
    @Test
    func `exact local Claude pricing restores missing remote cost without changing usage or coverage`() throws {
        let catalog = try self.catalog()
        let record = self.record(model: "claude-fixture", mode: nil)
        let ledger = self.ledger(provider: "claude", records: [record])
        let repriced = UsageLedgerPricing.repriceMissing(ledger, catalog: catalog)
        let priced = try #require(repriced.records.first)
        // 1000 regular, 10000 cache reads, 1000 five-minute writes, 200 one-hour writes, 200 output.
        #expect(try abs(#require(priced.costUSD) - 0.01395) < 0.000000001)
        #expect(priced.costProvenance == .listPriceEstimate)
        #expect(priced.pricingModel == "claude-fixture")
        #expect(priced.pricingMode == nil)
        var restored = priced
        restored.costUSD = record.costUSD
        restored.costProvenance = record.costProvenance
        restored.pricingModel = record.pricingModel
        #expect(restored == record)
        #expect(!repriced.coverageIsEstablished)
        #expect(repriced.conflictingRecordIDs == ledger.conflictingRecordIDs)
        #expect(repriced.warnings.contains { $0.contains("local pricing data") })
    }

    @Test(arguments: ["claude-fixture-private", "unknown", "claude-missing"])
    func `missing Claude pricing does not guess family aliases or substitute another provider`(model: String) throws {
        let repriced = try UsageLedgerPricing.repriceMissing(
            self.ledger(provider: "claude", records: [self.record(model: model, mode: nil)]),
            catalog: self.catalog())
        #expect(repriced.records.first?.costUSD == nil)
        #expect(repriced.records.first?.costProvenance == .unknown)
        #expect(repriced.warnings.isEmpty)
    }

    @Test(arguments: ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"])
    func `documented GPT6 fast modes use double standard rates including long context`(model: String) throws {
        let empty = ModelsDevCatalog(providers: [:])
        for input in [1000, 300_000] {
            let standard = try #require(CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: input,
                cachedInputTokens: 400,
                outputTokens: 200,
                modelsDevCatalog: empty))
            let fast = try #require(CostUsagePricing.codexPriorityCostUSD(
                model: model,
                inputTokens: input,
                cachedInputTokens: 400,
                outputTokens: 200,
                modelsDevCatalog: empty))
            #expect(abs(fast - 2 * standard) < 0.000000001)
        }
    }

    @Test
    func `missing Codex fast estimate uses its native mode and preserves cache subset accounting`() throws {
        var record = self.record(model: "gpt-6.1-sol", mode: "priority")
        record.inputTokens = 1000
        record.cacheReadTokens = 400
        record.cacheWriteTokens = 0
        record.cacheWrite1hTokens = 0
        record.totalTokens = 1200
        let priced = UsageLedgerPricing.repriceMissing(
            self.ledger(provider: "codex", records: [record]), catalog: ModelsDevCatalog(providers: [:]))
        #expect(try abs(#require(priced.records.first?.costUSD) - 0.00648) < 0.000000001)
        #expect(priced.records.first?.totalTokens == 1200)
        #expect(priced.records.first?.pricingMode == "priority")
    }

    @Test(arguments: ["codex-auto-review", "unknown", "unpublished-model"])
    func `unknown Codex base models retain an unavailable cost`(model: String) {
        let priced = UsageLedgerPricing.repriceMissing(
            self.ledger(provider: "codex", records: [self.record(model: model, mode: "priority")]),
            catalog: ModelsDevCatalog(providers: [:]))
        #expect(priced.records.first?.costUSD == nil)
    }

    @Test
    func `existing metered and estimated costs and unsupported modes remain unchanged`() throws {
        var metered = self.record(model: "claude-fixture", mode: nil)
        metered.costUSD = 7
        metered.costProvenance = .vendorMetered
        var estimated = metered
        estimated.costProvenance = .listPriceEstimate
        let unsupported = self.record(model: "claude-fixture", mode: "ultrafast")
        let ledger = self.ledger(provider: "claude", records: [metered, estimated, unsupported])
        let repriced = try UsageLedgerPricing.repriceMissing(ledger, catalog: self.catalog())
        #expect(repriced.records == ledger.records)
        #expect(repriced.warnings.isEmpty)
    }

    private func catalog() throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-fixture": {
                "id": "claude-fixture",
                "cost": { "input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75 }
              }
            }
          },
          "openai": {
            "id": "openai",
            "models": { "claude-missing": { "id": "claude-missing", "cost": { "input": 99, "output": 99 } } }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private func record(model: String, mode: String?) -> UsageLedgerRecord {
        UsageLedgerRecord(
            id: UsageLedgerRecord.digest(["request"]),
            sessionID: UsageLedgerRecord.digest(["session"]),
            identity: .request,
            timestampUnixMs: 1_791_640_800_000,
            model: model,
            inputTokens: 1000,
            cacheReadTokens: 10000,
            cacheWriteTokens: 1200,
            outputTokens: 200,
            totalTokens: 12400,
            costUSD: nil,
            cacheWrite1hTokens: 200,
            pricingMode: mode)
    }

    private func ledger(provider: String, records: [UsageLedgerRecord]) -> UsageLedger {
        UsageLedger(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_791_640_800),
            historyDays: 1,
            bucketTimeZone: "UTC",
            coverageIsEstablished: false,
            records: records,
            conflictingRecordIDs: [UsageLedgerRecord.digest(["quarantined"])])
    }
}
