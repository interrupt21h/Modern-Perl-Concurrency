# Modern Perl Concurrency and Locking — Edition 1.3

Created and written by **Scott Muller**. © 2026 Scott Muller.

Engineering handbook and self-verifying laboratory covering ithreads, processes,
event loops, MySQL/InnoDB transactions and DBIx::Class, Redis/Valkey leases,
semaphores and Streams, Catalyst sessions on Redis, and Memcached coordination.
Every locking strategy (31 in all) has a strategy card with a plain-language
explanation and a diagram (45 figures), so the guide serves junior developers
and experienced engineers alike.

## Build the handbook

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-docs.txt
make
```

Requires Python 3, GNU Make, latexmk and TeX Live (pdfLaTeX, fvextra, upquote,
TikZ, tcolorbox, titlesec, caption, enumitem, needspace, adjustbox, xurl and
Latin Modern). On Debian/Ubuntu, `texlive-latex-extra`, `texlive-pictures`,
`texlive-fonts-recommended`, `lmodern` and `latexmk` provide the TeX packages.
The output is `guide.pdf`. `make clean` removes LaTeX intermediates.

For a TeX-only build of this exact source snapshot, the pre-generated
highlighted listings are included:

```sh
latexmk -pdf -interaction=nonstopmode -halt-on-error -file-line-error guide.tex
```

After editing any listing source, use `make` (or `python3 scripts/highlight.py`
before running latexmk). The highlighting script checks that tokenization
preserves the full source text. No LaTeX shell escape is required.

### Project layout

- `guide.tex`: main handbook and shared document macros.
- `distributed-cache.tex`, `catalyst-sessions.tex`, `api-credentials.tex`:
  chapter/section source files.
- `styles/code-layout.tex`: shared, page-breakable code box style.
- `examples/`: original executable programs, schema, protocol transcript and
  Catalyst lab application; edit these, not the highlighted output.
- `snippets/`: original inline excerpts extracted verbatim into separate files.
- `figures/`: TikZ figure sources.
- `generated/code/`: generated TeX token streams and palette; do not edit by hand.
- `scripts/highlight.py`: language-aware highlighting and source-preservation check.

The 59 code listings use Perl, C, SQL, Shell, Lua, YAML and plain-text output
lexers. Long listings repeat their title on continuation pages; wrapping does
not change the underlying source file. The source files are authoritative for
copying and running examples.

### Source style and execution boundary

Perl is the application language. Redis Lua is embedded server-side code; it
has its own syntax highlighting, with a separate header for standalone scripts.
Example 31 uses WATCH/MULTI/EXEC instead of Lua for owner-checked renewal and
release. Use four-space indentation and prefer one statement per line. Keep
heredoc delimiters and script contents intact when formatting Perl. The source
files are the canonical examples; extracted excerpts are explicitly labelled.

## Run the laboratory

The guide contains complete executable examples alongside excerpts, commands,
configuration and transcripts. Every executable example checks its own invariant and exits non-zero on violation. `run-tests.sh` always runs the local examples and runs service
examples only when their endpoint is configured.

```sh
# Local only (threaded Perl, System V IPC):
./run-tests.sh

# Full suite against DISPOSABLE services:
mysql -u lab -p concurrency_lab < examples/schema.sql
export DB_DSN='DBI:mysql:database=concurrency_lab;host=127.0.0.1'
export DB_USER=lab DB_PASS=...            # inject via your secret mechanism
export REDIS_SERVER=127.0.0.1:6379 MEMCACHED_SERVER=127.0.0.1:11211
./run-tests.sh
```

Optional for Redis ACL testing: `REDIS_USERNAME` and `REDIS_PASSWORD`
(examples 13, 16 and 31 honor them; see the guide's ACL section).

CPAN dependencies by example group:

| Examples | Modules |
|---|---|
| 01–09, 20, 22, 23, 25, 26 | core only (threaded Perl) |
| 21 | C compiler (C11, pthreads; compiled into a scratch dir by run-tests.sh) |
| 24 | Perl 5.36+ (try/catch, defer) |
| 27 | MCE |
| 28 | Catalyst, Catalyst::Plugin::Session, Session::State::Cookie, Sereal, Starman, Redis (Debian/Ubuntu: libcatalyst-perl, libcatalyst-plugin-session-perl, libcatalyst-plugin-session-state-cookie-perl, libsereal-perl, starman) |
| 30 | as 28, plus Crypt::JWT and YAML::XS (libcrypt-jwt-perl, libyaml-libyaml-perl) |
| 10–12, 18 | DBI, DBD::mysql (or DBD::MariaDB with a DSN change) |
| 29 | DBIx::Class, DBI, DBD::mysql |
| 13, 16–18, 31 | Redis (Redis::Fast is API-compatible) |
| 14 | Cache::Memcached::Fast |
| 19 | Future::AsyncAwait, IO::Async |

Example 15 is a protocol transcript, not a script. Redis examples need Redis
6.2+ or Valkey 7.2+ (example 17 uses XAUTOCLAIM). The schema needs MySQL
8.0.16+ for enforced CHECK constraints and expression defaults.

Example 18 depends on the Redis fence counter staying ahead of the database.
If you flush or restart Redis without persistence, reload `schema.sql` before
rerunning it. Otherwise it reports that fencing failed safe, which is the
behavior it is meant to demonstrate.

## Catalyst laboratory

`examples/catalyst-session/` is a complete Catalyst application (hardened
Redis session store, session lock, idempotency keys, rate limiting, logout
everywhere). `examples/28-catalyst-sessions.pl` starts it under Starman with
four workers on a free loopback port and verifies 29 properties.

The same application exposes an API (`SessionLab::Controller::API`,
`SessionLab::Tokens`) described by `examples/catalyst-session/openapi.yaml`
(OpenAPI 3.2.0): hashed API keys with per-key rate limits, JWT access tokens
(algorithm pinned, `exp` and `typ: at+jwt` required, jti denylist), refresh-token
rotation with reuse detection that is safe under concurrent refreshes, and
HMAC-signed requests with single-use nonces. `examples/30-api-tokens.pl`
verifies 33 properties, including the naive rotation race it fixes. Set
`SESSIONLAB_JWT_KEY`, `SESSIONLAB_REFRESH_KEY` and `SESSIONLAB_SIGNING_KEY`
outside the laboratory; the built-in defaults are public.

To explore it by hand:

```sh
REDIS_SERVER=127.0.0.1:6379 starman --workers 4 --listen 127.0.0.1:5000 \
    examples/catalyst-session/app.psgi
```

## Safety

The examples create, delete and flush keys and tables in the namespaces they
use (`lease:*`, `fence:*`, `sem:*`, `jobs:{demo}`, the session lab's `sess:*`,
`cart:*`, `idem:*`, `charges:*`, `ratelimit:*`, `user-sessions:*`, `slock:*`, and
the lab schema). Run them
only against isolated, disposable services. The reader/writer lock and barrier
are educational implementations. Cache leases must never be the sole
authority for correctness-critical operations.

See `CHANGELOG.md` for the differences from Edition 1.1 and
`test-results.txt` for the original laboratory verification record. The formatting
revision preserves the original examples and does not replace that historical record.

## Format the Perl code and rebuild

Install the real Perl::Tidy formatter (the reference formatter release is
20260826 from CPAN). On Debian/Ubuntu:

```sh
sudo apt-get install cpanminus
sudo cpanm SHANCOCK/Perl-Tidy-20260826.tar.gz
```

The distribution's `perltidy` package is also suitable if its version supports
all options in `.perltidyrc`. With the documentation dependencies installed:

```sh
make tidy          # format .pl, .pm, .psgi and .t under examples/ and snippets/
make tidy-check    # verify formatting without modifying source
make tidy-rebuild  # format, check, run local regression suite, regenerate PDF
```

The formatting driver stages results for all 38 Perl files in memory before
writing any changes, rejects formatter diagnostics and non-idempotent output,
and checks embedded Lua bodies byte-for-byte. The formatter targets 76 columns;
long literals or embedded scripts may still require PDF line wrapping. The
standalone Lua, C, SQL and other non-Perl files are intentionally untouched.
Review the source diff and run integration tests against disposable services
before publication. No formatter can prove semantic equivalence by itself.

For an online build, initialize/push this directory to a GitHub repository and
run **Format Perl and rebuild handbook** from the Actions tab. The artifact
contains the formatted source, PDF, build log and source diff. It does not push
changes back to the repository. The workflow is provided but has not been run
in the offline authoring environment.
