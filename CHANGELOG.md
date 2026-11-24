# Changelog

## Edition 2.1 — editorial and reproducibility revision

- Reorganize the book into six parts and technical appendices; preserve full listings.
- Add chapter objectives, strategy cards, reading paths, example catalog and subject/API index.
- Clarify fencing, delivery guarantees and experimental syntax; add a processing capstone, savepoints, cancellation/retry and contention laboratories.
- Strengthen service-backed CI and PDF preflight.

## Edition 2.0 — application concurrency architecture

- Add seven application-oriented chapters, synthetic laboratories 32–35, and architecture diagrams covering object lifetimes, transaction ownership, batch pipelines, cross-system delivery, migration, testing and deployment.
- Unify callout headings, spacing and accent rules across the handbook.
- Enable Moose, DBIx::Class and SQLite laboratory dependencies in CI; retain historical integration evidence separately.
- Keep the two-page cheat sheet and publish it with the expanded handbook.

## Edition 1.3 — presentation and Perl execution boundary

- Clarify Redis server-side Lua, highlight embedded scripts, pair standalone script with Perl invocation.
- Add WATCH/MULTI/EXEC lease example and regression entry; document trade-offs and ambiguous results.
- Clean up front matter, contents numbering, tip boxes, laboratory navigation and selected dense source lines.
- Retain earlier integration results as historical evidence, not a new service test.

Modern Perl Concurrency and Locking — created and written by Scott Muller.

## Edition 1.2 — documentation formatting revision

- Replaced the legacy LaTeX listings renderer with Pygments-generated token
  streams and a shared, breakable code-box style. Listings retain source line
  numbering, identify their language and repeat captions on continuation pages.
- Extracted 19 inline snippets verbatim; retained all original example files
  byte-for-byte. All 57 code blocks use the same presentation system.
- Added a reproducible Makefile, pinned documentation dependency, offline
  generated highlighting, and build instructions. No shell escape is required.
- Corrected README strategy/figure counts, distinguished executable programs
  from excerpts and transcripts, and clarified the original verification record.

## Edition 1.2 — November 2026

### API credentials and OpenAPI 3.2 (fourth review)
- New section "API credentials on Redis" in the Catalyst chapter: credential
  comparison table, OpenAPI 3.2 security schemes (device flow,
  oauth2MetadataUrl, deprecated schemes), hashed API keys, strictly verified JWT
  access tokens, refresh-token rotation with reuse detection, logout and
  revocation, signed requests with replay protection, idempotency for API
  clients, key layout and ACL prefixes.
- Four strategy cards (31 in total) and four diagrams (44 in total): API key
  issue and use, the refresh rotation race (naive vs atomic), the refresh-token
  state machine with grace window, and signed-request verification order.
- Example 30 and the API controller, token module and OpenAPI document. The
  concurrent refresh race is reproduced (naive rotation forks the token family)
  and fixed with one Lua script, deterministic HMAC successors and a grace window.
- Findings written into the text: Crypt::JWT checks `exp` only when present
  unless `verify_exp => 1`, and does not check `typ`, so RFC 9068 explicit
  typing is enforced by hand; the nonce must be recorded only after the
  signature verifies; the IETF Idempotency-Key draft has expired; RateLimit
  headers now use the draft-11 structured-field syntax.
- New pop-out TIP callout, used across the handbook (lock register, async
  await gaps, dedicated lock files, per-process connections, InnoDB deadlock
  logging, transaction retry helper, lock-name conventions, TTL jitter, wait vs
  hold metrics, reproducible races).
- Glossary: grace window, HMAC, JWT, nonce, OpenAPI security scheme, refresh
  token, token family. References [48]–[60]: RFC 9700, 8725, 9068, 9421, 9449,
  OpenAPI 3.2.0, Crypt::JWT, OpenAPI::Modern, IETF drafts, Okta, Cognito, Auth0.

### Full review: strategies for every reader (third review)
- Credits Scott Muller as creator on the title page, a copyright page, every
  page footer and the PDF metadata.
- Strategy cards for all 27 locking strategies: an everyday analogy ("In plain
  terms"), when to use, when to avoid, and the Perl tools. They are indexed in a
  "Locking strategies at a glance" table, and the Chapter 2 primitives table links
  to them.
- Twenty-two new diagrams (40 in total), so that every strategy is illustrated:
  semaphore, condition variable, barrier, work queue, snapshot publication,
  async race, lock striping, release paths, flock deadline, System V semaphore,
  row locks (FOR UPDATE / NOWAIT / SKIP LOCKED), optimistic versioning, GET_LOCK,
  fencing, Redis semaphore, Redlock, Memcached CAS, cache stampede, session
  fixes, rate limiting, consensus coordinators and execution models. The three
  legacy inline diagrams were redrawn in the shared style, and every figure was
  rendered and checked.
- New section on transactions and locking with DBIx::Class, and example 29,
  verified against MySQL. Findings: txn_do never retries deadlocks (it reruns
  once only after a lost connection); the MySQL SQL maker rejects the
  documented scalar-ref `for`, and 'shared' emits LOCK IN SHARE MODE. A
  nine-line subclass enables SKIP LOCKED.
- Glossary of 29 terms; reading paths for newcomers and experienced engineers.
- Example 29 initially passed vacuously (0 jobs claimed after example 12
  drained the queue); it now seeds its own jobs and fails if none are claimed.
- Spelling normalized to American English; a prose spell-check found no typos.

### Verification
- All 19 executable examples now run against live services: MySQL 8.0.46,
  Redis 7.0.15 and Memcached 1.6.24 on threaded Perl 5.38.2. In 1.1 the
  database and cache examples had only been reviewed against documentation.
- New `run-tests.sh` runs the local examples and any service-backed examples
  whose endpoints are configured.
- Every example now checks its own invariant. Examples 13 and 14 fork
  competing workers and assert exclusion instead of running one uncontested
  process.

### New content
- Chapter 1: a coordination-mechanism selection matrix covering
  efficiency vs. correctness locks and the scope of participants.
- Chapter 5: event loops with Future::AsyncAwait, Future::Mutex and bounded
  fan-out (example 19). This includes a measured lost-update race in a
  single-threaded loop.
- Chapter 6: releasing on every path with eval, stable try/catch (5.40+),
  defer and scope guards (example 20), including the fork-inheritance hazard.
- Chapter 8: DBD::mysql 5.x vs DBD::MariaDB; per-session
  innodb_lock_wait_timeout; MySQL 9.7 LTS and calendar versioning.
- Chapter 8: example 12 rewritten as a visibility-timeout queue with owner and
  attempt fencing, heartbeat, conditional completion, an idempotent effect in
  the same transaction, and dead-lettering.
- Chapter 9 (rewritten): Redis/Valkey licensing landscape; Perl client
  selection (Redis, Redis::Fast, Net::Async::Redis); a version-annotated
  command table including Redis 8.4 DELEX / SET IFEQ and Valkey 8.1/9.0
  SET IFEQ / DELIFEQ; EVALSHA with NOSCRIPT fallback; atomic lease plus fence
  allocation (example 13); end-to-end fenced write (example 18); a distributed
  counting semaphore using server time (example 16); Streams consumer groups
  with XAUTOCLAIM recovery (example 17); WAITAOF, AOF fsync trade-offs and
  clock steps; a tested least-privilege ACL.
- Chapter 11: authoritative coordinators (etcd, ZooKeeper, Kubernetes Lease,
  PostgreSQL transaction-scoped advisory locks).
- Chapter 12: a per-example verification record.

### Catalyst sessions, illustrations and Perl detail (second review)
- New chapter: Catalyst sessions and request coordination on Redis. It covers
  how Catalyst::Plugin::Session loads and saves, source-level assessment of
  Session::Store::Redis 0.900 and CHI::Driver::Redis 0.10, a hardened store,
  session-ID generation, fixation, cookie and reverse-proxy behavior, the
  concurrent-request lost update with atomic and locked fixes, idempotency
  keys, login rate limiting, logout everywhere and Kubernetes deployment.
- New example 28 and examples/catalyst-session/: a complete Catalyst app
  verified under Starman (4 workers) by 29 checks against live Redis.
- Findings from building it: the default session ID generator is not
  cryptographic; cookie_secure defaults to 0; ReverseProxy is applied only
  for 127.0.0.1; the packaged stores write SET then EXPIRE separately and
  Store::Redis thaws Storable data. Catalyst's UTF-8 setup makes STDERR
  buffered, which delays and loses worker log lines (fixed with autoflush).
- A design flaw in our own first idempotency handler (24 h TTL while pending
  would block retries for a day after a crash) found by fault injection and
  fixed with a 2-minute pending TTL. A bug in the first driver (END block's
  waitpid masking the exit status) was fixed with local $?.
- 18 TikZ figures (figures/), each rendered and checked.
- New sections: lock() semantics (verified table: element locks and unshared
  variables die, references are followed one level, locks are advisory);
  locks across fork, exec and signals (flock shared via the open file
  description; fcntl locks not inherited and dropped on any close; alarm
  interrupts flock); preforking web servers; Redis key design and per-instance
  eviction policy; measured InnoDB next-key locks, including a FOR UPDATE on
  the primary key that locked the whole table through a covering-index scan.

### No code fragments (review follow-up)
- Listing 2.1 was four comment lines presented as a "pseudocode" mutex. It is
  replaced by 21-futex-mutex.c: a complete three-state futex mutex with C11
  acquire/release atomics, stress-tested (8 threads x 10^6 increments) and
  clean under ThreadSanitizer, plus an strace measurement showing that Perl's
  lock() made 54 futex calls for 40,000 acquisitions.
- Every former Perl fragment is now a runnable, self-verifying example:
  22 snapshot publication (was a fragment with no readers or writer),
  23 lock striping with ordered and recursive all-stripe acquisition (the
     listing's body was a comment),
  24 try/catch/defer helper (called undefined acquire/release/log_failure),
  25 flock with a deadline (the timeout path was never exercised),
  26 lock wait/hold percentiles under contention (measured one uncontended
     sample),
  27 MCE pool with per-worker setup and verified gather (only printed).
- 27 initially exposed a real precision bug: a sum above 2**53 lost precision
  as a floating-point value yet still compared equal. The example now stays in
  the exact-integer range and refuses results outside it.
- The Redis CLI listing now generates $TOKEN instead of using it undefined.

### Corrections
- The lock-ordering listing declared lexical `$a`/`$b`, which shadow sort's
  package variables. The variables are now renamed.
- Examples 01, 02 and 04 ignored thread failures. join results are now
  checked and `$thr->error` is reported.
- Example 07 had a redundant `$failed ||= 0` and leaked the semaphore set on
  abnormal exit. It now cleans up from an END block guarded by the creating
  PID.
- Example 11 retried lock-wait timeouts under the 50 s server default. It now
  sets the session timeout to 5 s and can run concurrent opposing transfers.
- Example 10 printed nothing on success. It now verifies ownership with
  IS_USED_LOCK and checks the name length.
- Example 14 conflated backend errors with contention. It now counts errors
  separately and fails after repeated backend failures.
- The Memcached table contained Perl POD markup (`C<cas>`) and a malformed
  meta set syntax. Both are corrected.
- The fencing section implied that Redis counter loss endangers correctness.
  With destination-enforced fencing it fails safe (rejects writes), and the
  guide now explains how to recover by re-seeding the counter.
- "Redis documents newer conditional commands" was replaced with the specific
  commands and the versions that introduced them.
- References [8], [16], [17] and [18] were listed but never cited. They are
  now cited where relevant, and the reference list is extended to 47 entries.
- NFS: the guide now notes that Linux emulates flock with byte-range locks,
  so the two lock families interact on NFS mounts.
- The 15-memcached-meta transcript was extended with the stale-CAS (EX) case
  and replayed against a live server.

### Presentation
- Sans-serif chapter and section headings consistent with the title page.
- Colour-coded callouts: engineering note, correctness warning, version note,
  verified.
- Ragged-right table columns, upright quotes in listings so shell and SQL
  copy-paste correctly, and listing captions kept with their code.
- hyperref is now loaded last, as recommended.

## Edition 1.1
- Added Redis and Memcached chapters (documentation-reviewed).

## Edition 1.0
- Initial release.
