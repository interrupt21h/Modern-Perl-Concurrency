#!/usr/bin/env python3
"""Capture release evidence after all required tests pass; allow local benchmark previews."""
import argparse
import json
import os
import platform
import re
import socket
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "generated"
OUT.mkdir(exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument("--suite", type=Path)
parser.add_argument("--benchmark", type=Path, required=True)
parser.add_argument("--local", action="store_true")
args = parser.parse_args()

def command(*cmd):
    return subprocess.check_output(cmd, text=True, timeout=20).strip()

def module(name):
    return command("perl", "-M" + name, "-e", f"print ${name}::VERSION")

def tex(value):
    substitutions = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#", "_": r"\_", "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}
    return "".join(substitutions.get(c, c) for c in str(value))

bench = args.benchmark.read_text()
rows = re.findall(r"^stripes=(1|4) workers=(\d+) increments=(\d+) elapsed=([0-9.]+)s$", bench, re.M)
assert len(rows) == 6 and all(w == "4" and n == "40000" for _, w, n, _ in rows)
assert "all benchmark trials preserved the counter invariant" in bench
values = {s: [float(v) for k, _, _, v in rows if k == s] for s in ("1", "4")}
assert all(len(v) == 3 and min(v) > 0 for v in values.values())
cpuinfo = Path("/proc/cpuinfo").read_text()
cpu = re.search(r"^model name\s*:\s*(.+)$", cpuinfo, re.M)
cpu = cpu.group(1).strip() if cpu else platform.machine()
logical = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count()
os_label = platform.freedesktop_os_release().get("PRETTY_NAME", platform.system())
perl = command("perl", "-e", 'print $^V')
threads = command("perl", "-MConfig", "-e", 'print $Config{useithreads}')
info = {"generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"), "environment": {"os": os_label, "kernel": platform.release(), "cpu": cpu, "logical_cpus_available": logical, "perl": perl, "ithreads": threads}, "benchmark": {"workers": 4, "increments_per_trial": 40000, "seconds": values}}
label = "Local preview, not release evidence" if args.local else "Recorded release-run measurement"
context = f"{label}: {os_label}; {cpu}; {logical} logical CPUs visible to the process; Perl {perl}, ithreads {threads}. Four workers, 10,000 increments each; three trials per lock configuration. Includes interpreter thread creation and joining."
lines = [tex(context), r"\begin{center}\small", r"\begin{tabular}{lrrrr}\toprule Locks & Trial 1 (s) & Trial 2 (s) & Trial 3 (s) & Median (s)\\ \midrule"]
for s, v in values.items():
    lines.append(("One shared" if s == "1" else "Four stripes") + " & " + " & ".join(f"{x:.4f}" for x in [*v, statistics.median(v)]) + r"\\")
lines.extend([r"\bottomrule\end{tabular}", r"\end{center}"])
(OUT / "benchmark-results.tex").write_text("\n".join(lines) + "\n")
if args.local:
    raise SystemExit(0)
if not args.suite or not os.environ.get("GITHUB_RUN_ID"):
    raise SystemExit("Release mode requires a completed suite and GitHub run identity")
summary = re.search(r"^(\d+) passed, (\d+) skipped$", args.suite.read_text(), re.M)
if not summary or tuple(map(int, summary.groups())) != (38, 0):
    raise SystemExit("Expected full 38-laboratory suite with zero skips")

def server_version(port):
    result = command("redis-cli", "-p", str(port), "INFO", "server")
    m = re.search(r"^valkey_version:([^\r\n]+)", result, re.M) or re.search(r"^redis_version:([^\r\n]+)", result, re.M)
    if not m:
        raise SystemExit("Missing Redis/Valkey version")
    return m.group(1)

with socket.create_connection(("127.0.0.1", 11211), timeout=5) as sock:
    sock.sendall(b"version\r\n")
    version = sock.makefile("rb").readline().decode().strip().removeprefix("VERSION ")
info.update({"ci_run": os.environ["GITHUB_RUN_ID"], "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"], "trigger_sha": os.environ["GITHUB_SHA"], "primary_tests": {"passed": 38, "skipped": 0}, "additional_checks_completed": ["SQLite savepoints", "Test2 via prove and yath", "seven Valkey integration examples", "Perl::Tidy idempotence"], "services": {"MySQL": command("mysql", "--protocol=TCP", "-h", "127.0.0.1", "-P", os.environ["MYSQL_PORT"], "-u", os.environ["DB_USER"], "-Nse", "SELECT VERSION()"), "Redis": server_version(6379), "Valkey": server_version(16379), "Memcached": version, "SQLite": command("perl", "-MDBD::SQLite", "-e", 'print $DBD::SQLite::sqlite_version')}, "modules": {name: module(name) for name in ("DBI", "DBIx::Class", "DBD::SQLite", "DBD::mysql", "Redis", "Cache::Memcached::Fast", "Catalyst", "Moose", "MCE", "Future", "Test2::V0")}})
(OUT / "release-verification.json").write_text(json.dumps(info, indent=2) + "\n")
url = f'https://github.com/{os.environ["GITHUB_REPOSITORY"]}/actions/runs/{info["ci_run"]}'
lines = [r"\textbf{Current run:} " + tex(info["generated_utc"]) + r". \href{" + url + "}{GitHub Actions run " + info["ci_run"] + "}.", "Trigger revision: " + r"\nolinkurl{" + info["trigger_sha"] + "}. The final release commit and PDF checksums are recorded with the downloadable assets.", r"\begin{longtable}{L{.30\linewidth}L{.62\linewidth}}\toprule Component & Recorded value \\ \midrule\endhead"]
for k, v in [("Primary suite", "38 passed; 0 skipped"), ("Additional checks", "; ".join(info["additional_checks_completed"])), ("Operating system", os_label), ("Perl", perl + "; ithreads " + threads), *info["services"].items(), *info["modules"].items()]:
    lines.append(tex(k) + " & " + tex(v) + r"\\")
lines.extend([r"\bottomrule\end{longtable}", "The manifest records the test phase before compilation. The release is published only after subsequent PDF preflight and packaging succeed. It does not establish compatibility with untested versions."])
(OUT / "release-verification.tex").write_text("\n".join(lines) + "\n")
