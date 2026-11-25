# Technical review follow-up — Edition 2.1.1

Claude review, 2026-11-24, 280-page edition. This is a source-level audit, not a claim that the pending changes passed CI.

| Recommendation | Status | Evidence / remaining work |
| --- | --- | --- |
| Verified vs documented versions; Redis 7.0 floor | Implemented | guide.tex; verification manifest |
| MySQL lock observation caption | Implemented | explicitly labels 8.0.46 |
| Atomic API-key and refresh-family creation | Previously implemented | API controller ISSUE_KEY/ISSUE_FAMILY scripts |
| Atomic cart increment and session index | Previously implemented | Root controller atomic scripts |
| Expiring key assertions | Implemented | drivers 28/30; persistent simulated provider ledger intentionally excluded |
| Interpret striping results | Implemented | guide and production chapter |
| Reader/writer exclusion and joins | Implemented | independent probe in example 05 |
| Coordinated start for corrected race | Implemented | example 35 |
| Redis 8.4 and Valkey 9.0 native commands | Open | isolated service matrix and capability tests |
| Perl 5.44 | Open | dedicated compatibility job |
| MySQL 9.7 | Open | database matrix and driver verification |
| Matrix evidence and module versions | Partial | module versions added; matrix pending |
| Idempotency mismatch status | Previously implemented | both apps use 422 |
| OpenAPI versions | Previously implemented | both specs 3.2.0 |
| Redis eviction policy scope | Previously implemented | dedicated instance, not logical DB |
| Retry 1205 after full rollback | Previously implemented | guide |
| Durable claim SQL | Previously clarified | pipelines chapter explains OR vs visibility-range |
| Numeric DBI error classification | Open | capture original error before ORM rollback; add contention tests |
| Reap all children | Implemented | example 29 |
| Per-process resource handles | Implemented | MemcachedLab controller |
| Abbreviation boxes and strategy cards | Partial | earlier improvements; broader editorial pass pending |
| Session prefix and password guidance | Implemented | SessionLab Root |
| Payment expiry and stale completion | Implemented | simulated provider ledger, owner-checked completion and post-expiry retry test; not production payment durability |
| Other chapter notes | Open | individual observations and rendered review |
| Quick-reference graphics | Implemented | all 24 reused from common source; visual review pending |

The prior 288-page publication passed CI in run 45641996246. This review branch requires fresh full CI and visual inspection before publication; prior success does not verify these changes.

## Publication layout follow-up

The floating quick-reference additions were replaced with compact non-floating visual models in the original strategy cards and prose. The 24-diagram source is preserved, as are the original detailed figures and verified technical fixes. See [LAYOUT-GUIDE.md](LAYOUT-GUIDE.md); automated checks and rendered contact sheets are required, and manual visual approval remains distinct from CI success.
