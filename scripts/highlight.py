#!/usr/bin/env python3
"""Render handbook listing sources with Pygments; fail on missing/mismatched sources."""
from pathlib import Path
import re
from pygments import lex
from pygments.formatters import LatexFormatter
from pygments.lexers import get_lexer_by_name
from pygments.style import Style
from pygments.token import (Text, Whitespace, Error, Comment, Keyword, Name,
                            String, Number, Operator, Punctuation, Generic)

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'generated' / 'code'
CHAPTERS = ('guide.tex', 'distributed-cache.tex', 'catalyst-sessions.tex', 'api-credentials.tex', 'enterprise-architecture.tex')

class HandbookStyle(Style):
    styles = {
        Text: '#16324A', Whitespace: '#16324A', Error: '#16324A',
        Comment: '#536675', Keyword: '#006B70',
        Keyword.Type: '#006B70', Name: '#16324A',
        Name.Function: '#245B93', Name.Class: '#245B93',
        Name.Builtin: '#006B70', Name.Variable: '#264B70',
        String: '#984121', Number: '#765A13', Operator: '#36566D',
        Punctuation: '#16324A', Generic: '#16324A',
    }


def write_if_changed(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text(encoding='utf-8') != data:
        path.write_text(data, encoding='utf-8')


def mixed_perl_tokens(raw, lexer):
    """Keep Perl heredoc delimiters in Perl; highlight only Lua body text."""
    spans = []
    pending = None
    offset = 0
    for line in raw.splitlines(keepends=True):
        if pending is not None and line.rstrip('\r\n') == 'LUA':
            spans.append((pending, offset))
            pending = None
        elif pending is None and re.search(r"<<\s*'LUA'", line):
            pending = offset + len(line)
        offset += len(line)
    if pending is not None:
        raise ValueError('Unterminated Lua heredoc')
    if not spans:
        return list(lex(raw, lexer))
    # Slice the original token stream instead of re-lexing isolated Perl
    # segments: Perl lexer state outside the embedded script is preserved.
    perl_tokens = list(lex(raw, lexer))
    lua = get_lexer_by_name('lua', stripnl=False, ensurenl=False, tabsize=0)
    result = []
    def perl_slice(start, end):
        pos = 0
        for kind, value in perl_tokens:
            stop = pos + len(value)
            a, b = max(start, pos), min(end, stop)
            if a < b:
                result.append((kind, value[a-pos:b-pos]))
            pos = stop
            if pos >= end:
                break
    start = 0
    for a, b in spans:
        perl_slice(start, a)
        result.extend(lex(raw[a:b], lua))
        start = b
    perl_slice(start, len(raw))
    return result


def main():
    fmt = LatexFormatter(style=HandbookStyle, nowrap=True, commandprefix='PG')
    write_if_changed(OUT / 'palette.tex', fmt.get_style_defs() + '\n')
    seen = {}
    for chapter in CHAPTERS:
        source = (ROOT / chapter).read_text(encoding='utf-8')
        for lang, name in re.findall(r'\\CodeFile\{([^{}]+)\}\{([^{}]+)\}', source):
            if name in seen and seen[name] != lang:
                raise ValueError(f'Conflicting language for {name}')
            if name in seen:
                continue
            seen[name] = lang
            path = ROOT / name
            raw = path.read_text(encoding='utf-8')
            lexer = get_lexer_by_name('perl' if lang == 'perllua' else lang, stripnl=False, ensurenl=False, tabsize=0)
            tokens = mixed_perl_tokens(raw, lexer) if lang in ('perl', 'perllua') else list(lex(raw, lexer))
            if ''.join(value for _, value in tokens) != raw:
                raise ValueError(f'Lexer did not preserve source text: {name}')
            from io import StringIO
            output = StringIO()
            fmt.format(tokens, output)
            write_if_changed(OUT / (name + '.tex'), output.getvalue().replace(chr(96), r'\PGZgrave{}'))
    print(f'Highlighted {len(seen)} listing sources (source-text round trip verified).')

if __name__ == '__main__':
    main()
