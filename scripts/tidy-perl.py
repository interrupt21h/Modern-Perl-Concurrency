#!/usr/bin/env python3
"""Format Perl sources only, validate the complete batch before writing it."""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = {'.pl', '.pm', '.psgi', '.t'}


def lua_bodies(source):
    bodies = []
    pending = None
    for line in source.splitlines(keepends=True):
        if pending is not None:
            if line.rstrip(b'\r\n') == b'LUA':
                bodies.append(b''.join(pending))
                pending = None
            else:
                pending.append(line)
        elif re.search(rb"<<\s*'LUA'", line):
            pending = []
    if pending is not None:
        raise ValueError('Unterminated Lua heredoc')
    return bodies


def tidy(executable, data, path):
    result = subprocess.run(
        [executable, '-pro=' + str(ROOT / '.perltidyrc'), '-st', '-se'],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=ROOT, timeout=60,
    )
    if result.returncode or result.stderr:
        raise RuntimeError(f'{path}: Perl::Tidy diagnostic (exit {result.returncode}):\n'
                           + result.stderr.decode(errors='replace'))
    if data.strip() and not result.stdout.strip():
        raise RuntimeError(f'{path}: unexpected empty output')
    if lua_bodies(data) != lua_bodies(result.stdout):
        raise RuntimeError(f'{path}: embedded Lua body changed')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='report differences; do not write')
    args = parser.parse_args()
    executable = shutil.which('perltidy')
    if not executable:
        parser.exit(2, 'Perl::Tidy unavailable. Install with cpanm Perl::Tidy or your OS package manager.\n')
    subprocess.run([executable, '-v'], check=True)
    files = sorted(p for directory in ('examples', 'snippets')
                   for p in (ROOT / directory).rglob('*')
                   if p.is_file() and p.suffix in EXTENSIONS)
    if not files:
        parser.exit(2, 'No Perl source files found.\n')
    changes = []
    for path in files:
        original = path.read_bytes()
        formatted = tidy(executable, original, path.relative_to(ROOT))
        # Formatting must reach a fixed point before we accept it.
        if tidy(executable, formatted, path.relative_to(ROOT)) != formatted:
            raise RuntimeError(f'{path}: formatting is not idempotent')
        if original != formatted:
            changes.append((path, formatted))
    for path, formatted in changes:
        print(('Would format: ' if args.check else 'Formatting: ') + str(path.relative_to(ROOT)))
        if not args.check:
            path.write_bytes(formatted)
    print(f'{len(files)} Perl files checked; {len(changes)} differ. Embedded Lua preserved.')
    return int(args.check and bool(changes))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
