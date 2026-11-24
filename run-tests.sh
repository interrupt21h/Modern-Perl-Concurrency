#!/bin/sh
# Laboratory regression suite. Local examples always run; service-backed
# examples run only when their endpoint is configured and reachable.
# Every example verifies its own invariant and exits non-zero on violation.
#
#   DB_DSN / DB_USER / DB_PASS   disposable MySQL schema (examples 10-12, 18, 29)
#   REDIS_SERVER=host:port       disposable Redis or Valkey (13, 16-18, 28, 30)
#   MEMCACHED_SERVER=host:port   disposable Memcached (14)
set -eu
cd "$(dirname "$0")"
pass=0; skip=0

run() {
    printf '%-32s ' "$1"
    out=$(timeout 60 perl "examples/$1" 2>&1) || {
        printf 'FAIL\n%s\n' "$out"; exit 1; }
    printf 'ok   %s\n' "$(printf '%s' "$out" | tail -n 1)"
    pass=$((pass + 1))
}
skipped() { printf '%-32s skip (%s)\n' "$1" "$2"; skip=$((skip + 1)); }

for f in 01-mutex.pl 02-semaphore.pl 03-condition.pl 04-queue.pl \
         05-rwlock.pl 06-flock.pl 07-sysv.pl 08-pipe.pl 09-barrier.pl \
         20-scope-release.pl 22-config-snapshot.pl 23-lock-striping.pl \
         25-flock-deadline.pl 26-lock-metrics.pl; do
    run "$f"
done

if perl -e 'use v5.36; 1' 2>/dev/null; then run 24-try-defer.pl
else skipped 24-try-defer.pl 'needs Perl 5.36+'; fi

if perl -MMCE::Loop -e1 2>/dev/null; then run 27-mce-loop.pl
else skipped 27-mce-loop.pl 'MCE not installed'; fi

# The native futex mutex is C: compile it into a scratch directory and run.
if command -v cc >/dev/null 2>&1; then
    printf '%-32s ' 21-futex-mutex.c
    bin=$(mktemp -d)/futex-mutex
    if cc -O2 -Wall -Wextra -pthread -o "$bin" examples/21-futex-mutex.c \
        && out=$("$bin"); then
        printf 'ok   %s\n' "$out"; pass=$((pass + 1))
    else
        printf 'FAIL\n'; exit 1
    fi
    rm -rf "$(dirname "$bin")"
else
    skipped 21-futex-mutex.c 'no C compiler'
fi

if perl -MFuture::AsyncAwait -MIO::Async::Loop -e1 2>/dev/null; then
    run 19-async-await.pl
else
    skipped 19-async-await.pl 'Future::AsyncAwait / IO::Async not installed'
fi

if [ -n "${DB_DSN:-}" ]; then
    run 10-mysql-advisory.pl
    run 11-mysql-transfer.pl
    run 12-mysql-queue.pl
    if perl -MDBIx::Class -e1 2>/dev/null; then run 29-dbic-locking.pl
    else skipped 29-dbic-locking.pl 'DBIx::Class not installed'; fi
else
    for f in 10-mysql-advisory.pl 11-mysql-transfer.pl 12-mysql-queue.pl 29-dbic-locking.pl; do
        skipped "$f" 'DB_DSN not set'
    done
fi

if [ -n "${REDIS_SERVER:-}" ]; then
    run 13-redis-lease.pl
    run 16-redis-semaphore.pl
    run 17-redis-stream-worker.pl
    run 31-redis-watch-lease.pl
    if [ -n "${DB_DSN:-}" ]; then run 18-fenced-write.pl
    else skipped 18-fenced-write.pl 'needs DB_DSN and REDIS_SERVER'; fi
else
    for f in 13-redis-lease.pl 16-redis-semaphore.pl \
             17-redis-stream-worker.pl 18-fenced-write.pl 31-redis-watch-lease.pl; do
        skipped "$f" 'REDIS_SERVER not set'
    done
fi

if [ -n "${REDIS_SERVER:-}" ] && command -v starman >/dev/null 2>&1 \
   && perl -MCatalyst -MCatalyst::Plugin::Session::State::Cookie -MSereal -e1 2>/dev/null; then
    run 28-catalyst-sessions.pl
else
    skipped 28-catalyst-sessions.pl 'needs REDIS_SERVER, Catalyst, Sereal, Starman'
fi

if [ -n "${REDIS_SERVER:-}" ] && command -v starman >/dev/null 2>&1 \
   && perl -MCatalyst -MSereal -MCrypt::JWT -MYAML::XS -e1 2>/dev/null; then
    run 30-api-tokens.pl
else
    skipped 30-api-tokens.pl 'needs REDIS_SERVER, Catalyst, Starman, Crypt::JWT, YAML::XS'
fi

if [ -n "${MEMCACHED_SERVER:-}" ]; then run 14-memcached-lease.pl
else skipped 14-memcached-lease.pl 'MEMCACHED_SERVER not set'; fi

# Architecture laboratories use isolated, synthetic data.
if perl -MMoose -e1 2>/dev/null; then run 32-worker-lifecycle.pl
else skipped 32-worker-lifecycle.pl 'Moose not installed'; fi
if perl -MDBIx::Class -MDBD::SQLite -e1 2>/dev/null; then
    run 33-layered-transaction.pl
else skipped 33-layered-transaction.pl 'needs DBIx::Class and DBD::SQLite'; fi
if perl -MDBI -MDBD::SQLite -e1 2>/dev/null; then
    run 34-replay-outbox.pl
else skipped 34-replay-outbox.pl 'needs DBI and DBD::SQLite'; fi
run 35-deterministic-race.pl

if perl -MDBI -MDBD::SQLite -e1 2>/dev/null; then
    run 36-processing-capstone.pl
else skipped 36-processing-capstone.pl 'needs DBI and DBD::SQLite'; fi
if perl -MDBIx::Class -MDBD::SQLite -e1 2>/dev/null; then
    run 37-savepoints.pl
else skipped 37-savepoints.pl 'needs DBIx::Class and DBD::SQLite'; fi
run 38-retry-cancel.pl
run 39-contention-benchmark.pl

printf '\n%d passed, %d skipped\n' "$pass" "$skip"
if [ "${REQUIRE_FULL_SUITE:-0}" = 1 ] && [ "$skip" -ne 0 ]; then
    echo 'Full-suite mode rejects skipped laboratories' >&2
    exit 1
fi
