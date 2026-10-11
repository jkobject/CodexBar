import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerCodexCacheTests {
    @Test
    func `warm native exports skip historical parsing and resume only appended requests`() async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = UsageLedgerCodexTests.nativeRequest()
        try fixture.write(records: [request], name: "usage.jsonl")
        let coldBudget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let cold = try await Self.load(fixture, budget: coldBudget)
        #expect(cold.records.count == 1)
        #expect(coldBudget.bytesConsumed > 0)
        let warmBudget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let warm = try await Self.load(fixture, budget: warmBudget)
        #expect(warm.records == cold.records)
        #expect(warm.coverageIsEstablished == cold.coverageIsEstablished)
        #expect(warm.conflictingRecordIDs == cold.conflictingRecordIDs)
        #expect(warmBudget.bytesConsumed < coldBudget.bytesConsumed)
        #expect(warmBudget.bytesConsumed <= 64 * 1024)
        var continuation = request
        var payload = try #require(continuation["payload"] as? [String: Any])
        payload["response_id"] = "response-two"
        continuation["payload"] = payload
        let appendedBytes = try Self.append(continuation, to: fixture.sessions.appendingPathComponent("usage.jsonl"))
        let appendBudget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let resumed = try await Self.load(fixture, budget: appendBudget)
        #expect(resumed.records.count == 2)
        #expect(resumed.records.reduce(0) { $0 + $1.totalTokens } == 220)
        #expect(appendBudget.bytesConsumed == appendedBytes + warmBudget.bytesConsumed)
    }

    @Test
    func `appended contradictions persist across warm exports and replacement removes stale evidence`() async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = UsageLedgerCodexTests.nativeRequest()
        try fixture.write(records: [request], name: "usage.jsonl")
        let clean = try await Self.load(fixture)
        var tokens = UsageLedgerCodexTests.nativeTokens
        tokens["input_tokens"] = 200
        let changed = UsageLedgerCodexTests.nativeRequest(tokens: tokens)
        _ = try Self.append(changed, to: fixture.sessions.appendingPathComponent("usage.jsonl"))
        let conflicted = try await Self.load(fixture)
        #expect(conflicted.conflictingRecordIDs == clean.records.map(\.id))
        #expect(!conflicted.coverageIsEstablished)
        let warm = try await Self.load(fixture)
        #expect(warm.conflictingRecordIDs == conflicted.conflictingRecordIDs)
        let combined = try UsageLedgerMerger.merge(
            reports: [.init(host: "local", ledger: warm), .init(host: "remote", ledger: clean)],
            provider: "codex",
            historyDays: 1)
        #expect(combined.combined.totalTokens == 0)
        #expect(combined.combined.costUSD == nil)
        #expect(combined.combined.conflictCount == 1)
        try fixture.write(records: [request], name: "usage.jsonl")
        let replaced = try await Self.load(fixture)
        #expect(replaced.records == clean.records)
        #expect(replaced.conflictingRecordIDs == nil)
    }

    @Test
    func `deleted copied conflicts are removed and evidence never exports private identifiers`() async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write(records: [UsageLedgerCodexTests.nativeRequest()], name: "clean.jsonl")
        var tokens = UsageLedgerCodexTests.nativeTokens
        tokens["output_tokens"] = 20
        try fixture.write(records: [UsageLedgerCodexTests.nativeRequest(tokens: tokens)], name: "copied.jsonl")
        let conflict = try await Self.load(fixture)
        #expect(conflict.conflictingRecordIDs?.count == 1)
        let root = try #require(fixture.options.cacheRoot)
        let envelope = try JSONDecoder().decode(
            CodexLedgerCache.Envelope.self,
            from: Data(contentsOf: root.appendingPathComponent("request-evidence-v1.json")))
        let evidence = try #require(String(data: envelope.payload, encoding: .utf8))
        for privateValue in ["synthetic-session", "response-one", "turn-one", fixture.sessions.path, "gpt-5"] {
            #expect(!evidence.contains(privateValue))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let stateAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("request-evidence-v1.json").path)
        #expect((stateAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.removeItem(at: fixture.sessions.appendingPathComponent("copied.jsonl"))
        let removed = try await Self.load(fixture)
        #expect(removed.conflictingRecordIDs == nil)
        #expect(removed.records.count == 1)
        #expect(removed.records.first?.totalTokens == 110)
    }

    @Test
    func `persisted observations follow exact windows including future zero usage`() async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let future = UsageLedgerCodexTests.now.addingTimeInterval(60)
        let zeros = UsageLedgerCodexTests.nativeTokens.mapValues { _ in 0 }
        try fixture.write(records: [
            UsageLedgerCodexTests.nativeRequest(),
            UsageLedgerCodexTests.nativeRequest(tokens: zeros, timestamp: future),
        ], name: "usage.jsonl")
        let before = try await Self.load(fixture)
        #expect(before.conflictingRecordIDs == nil)
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let after = try await Self.load(fixture, now: future, budget: budget)
        #expect(after.conflictingRecordIDs == before.records.map(\.id))
        #expect(budget.bytesConsumed <= 64 * 1024)
        let back = try await Self.load(fixture)
        #expect(back.conflictingRecordIDs == nil)
    }

    @Test(arguments: ["corrupt", "valid-json-corruption", "missing", "interrupted"])
    func `missing corrupt or interrupted evidence forces complete recovery`(failure: String) async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var tokens = UsageLedgerCodexTests.nativeTokens
        tokens["input_tokens"] = 200
        try fixture.write(records: [
            UsageLedgerCodexTests.nativeRequest(), UsageLedgerCodexTests.nativeRequest(tokens: tokens),
        ], name: "usage.jsonl")
        let first = try await Self.load(fixture)
        let root = try #require(fixture.options.cacheRoot)
        let state = root.appendingPathComponent("request-evidence-v1.json")
        switch failure {
        case "corrupt": try Data("invalid".utf8).write(to: state)
        case "valid-json-corruption":
            let envelope = try JSONDecoder().decode(CodexLedgerCache.Envelope.self, from: Data(contentsOf: state))
            var payload = try #require(JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any])
            payload["evidence"] = [:]
            let changed = try CodexLedgerCache.Envelope(
                payload: JSONSerialization.data(withJSONObject: payload),
                checksum: envelope.checksum)
            try JSONEncoder().encode(changed).write(to: state)
        case "missing": try FileManager.default.removeItem(at: state)
        default:
            let cache = try CodexLedgerCache(root: root, checkCancellation: {})
            try cache.beginScan()
            cache.release()
        }
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let recovered = try await Self.load(fixture, budget: budget)
        #expect(recovered.conflictingRecordIDs == first.conflictingRecordIDs)
        #expect(recovered.records == first.records)
        #expect(budget.bytesConsumed > 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("scan-in-progress").path))
    }

    @Test
    func `same inode growth with a rewritten historical middle forces complete native recovery`() async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = UsageLedgerCodexTests.nativeRequest()
        let padding: [String: Any] = [
            "type": "message", "payload": ["private_text": String(repeating: "x", count: 100_000)],
        ]
        try fixture.write(records: [request, padding], name: "usage.jsonl")
        let before = try await Self.load(fixture)
        let initialInventory = try CodexLedgerCache.inventory(roots: [fixture.sessions], checkCancellation: {})
        let url = fixture.sessions.appendingPathComponent("usage.jsonl")
        let original = try String(contentsOf: url, encoding: .utf8)
        let rewritten = original.replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":200")
        #expect(rewritten != original)
        try Data(rewritten.utf8).write(to: url)
        var continuation = request
        var payload = try #require(continuation["payload"] as? [String: Any])
        payload["response_id"] = "response-two"
        continuation["payload"] = payload
        _ = try Self.append(continuation, to: url)
        let changedInventory = try CodexLedgerCache.inventory(roots: [fixture.sessions], checkCancellation: {})
        #expect(initialInventory.files.values.first?.identity == changedInventory.files.values.first?.identity)
        #expect((changedInventory.files.values.first?.size ?? 0) > (initialInventory.files.values.first?.size ?? 0))
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let recovered = try await Self.load(fixture, budget: budget)
        #expect(recovered.records.count == 2)
        #expect(recovered.records.first(where: { $0.id == before.records.first?.id })?.inputTokens == 200)
        #expect(recovered.records.reduce(0) { $0 + $1.totalTokens } == 320)
        #expect(recovered.conflictingRecordIDs == nil)
        #expect(budget.bytesConsumed >= Int64(rewritten.utf8.count))
    }

    @Test
    func `waiting for another exporter is cancellable without discarding valid evidence`() async throws {
        let fixture = try UsageLedgerCodexTests.NativeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write(records: [UsageLedgerCodexTests.nativeRequest()], name: "usage.jsonl")
        let clean = try await Self.load(fixture)
        let root = try #require(fixture.options.cacheRoot)
        do {
            let heldLock = try CodexLedgerCache(root: root, checkCancellation: {})
            #expect(throws: CancellationError.self) {
                _ = try CodexLedgerCache(root: root, checkCancellation: { throw CancellationError() })
            }
            // Keep the first exporter lock alive until the cancelled acquisition has returned.
            heldLock.release()
        }
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0)
        let recovered = try await Self.load(fixture, budget: budget)
        #expect(recovered.records == clean.records)
        #expect(budget.bytesConsumed <= 64 * 1024)
    }

    private static func load(
        _ fixture: UsageLedgerCodexTests.NativeFixture,
        now: Date = UsageLedgerCodexTests.now,
        budget: CostUsageScanner.CodexScanBudget? = nil) async throws -> UsageLedger
    {
        var options = fixture.options
        options.codexScanBudgetForTesting = budget
        return try await UsageLedgerLoader.loadCodex(
            historyDays: 1,
            now: now,
            options: options,
            pricingCacheRoot: options.cacheRoot)
    }

    @discardableResult
    private static func append(_ request: [String: Any], to url: URL) throws -> Int64 {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
        return Int64(data.count)
    }
}
