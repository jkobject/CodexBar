import Foundation

extension CostUsageScanner {
    /// Native exports observe owned records before replay/copy suppression.
    @TaskLocal static var codexLedgerRequestObserver: CodexLedgerRequestObserver?
}

/// Durable evidence contains hashes and numbers only; private native JSONL cursors stay in the local scanner DB.
final class CodexLedgerRequestObserver: Sendable {
    struct Observation: Codable, Hashable, Sendable {
        let endOffset: Int64
        let id: String
        let timestampUnixMs: Int64
        let modelDigest: String
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int?

        func matchesPayload(_ other: Self) -> Bool {
            self.modelDigest == other.modelDigest && self.input == other.input && self.cached == other.cached
                && self.output == other.output && self.reasoning == other.reasoning
        }
    }

    typealias Evidence = [String: Set<Observation>]

    private let sinceUnixMs: Int64
    private let untilUnixMs: Int64
    private let state: CostUsageScanExecutor.LockedState<Evidence>

    init(since: Date, until: Date, evidence: Evidence = [:]) {
        self.sinceUnixMs = Int64(since.timeIntervalSince1970 * 1000)
        self.untilUnixMs = Int64((until.timeIntervalSince1970 * 1000).rounded())
        self.state = .init(evidence)
    }

    /// A native full reparse replaces file evidence; incremental parsing replaces only the uncommitted suffix.
    func beginFile(_ fileURL: URL, startOffset: Int64) {
        let file = Self.fileID(fileURL)
        self.state.withLock { state in
            state[file] = startOffset == 0 ? [] : state[file]?.filter { $0.endOffset <= startOffset } ?? []
        }
    }

    /// Ownership is checked by the native parser. Keep temporal evidence so advancing windows stay exact.
    func observe(fileURL: URL, endOffset: Int64?, sessionID: String?, row: CostUsageScanner.CodexUsageRow) {
        guard let sessionID, let responseID = row.responseID, let timestamp = row.timestampUnixMs else { return }
        // Provider-specific by design: Native Codex request identity combines rollout ownership and response ID.
        let observation = Observation(
            endOffset: endOffset ?? 0,
            id: UsageLedgerRecord.digest(["codex", "request", sessionID, responseID]),
            timestampUnixMs: timestamp,
            modelDigest: UsageLedgerRecord.digest([CostUsagePricing.normalizeCodexModel(row.model)]),
            input: row.input,
            cached: row.cached,
            output: row.output,
            reasoning: row.reasoning)
        self.state.withLock { _ = $0[Self.fileID(fileURL), default: []].insert(observation) }
    }

    static func fileID(_ fileURL: URL) -> String {
        UsageLedgerRecord.digest(["codex", "file", fileURL.resolvingSymlinksInPath().standardizedFileURL.path])
    }

    var evidence: Evidence {
        self.state.withLock { $0 }
    }

    var conflictingRecordIDs: [String] {
        self.state.withLock { state in
            var payloads: [String: Observation] = [:]
            var conflicts = Set<String>()
            for observation in state.values.joined()
                where observation.timestampUnixMs >= self.sinceUnixMs
                && observation.timestampUnixMs <= self.untilUnixMs
            {
                if let previous = payloads[observation.id], !previous.matchesPayload(observation) {
                    conflicts.insert(observation.id)
                } else {
                    payloads[observation.id] = observation
                }
            }
            return conflicts.sorted()
        }
    }
}
