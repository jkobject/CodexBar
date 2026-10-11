# Experimental cross-host native usage ledger

This experiment combines native Codex or Claude Code usage recorded on this machine and one explicitly
selected SSH host. It exports numeric usage records with hashed identities, deduplicates them before
summing, and shows uncertainty when the available histories cannot establish complete accounting.
It does not provide account-wide telemetry or a billing receipt. Deleted histories, unsupported formats,
unmetered requests and machines outside the selected pair remain outside the result.

## Manual use

```sh
codexbar cost --provider codex --combine-remote build-host --format json
codexbar cost --provider claude --combine-remote build-host
codexbar cost --provider claude --ledger-only --format json --days 30
```

In **Usage & Spend → Cross-host usage — Experimental**, enter a trusted SSH alias and select **Add host**
once. The saved host participates in ordinary cost refreshes for enabled Codex and Claude Code providers.
Adding a host enables cost history collection; it does not enable a disabled provider. **Remove host**
restores local accounting. The menu and spend dashboard use the same deduplicated identity union, so
the dashboard does not add the local total a second time. The configured timezone defines both sources'
calendar buckets. Collection reads the last 365 days; shorter menu and chart periods project that union.
The All range remains bounded to those collected days.

Changing or removing the host, timezone or cost configuration retires pending work before cancellation.
A late SSH completion cannot publish into the new scope. Local and remote readers start concurrently,
and source failures retain usable records with explicit partial coverage. Combined reports are retained
in memory and kept separate from account-scoped cost caches. The SSH alias is saved in user defaults.

Debug builds accept `--usage-ledger-preview` or `CODEXBAR_USAGE_LEDGER_PREVIEW=1` to open the real panel
in a standalone trial window before normal app startup. This preview uses the current calendar and
does not initialize settings, provider refreshes, or the ordinary dashboard's shared caches.

The remote machine must have this experimental CLI installed as `codexbar` on its login-shell PATH.
The macOS app-bundle helper is a fallback when no PATH executable exists. Finding an older executable
that lacks `--ledger-only` is a source failure; it does not trigger another scan or a fallback total.
SSH runs with batch authentication, strict known-host checking, no terminal, no forwarded agent and no
port forwarding. It requests compression for the numeric reply. A failed source remains visible while
the other source's recorded subtotal is retained.

## Reporting window

Ledger modes accept one explicit `--provider codex|claude`. `--days` ranges from 1 to 365 and defaults to 30.
`--ledger-only` requires JSON output. `--combine-remote` supports text or JSON and is mutually exclusive
with `--ledger-only`. Neither mode accepts `--remote`, `--summary-only`, `--period`, `--group-by` or
`--breakdown`. Pi and OMP histories are excluded by construction.

The collecting machine fixes one timezone and inclusive window end before scanning either machine.
`--ledger-time-zone` accepts a timezone identifier, and `--ledger-end` accepts Unix milliseconds.
The start is midnight at the beginning of the first requested calendar day; the default end is the
collector's current time. Both explicit window boundaries travel as integer milliseconds so ISO8601
formatting of the snapshot date cannot truncate them. Remote reports must match the requested day count,
timezone, start and end. Records outside that interval are excluded.

## Versioned numeric transport

The schema version is **1**. A ledger contains:

| Field | Meaning |
| --- | --- |
| `schemaVersion`, `provider` | Transport compatibility and native provider |
| `updatedAt` | Snapshot timestamp |
| `historyDays`, `bucketTimeZone` | Requested calendar window |
| `windowStartUnixMs`, `windowEndUnixMs` | Inclusive integer-millisecond interval |
| `coverageIsEstablished` | Whether the source can establish coverage for that interval |
| `incompleteRequestCount`, `warnings` | Explicit source limitations |
| `conflictingRecordIDs` (optional) | Hashed identities contradicted within a native source before copy selection |
| `records` | Native usage records; no daily total is invented into a request |

Each record carries a SHA-256 identity hash, an optional hashed session identity, an identity-evidence
class, an integer-millisecond timestamp, sanitized model identifiers, native token categories, a native
total and optional cost/pricing provenance. Codex input includes cache reads; Claude input excludes
cache reads and cache creation. The native total preserves those provider-specific definitions.
Reasoning tokens and one-hour cache creation are retained where recorded.

Prompts, responses, project paths, conversation titles and raw session/request/message identifiers are
not transferred. Identity components use length framing before hashing, and the export redacts model
metadata that is not an identifier. Hashes remain stable enough to correlate copies across the selected
machines; they are pseudonymous identifiers, not a claim of anonymization.

Validation rejects unsupported schemas/providers, mismatched windows, invalid numeric values, overflow
and malformed identity hashes. Each ledger is bounded to 100,000 records and 32 MiB of encoded output.
The SSH operation has a 180-second timeout. Codex scanning uses a separate private incremental native
cache on each machine. It stores numeric/hash identity evidence alongside the native scanner's local
resume cursors, uses owner-only permissions and a cross-process lock, and recovers after an interrupted
write. Native cursors can contain an unfinished local JSONL line; this local data is never part of the
ledger or transferred over SSH. The first scan must read available history; later scans reuse completed
files and append cursors. Rewrites, removals and incompatible or dirty cache state trigger recovery.

## Conservative accounting

Stable request identities are unioned before summing. Equal identities with equal native usage count
once. Different token, model or reasoning observations under the same identity are conflicts: the
conflicting identity is excluded and the result is partial. Different price/provenance observations
retain unique token accounting but make the complete combined dollar amount unavailable. Unknown prices
do the same. `pricedCostUSD` separately exposes the accepted known-price subtotal, which the app labels
as a subtotal with explicit unpriced request counts. An entirely unknown-priced window stays unavailable;
only a proven empty window can display zero.

Native exporters detect disagreements before selecting same-host copies. Codex observes owned request
records before replay suppression; Claude compares completed, already-normalized per-file responses.
Legitimate cumulative streaming updates remain normalized by the native reader. Conflict hashes are
carried independently of numeric rows, so redaction or an overflowing row cannot revive that identity
through a clean observation on the other host. Detection uses the exact requested timestamp window.

Legacy event identities are weaker evidence. The result reports their count and cannot establish full
cross-host coverage while they remain. When a session has different request/legacy representations
and no proven alias, its ambiguous legacy rows are withheld even if both representations came from
copied files on the same machine. If any strong request record lacks session provenance, all legacy
rows are withheld because the available metadata cannot disprove an overlap. Records without stable
identity are also withheld. This can undercount rather than invent certainty about an overlap.

Complete coverage requires readable source reports, established native scan coverage, no excluded
incomplete requests, no usage conflicts, no unidentified or ambiguously represented records and no
remaining legacy identities. Otherwise the app and CLI label the result a **recorded subtotal** and
show relevant source limitations. A clean scan describes the available native histories; it cannot prove
that a user never deleted or moved an earlier history.

Costs preserve authoritative dollar values recorded by the native reader where available and otherwise
use that reader's API-price estimate, including cache/priority metadata. Prices can differ between
machines with different catalogs or custom overlays. These amounts do not establish subscription spend
or the provider's invoiced charge.

The incremental Codex scan database is separate from its pricing input: exports read the installed
models.dev catalog through the native resolver without copying, refreshing or modifying it. Missing
remote estimates can be filled from the collector's installed catalog using exact Claude model IDs and
supported native pricing modes. Existing priced values retain their provenance. Unknown models remain
unpriced. Codex Fast estimates apply documented API multipliers, including GPT-6 model families. Existing
stable cost databases adopt the exact compatible v0.74.0/main parser fingerprint while retaining saved
reports, billing rows, pricing and checkpoints.

## Experiment and review scope

This is an opt-in design proposal: saving an SSH host explicitly selects combined local/remote accounting. Validation
must cover copied/resumed histories, forks and unavailable fork parents, streaming response updates,
request versus legacy representations, contradictory token or price observations, missing metadata,
millisecond window roundtrips, source failures, privacy and cancellation. CLI/parser tests establish
accounting behavior; a separate rendered-app check establishes saved-host configuration and automatic native interaction.
