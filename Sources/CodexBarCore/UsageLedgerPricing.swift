import Foundation

/// Uses the installed pricing catalog without reading histories, refreshing prices, or changing usage identities.
public enum UsageLedgerPricing {
    /// Fill missing API-rate estimates locally; metered and existing estimated costs retain their provenance.
    public static func repriceMissing(_ ledger: UsageLedger, now: Date = Date()) -> UsageLedger {
        guard ledger.records.contains(where: { $0.costUSD == nil }) else { return ledger }
        let catalog = ModelsDevCache.load(now: now).artifact?.catalog ?? ModelsDevCatalog(providers: [:])
        return Self.repriceMissing(ledger, catalog: catalog)
    }

    /// An explicit immutable catalog keeps tests and a multi-host collection independent of cache writes.
    static func repriceMissing(_ ledger: UsageLedger, catalog: ModelsDevCatalog) -> UsageLedger {
        // Provider-specific by design: Native Claude and Codex define different input/cache token contracts.
        guard ["codex", "claude"].contains(ledger.provider) else { return ledger }
        let codexResolver = CostUsagePricing.CodexResolver(catalog: catalog)
        var result = ledger
        var repriced = false
        for index in result.records.indices where result.records[index].costUSD == nil {
            let row = result.records[index]
            let model = row.pricingModel ?? row.model
            guard model != "unknown", model != "codex-auto-review" else { continue }
            let date = Date(timeIntervalSince1970: Double(row.timestampUnixMs) / 1000)
            let cost: Double?
            // Provider-specific by design: Claude input excludes cache reads; Codex input includes them.
            switch ledger.provider {
            case "claude":
                guard row.pricingMode == nil || row.pricingMode == "standard",
                      let lookup = catalog.pricing(providerID: "anthropic", modelID: model, exactModelID: true)
                else { continue }
                let calculated = CostUsagePricing.claudeCostUSD(
                    pricing: lookup.pricing,
                    tokens: .init(
                        input: row.inputTokens,
                        cacheRead: row.cacheReadTokens,
                        cacheCreation: row.cacheWriteTokens,
                        cacheCreation1h: row.cacheWrite1hTokens,
                        output: row.outputTokens))
                // Match the native Claude scanner's nanodollar rounding so copies retain identical prices.
                cost = Int64(exactly: (calculated * 1_000_000_000).rounded())
                    .map { Double($0) / 1_000_000_000 }
            // Provider-specific by design: Codex native pricing retains its standard/Fast and context rules.
            case "codex":
                guard row.pricingMode == "standard" || row.pricingMode == "priority" else { continue }
                cost = row.pricingMode == "priority"
                    ? CostUsagePricing.codexPriorityCostUSD(
                        model: model,
                        inputTokens: row.inputTokens,
                        cachedInputTokens: row.cacheReadTokens,
                        outputTokens: row.outputTokens,
                        pricingDate: date,
                        modelsDevCatalog: catalog,
                        pricingResolver: codexResolver)
                    : CostUsagePricing.codexCostUSD(
                        model: model,
                        inputTokens: row.inputTokens,
                        cachedInputTokens: row.cacheReadTokens,
                        outputTokens: row.outputTokens,
                        pricingDate: date,
                        modelsDevCatalog: catalog,
                        pricingResolver: codexResolver)
            default:
                continue
            }
            guard let cost, cost.isFinite, cost >= 0 else { continue }
            result.records[index].costUSD = cost
            result.records[index].costProvenance = .listPriceEstimate
            result.records[index].pricingModel = model
            repriced = true
        }
        if repriced, result.warnings.count < 20 {
            result.warnings.append("Missing API-rate estimates were resolved using this machine's local pricing data.")
        }
        return result
    }
}
